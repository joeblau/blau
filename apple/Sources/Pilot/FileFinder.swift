import Foundation

/// One indexed file in a workspace root.
struct FileItem: Identifiable, Hashable {
    var id: String { path }
    let path: String          // absolute
    let relativePath: String  // path relative to root, shown in the UI
    let name: String          // basename
}

/// In-memory file index + fuzzy search for the editor's "open file" finder.
///
/// `start(root:)` builds the index once per root (off the main actor), then
/// `setQuery(_:)` filters it *off the main actor* on every keystroke via
/// `FuzzyMatcher` — the full scan is ~280ms at the 200k cap, far too much to
/// run on the MainActor without freezing typing. Indexing prefers
/// `git ls-files` so `.gitignore` is honored for free (plus a pruned scan that
/// adds back `.env*` / `.dev.vars` — gitignored, but exactly the files you open
/// by hand), and falls back to a pruned filesystem walk outside git repos.
@MainActor
@Observable
final class FileFinder {
    /// The current search results — already filtered, scored, sorted, and capped.
    private(set) var results: [FileItem] = []
    /// True while the background index is being built.
    private(set) var isIndexing: Bool = false

    /// The full, unfiltered index. Filtering reads from here on every keystroke.
    @ObservationIgnored private var index: [FileItem] = []
    /// The root the current `index` was (or is being) built for. Used both to
    /// make `start` idempotent and to drop results from a stale indexing task
    /// when the root changes mid-flight.
    @ObservationIgnored private var indexedRoot: String?
    /// The live query, retained so a freshly-built index can immediately reflect
    /// whatever the user has already typed.
    @ObservationIgnored private var query: String = ""
    /// Bumped on every query change (and refilter). The off-main filter task
    /// captures the value at dispatch time and only publishes its results if it
    /// still matches — so a slow scan for an old keystroke can't clobber a newer
    /// one (last-write-wins by generation, not by completion order).
    @ObservationIgnored private var queryGeneration = 0

    /// Caps:
    /// - `maxIndexedFiles` bounds memory and indexing time on huge trees.
    /// - `maxResults` bounds what we hand back to SwiftUI per keystroke.
    nonisolated private static let maxIndexedFiles = 200_000
    nonisolated private static let maxResults = 300

