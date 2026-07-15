import Foundation

struct GitCommit: Identifiable {
    let id: String // short SHA
    let fullSHA: String
    let message: String
    let author: String
    let date: String
}

struct GitAction: Identifiable {
    let id: UUID = UUID()
    let name: String
    let displayTitle: String
    let headBranch: String
    let headSha: String
    let status: String
    let conclusion: String
    let elapsed: String
    let url: String
}

struct GitRun: Identifiable {
    let id: Int
    let name: String
    let title: String
    let branch: String
    let elapsed: String
    let status: Status

    enum Status: String {
        case success, failure, inProgress, queued, unknown
    }
}

struct FileSystemEntry: Identifiable {
    let id: String
    let name: String
    let path: String
    let relativePath: String
    let isDirectory: Bool
    let children: [FileSystemEntry]?
}

@MainActor
@Observable
final class GitCommitStore {
    var commits: [GitCommit] = []
    var actions: [GitAction] = []
    var runs: [GitRun] = []
    var filesystem: [FileSystemEntry] = []
    var repoPath: String = ""
    var isLoading = false
    var isLoadingFilesystem = false
    private var refreshTimer: Timer?

    func startWatching(directory: String) {
        if repoPath == directory {
            fetchAll(policy: .automatic)
            if filesystem.isEmpty && !isLoadingFilesystem {
                fetchFilesystem()
            }
            return
        }

        repoPath = directory
        commits = []
        actions = []
        runs = []
        filesystem = []
        fetchAll(policy: .automatic)
        fetchFilesystem()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                self.fetchAll()
            }
        }
    }

    func stopWatching() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        repoPath = ""
        commits = []
        actions = []
        runs = []
        filesystem = []
        isLoading = false
        isLoadingFilesystem = false
    }

    func fetchAll(policy: RepositoryRefreshPolicy = .automatic) {
        fetchCommits(policy: policy)
        fetchWorkflowRuns(policy: policy)
    }

    func fetchCommits(policy: RepositoryRefreshPolicy = .automatic) {
        guard !repoPath.isEmpty else { return }
        isLoading = true
        let dir = repoPath

        Task {
            let result = await Self.fetchGitData(directory: dir, policy: policy)
            // Drop stale results: the user may have switched workspaces while
            // the shell command ran, and these would clobber the new repo's data.
            guard self.repoPath == dir else { return }
            self.commits = result
            self.isLoading = false
        }
    }

    /// Actions and runs both come from `gh run list`; one invocation (one
    /// GitHub API round-trip) feeds both instead of two per refresh tick.
    func fetchWorkflowRuns(policy: RepositoryRefreshPolicy = .automatic) {
        guard !repoPath.isEmpty else { return }
        let dir = repoPath

        Task {
            let (actions, runs) = await Self.fetchWorkflowData(directory: dir, policy: policy)
            guard self.repoPath == dir else { return }
            self.actions = actions
            self.runs = runs
        }
    }

    func fetchFilesystem() {
        guard !repoPath.isEmpty else { return }
        isLoadingFilesystem = true
        let dir = repoPath

        Task {
            let result = await Self.fetchFilesystemData(directory: dir)
            guard self.repoPath == dir else { return }
            self.filesystem = result
            self.isLoadingFilesystem = false
        }
    }

    private nonisolated static func fetchGitData(
        directory: String,
        policy: RepositoryRefreshPolicy
    ) async -> [GitCommit] {
        guard let repository = await RepositoryPollingScheduler.shared.repository(for: directory),
              let data = try? await RepositoryPollingScheduler.shared.data(
                for: .commits,
                repository: repository,
                policy: policy
              ) else { return [] }
        let logResult = String(decoding: data, as: UTF8.self)
        return logResult.components(separatedBy: "\n").compactMap { line -> GitCommit? in
            let parts = line.components(separatedBy: "||")
            guard parts.count >= 5 else { return nil }
            return GitCommit(
                id: parts[1],
                fullSHA: parts[0],
                message: parts[2],
                author: parts[3],
                date: Self.relativeTime(from: parts[4])
            )
        }
    }

    private nonisolated static func fetchWorkflowData(
        directory: String,
        policy: RepositoryRefreshPolicy
    ) async -> ([GitAction], [GitRun]) {
        guard let repository = await RepositoryPollingScheduler.shared.repository(for: directory),
              let data = try? await RepositoryPollingScheduler.shared.data(
                for: .workflowRuns,
                repository: repository,
                policy: policy
              ),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ([], [])
        }

        var actions: [GitAction] = []
        var runs: [GitRun] = []
        for item in items.prefix(10) {
            let name = item["name"] as? String ?? ""
            let title = item["displayTitle"] as? String ?? ""
            let branch = item["headBranch"] as? String ?? ""
            let conclusionStr = item["conclusion"] as? String ?? ""
            let statusStr = item["status"] as? String ?? ""
            let createdAt = item["createdAt"] as? String ?? ""

            actions.append(GitAction(
                name: name,
                displayTitle: title,
                headBranch: branch,
                headSha: item["headSha"] as? String ?? "",
                status: statusStr,
                conclusion: conclusionStr,
                elapsed: createdAt.isEmpty ? "" : Self.relativeTime(from: createdAt),
                url: item["url"] as? String ?? ""
            ))

            let status: GitRun.Status
            if conclusionStr == "success" {
                status = .success
            } else if conclusionStr == "failure" {
                status = .failure
            } else if statusStr == "in_progress" {
                status = .inProgress
            } else if statusStr == "queued" {
                status = .queued
            } else {
                status = .unknown
            }

            let updatedAt = item["updatedAt"] as? String ?? ""
            runs.append(GitRun(
                id: item["databaseId"] as? Int ?? 0,
                name: name,
                title: title,
                branch: branch,
                elapsed: Self.relativeTime(from: updatedAt),
                status: status
            ))
        }
        return (actions, runs)
    }

    private nonisolated static func fetchFilesystemData(directory: String) async -> [FileSystemEntry] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let rootURL = URL(fileURLWithPath: directory, isDirectory: true)
                let entries = listFilesystemEntries(at: rootURL, rootURL: rootURL)
                continuation.resume(returning: entries)
            }
        }
    }

    private nonisolated static func relativeTime(from iso: String) -> String {
        guard let date = parseISODate(iso) else { return iso }
        return relativeTime(from: date)
    }

    private nonisolated static func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = .autoupdatingCurrent
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // ISO8601DateFormatter is documented thread-safe, and these are never
    // mutated after init — hence nonisolated(unsafe) is sound. Building one
    // per parsed row (30 rows per 30s refresh) was measurable churn.
    private nonisolated(unsafe) static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private nonisolated static func parseISODate(_ value: String) -> Date? {
        isoFractionalFormatter.date(from: value) ?? isoFormatter.date(from: value)
    }

    nonisolated static func findGitRoot(from directory: String) -> String? {
        let invocation = ProcessInvocation.developerTool(
            "git",
            arguments: ["rev-parse", "--show-toplevel"],
            currentDirectoryURL: URL(fileURLWithPath: directory, isDirectory: true),
            timeout: .seconds(10),
            standardOutputLimit: 64 * 1_024
        )
        guard let result = try? ProcessRunner.runBlocking(invocation) else { return nil }
        let root = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    nonisolated static func listFilesystemEntries(at directoryURL: URL, rootURL: URL) -> [FileSystemEntry] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return []
        }

        let sortedEntries = urls.compactMap { url -> (url: URL, isDirectory: Bool, isSymbolicLink: Bool)? in
            guard url.lastPathComponent != ".git" else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            return (
                url: url,
                isDirectory: values?.isDirectory ?? false,
                isSymbolicLink: values?.isSymbolicLink ?? false
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }

            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }

        return sortedEntries.map { entry in
            let relativePath = relativePath(for: entry.url, rootURL: rootURL)
            return FileSystemEntry(
                id: relativePath,
                name: entry.url.lastPathComponent,
                path: entry.url.path,
                relativePath: relativePath,
                isDirectory: entry.isDirectory,
                children: nil
            )
        }
    }

    private nonisolated static func relativePath(for fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        guard filePath.hasPrefix(prefix) else {
            return fileURL.lastPathComponent
        }

        return String(filePath.dropFirst(prefix.count))
    }

}
