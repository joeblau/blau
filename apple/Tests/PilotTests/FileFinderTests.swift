import Foundation
import Testing
@testable import Pilot

@Suite("File finder filtering")
struct FileFinderTests {

    private func item(_ relativePath: String) -> FileItem {
        FileItem(
            path: "/root/" + relativePath,
            relativePath: relativePath,
            name: (relativePath as NSString).lastPathComponent
        )
    }

    private func sample() -> [FileItem] {
        [
            "workers/rendezvous/src/index.ts",
            "workers/rendezvous/package.json",
            "workers/rendezvous/tsconfig.json",
            "workers/web/package.json",
            "apple/Sources/Pilot/EditorPaneView.swift",
            "apple/Sources/Pilot/FileFinder.swift",
            "apple/Tests/PilotTests/PaneCyclingTests.swift",
        ].map(item)
    }

    /// Regression: a query that only appears in the *directory* path (no file is
    /// named "rendezvous") must still surface the files inside that directory.
    /// The old name-only matcher returned nothing here.
    @Test("Files are findable by a directory-name substring")
    func findsByDirectorySubstring() {
        let results = FileFinder.filter(items: sample(), query: "rendezvous")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.relativePath.contains("rendezvous") })
        #expect(results.contains { $0.name == "index.ts" })
        #expect(results.contains { $0.name == "package.json" })
    }

    /// Quick-open is preserved: a basename match outranks a path-only match of
    /// the same query, so typing a filename still lands that file first.
    @Test("A basename match outranks a path-only match")
    func basenameOutranksPath() {
        let files = [
            item("zoo/Sources/helpers/util.swift"),     // "pane" only via the dir? no — control row
            item("pane/Sources/helpers/util.swift"),    // "pane" only in the directory
            item("apple/Sources/Pilot/EditorPaneView.swift"), // "pane" in the basename
        ]
        let results = FileFinder.filter(items: files, query: "pane")
        #expect(results.first?.name == "EditorPaneView.swift")
    }

    /// A query containing "/" matches against the full relative path.
    @Test("A slash query matches the full path")
    func slashQueryMatchesPath() {
        let results = FileFinder.filter(items: sample(), query: "rendezvous/index")
        #expect(results.first?.relativePath == "workers/rendezvous/src/index.ts")
    }

    /// No query is the "browse" case: the whole list, alphabetized by path.
    @Test("Empty query returns the tree alphabetized")
    func emptyQueryAlphabetized() {
        let files = sample()
        let results = FileFinder.filter(items: files, query: "")
        #expect(results.count == files.count)
        let expected = files.map(\.relativePath)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #expect(results.map(\.relativePath) == expected)
    }

    /// A greedy matcher commits to the first `a` and misses the stronger `ab`
    /// run later in the same candidate. The scorer should choose the best
    /// alignment, not merely the first valid subsequence.
    @Test("The best later fuzzy alignment wins")
    func bestLaterAlignmentWins() throws {
        let laterRun = try #require(FuzzyMatcher.score(query: "ab", candidate: "a---ab.swift"))
        let scattered = try #require(FuzzyMatcher.score(query: "ab", candidate: "axxb.swift"))

        #expect(laterRun > scattered)
    }

    /// Boundary bonuses make acronym-style matching useful, but they must not
    /// outweigh an exact contiguous filename match for the same query.
    @Test("A contiguous exact match outranks scattered boundary matches")
    func contiguousMatchOutranksScatteredBoundaries() throws {
        let contiguous = try #require(FuzzyMatcher.score(query: "abc", candidate: "abc.swift"))
        let boundaryScattered = try #require(FuzzyMatcher.score(query: "abc", candidate: "a_x_b_c.swift"))

        #expect(contiguous > boundaryScattered)
    }

    /// Space-separated terms may target different path components and need not
    /// be typed in path order. This is the common "project + filename" flow.
    @Test("Multiple search terms may match independently")
    func multipleTermsMatchIndependently() {
        let files = [
            item("apple/Sources/Pilot/EditorPaneView.swift"),
            item("apple/Sources/Pilot/FileFinder.swift"),
            item("docs/EditorPaneView.md"),
        ]

        let forward = FileFinder.filter(items: files, query: "pilot editor")
        let reversed = FileFinder.filter(items: files, query: "editor pilot")

        #expect(forward.map(\.relativePath) == ["apple/Sources/Pilot/EditorPaneView.swift"])
        #expect(reversed.map(\.relativePath) == ["apple/Sources/Pilot/EditorPaneView.swift"])
    }

    /// Both common path separator styles should work, and omitted intermediate
    /// directories should not prevent a recursively indexed file from matching.
    @Test("Recursive path queries accept either separator style")
    func pathQueriesAcceptFlexibleSeparators() {
        let files = [
            item("packages/editor/Sources/Search/FileFinder.swift"),
            item("packages/terminal/Sources/Search/FileFinder.swift"),
        ]

        let slash = FileFinder.filter(items: files, query: "packages/editor/file")
        let backslash = FileFinder.filter(items: files, query: "packages\\editor\\file")

        #expect(slash.first?.relativePath == "packages/editor/Sources/Search/FileFinder.swift")
        #expect(backslash.first?.relativePath == "packages/editor/Sources/Search/FileFinder.swift")
    }

    /// Equal-scoring, equal-length paths need a stable lexical tiebreaker rather
    /// than inheriting filesystem enumeration or caller input order.
    @Test("Equal fuzzy matches have deterministic lexical ordering")
    func equalMatchesAreDeterministic() {
        let firstOrder = [item("zulu/Target.swift"), item("able/Target.swift")]
        let secondOrder = firstOrder.reversed()
        let expected = ["able/Target.swift", "zulu/Target.swift"]

        #expect(FileFinder.filter(items: firstOrder, query: "target").map(\.relativePath) == expected)
        #expect(FileFinder.filter(items: Array(secondOrder), query: "target").map(\.relativePath) == expected)
    }

    /// Exercises indexing against a real nested tree so this catches regressions
    /// in the non-git recursive-walk fallback, not just the in-memory filter.
    @Test("A real nested directory is indexed recursively")
    func indexesRealNestedDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("BlauFileFinderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let nestedDirectory = root
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("Features", isDirectory: true)
            .appendingPathComponent("Search", isDirectory: true)
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let nestedFile = nestedDirectory.appendingPathComponent("NestedResult.swift")
        try "struct NestedResult {}\n".write(to: nestedFile, atomically: true, encoding: .utf8)

        let indexed = FileFinder.buildIndex(root: root.path)

        #expect(indexed.contains {
            $0.relativePath == "Sources/Features/Search/NestedResult.swift"
        }, "Indexed paths: \(indexed.map(\.relativePath))")
    }
}