    /// Directory names skipped wholesale during the non-git filesystem walk.
    /// Build artifacts, dependency caches, and VCS metadata — none of which the
    /// user wants to open by hand.
    nonisolated private static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", "Pods",
        ".next", "dist", "out", "target", ".venv", "venv", "__pycache__",
        ".swiftpm", "vendor", "Carthage", ".gradle", ".idea", ".cache",
        ".turbo", ".vercel", "coverage",
    ]

    init() {}

    /// Kicks off indexing of `root`. Idempotent: calling it again with a root we
    /// already indexed (or are mid-indexing) is a no-op, so it's safe to call
    /// straight from `.onAppear`. Calling it with a *different* root replaces the
    /// index and invalidates any in-flight task for the old root.
    func start(root: String) {
        let normalized = Self.normalize(root)
        let isNewRoot = indexedRoot != normalized

        // Re-index on every explicit open so files created or removed since the
        // last scan show up — the index used to be built once per root and then
        // cached forever, which left the finder stale (e.g. an agent writes new
        // files in a sibling terminal and they never appear). Skip only when a
        // scan for this exact root is already in flight.
        if !isNewRoot && isIndexing { return }

        indexedRoot = normalized
        if isNewRoot {
            // Switched workspaces: drop the previous project's files so they
            // don't linger while the first scan of the new root runs. On a
            // same-root refresh we keep the current results visible until the
            // rescan lands, avoiding an empty flash.
            index = []
            results = []
        }
        isIndexing = true

        Task.detached(priority: .userInitiated) {
            let items = Self.buildIndex(root: normalized)
            await MainActor.run {
                // Guard against a stale task: if `start` was called again with a
                // different root while we were walking the disk, this result is
                // obsolete — drop it and let the newer task win.
                guard self.indexedRoot == normalized else { return }
                self.index = items
                self.isIndexing = false
                // Populate the initial/empty-query results now that the index
                // exists — reflecting whatever the user has already typed.
                self.refilter()
            }
        }
    }

    /// Updates the query and recomputes `results` off the main actor. Cheap on
    /// the MainActor (just trims + bumps a counter); the scan happens elsewhere.
    func setQuery(_ query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        refilter()
    }

    // MARK: - Filtering

    /// Dispatches a fresh filter pass for the current query/index off the main
    /// actor. Only immutable snapshots cross the actor boundary, and the result
    /// is published only if no newer query has superseded this one.
    private func refilter() {
        queryGeneration += 1
        let gen = queryGeneration
        let snapshot = index
        let q = self.query
        Task.detached(priority: .userInitiated) {
            // Brief debounce so a burst of keystrokes only scans once.
            try? await Task.sleep(for: .milliseconds(20))
            let computed = Self.filter(items: snapshot, query: q)
            await MainActor.run {
                // Drop stale results: a newer keystroke (or refilter) wins.
                guard self.queryGeneration == gen else { return }
                self.results = computed
            }
        }
    }

    /// Filters/sorts `items` against `query` and returns the top slice. Pure and
    /// `nonisolated` so it can run off the main actor over an immutable snapshot.
    nonisolated static func filter(items: [FileItem], query: String) -> [FileItem] {
        if query.isEmpty {
            // No query: show the first chunk of the tree, alphabetized. A plain
            // case-insensitive compare is fine here — we're off the main actor.
            return items
                .sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
                .prefix(maxResults)
                .map { $0 }
        }

        // Score every item; keep the matches; sort best-first, breaking ties
        // toward shorter paths (the shorter path is usually the tighter match).
        // Quick-open semantics: match the file *name* by default so typing a
        // filename (".env.", "Contents") surfaces files actually called that, not
        // every path whose directory letters happen to spell it (".env." used to
        // match ".../Assets.xcassets/assets/NVDA.imageset/…" through the dirs).
        // Match the full relative path only once the query contains "/", the
        // explicit "I'm typing a path" signal.
        let matchPath = query.contains("/")
        let scored = items.compactMap { item -> (item: FileItem, score: Int)? in
            let candidate = matchPath ? item.relativePath : item.name
            guard let score = FuzzyMatcher.score(query: query, candidate: candidate) else { return nil }
            return (item, score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.relativePath.count < rhs.item.relativePath.count
        }

        return scored.prefix(maxResults).map { $0.item }
    }

    // MARK: - Indexing (runs off the main actor)

    /// Builds the file list for `root`: git-aware first, filesystem walk second.
    private nonisolated static func buildIndex(root: String) -> [FileItem] {
        if let gitFiles = gitListFiles(root: root) {
            // git ls-files omits .gitignored files, but .env* / .dev.vars are
            // exactly the ignored files a developer opens by hand. Add them back
            // via a pruned walk (node_modules and friends stay skipped), deduped
            // against the git set so non-ignored env files aren't listed twice.
            var seen = Set(gitFiles.map(\.path))
            var merged = gitFiles
            for item in walkFilesystem(root: root, includeName: { Self.isDevConfigFile($0) })
            where merged.count < maxIndexedFiles && !seen.contains(item.path) {
                merged.append(item)
                seen.insert(item.path)
            }
            return merged
        }
        return walkFilesystem(root: root)
    }

    /// Gitignored files worth surfacing anyway: env files and wrangler's local
    /// secrets (`.dev.vars`). Matched by basename so they're found wherever they
    /// sit in the tree.
    private nonisolated static func isDevConfigFile(_ name: String) -> Bool {
        name.hasPrefix(".env") || name.hasPrefix(".dev.vars")
    }

    /// `git ls-files --cached --others --exclude-standard -z` enumerates tracked
    /// *and* untracked-but-not-ignored files, NUL-separated, relative to `root`.
    /// Returns `nil` when `root` isn't a git work tree or git fails/missing, so
    /// the caller can fall back to a filesystem walk.
    private nonisolated static func gitListFiles(root: String) -> [FileItem]? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "git", "-C", root,
            "ls-files", "--cached", "--others", "--exclude-standard", "-z",
        ]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Inherit a sane PATH so `git` resolves under both Homebrew and system installs.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env

        do {
            try process.run()
        } catch {
            return nil   // git not found / not launchable — fall back to walking.
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Non-zero exit means "not a git repository" (or similar): bail to the walk.
        guard process.terminationStatus == 0 else { return nil }

        let prefix = root.hasSuffix("/") ? root : root + "/"
        var items: [FileItem] = []
        items.reserveCapacity(min(4096, maxIndexedFiles))

        // Split on the NUL separator at the byte level *before* decoding, then
        // decode each path lossily on its own. Whole-buffer UTF-8 decoding fails
        // outright if any single filename has invalid bytes (seen on SMB/exFAT),
        // which would throw away the entire git index; per-path decoding drops at
        // most the one bad entry.
        for chunk in data.split(separator: 0x00, omittingEmptySubsequences: true) {
            let relativePath = String(decoding: chunk, as: UTF8.self)
            if relativePath.isEmpty { continue }
            items.append(FileItem(
                path: prefix + relativePath,
                relativePath: relativePath,
                name: (relativePath as NSString).lastPathComponent
            ))
            if items.count >= maxIndexedFiles { break }
        }
        return items
    }

    /// Filesystem fallback: a pruned recursive walk that skips known build/cache
    /// directories and collects regular files only.
    private nonisolated static func walkFilesystem(
        root: String,
        includeName: (@Sendable (String) -> Bool)? = nil
    ) -> [FileItem] {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]

        // Don't skip hidden files: the git path surfaces non-ignored dotfiles
        // (.github/, .env, .gitignore, …), so the walk should too. The
        // `skippedDirectories` prune below still keeps .git/.idea/.build/etc out,
        // so only genuine dotfiles become reachable — not VCS/build junk.
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }   // skip unreadable entries, keep going
        ) else {
            return []
        }

        let prefix = root.hasSuffix("/") ? root : root + "/"
        var items: [FileItem] = []

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                // Prune entire subtrees we never want to surface.
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }

            let name = url.lastPathComponent
            if let includeName, !includeName(name) { continue }

            let absolute = url.path
            let relativePath = absolute.hasPrefix(prefix) ? String(absolute.dropFirst(prefix.count)) : name
            items.append(FileItem(
                path: absolute,
                relativePath: relativePath,
                name: name
            ))
            if items.count >= maxIndexedFiles { break }
        }
        return items
    }

    /// Standardizes the root so idempotency checks compare apples to apples
    /// (expands `~`, resolves symlinks, resolves `..`, strips a trailing slash).
    ///
    /// Resolving symlinks matters because roots under /tmp, /var, /etc are
    /// themselves symlinks into /private/…. The enumerator yields the resolved
    /// /private/… paths, so the walk's `prefix` must match — otherwise the
    /// `hasPrefix` check fails and every relativePath collapses to its basename.
    /// `git -C` works fine with the resolved path.
    private nonisolated static func normalize(_ root: String) -> String {
        let expanded = (root as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        var path = (resolved as NSString).standardizingPath
        if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
