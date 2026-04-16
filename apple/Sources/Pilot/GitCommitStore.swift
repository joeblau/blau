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
            fetchAll()
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
        fetchAll()
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

    func fetchAll() {
        fetchCommits()
        fetchActions()
        fetchRuns()
    }

    func fetchCommits() {
        guard !repoPath.isEmpty else { return }
        isLoading = true
        let dir = repoPath

        Task {
            let result = await Self.fetchGitData(directory: dir)
            self.commits = result
            self.isLoading = false
        }
    }

    func fetchActions() {
        guard !repoPath.isEmpty else { return }
        let dir = repoPath

        Task {
            let result = await Self.fetchActionsData(directory: dir)
            self.actions = result
        }
    }

    func fetchRuns() {
        guard !repoPath.isEmpty else { return }
        let dir = repoPath

        Task {
            let result = await Self.fetchRunsData(directory: dir)
            self.runs = result
        }
    }

    func fetchFilesystem() {
        guard !repoPath.isEmpty else { return }
        isLoadingFilesystem = true
        let dir = repoPath

        Task {
            let result = await Self.fetchFilesystemData(directory: dir)
            self.filesystem = result
            self.isLoadingFilesystem = false
        }
    }

    private nonisolated static func fetchGitData(directory: String) async -> [GitCommit] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let logResult = shellRun("git", args: ["log", "--oneline", "--format=%H||%h||%s||%an||%aI", "-10"], in: directory)
                let parsed = logResult.components(separatedBy: "\n").compactMap { line -> GitCommit? in
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
                continuation.resume(returning: parsed)
            }
        }
    }

    private nonisolated static func fetchActionsData(directory: String) async -> [GitAction] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = shellRun("gh", args: [
                    "run", "list", "--limit", "10",
                    "--json", "status,conclusion,displayTitle,headBranch,headSha,name,createdAt"
                ], in: directory)

                var actions: [GitAction] = []
                if let data = result.data(using: .utf8),
                   let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for item in items {
                        let createdAt = item["createdAt"] as? String ?? ""
                        actions.append(GitAction(
                            name: item["name"] as? String ?? "",
                            displayTitle: item["displayTitle"] as? String ?? "",
                            headBranch: item["headBranch"] as? String ?? "",
                            headSha: item["headSha"] as? String ?? "",
                            status: item["status"] as? String ?? "",
                            conclusion: item["conclusion"] as? String ?? "",
                            elapsed: createdAt.isEmpty ? "" : Self.relativeTime(from: createdAt)
                        ))
                    }
                }
                continuation.resume(returning: actions)
            }
        }
    }

    private nonisolated static func fetchRunsData(directory: String) async -> [GitRun] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = shellRun("gh", args: [
                    "run", "list", "--limit", "10",
                    "--json", "databaseId,name,displayTitle,headBranch,status,conclusion,updatedAt"
                ], in: directory)

                var runs: [GitRun] = []
                if let data = result.data(using: .utf8),
                   let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for item in items {
                        let dbID = item["databaseId"] as? Int ?? 0
                        let name = item["name"] as? String ?? ""
                        let title = item["displayTitle"] as? String ?? ""
                        let branch = item["headBranch"] as? String ?? ""
                        let updatedAt = item["updatedAt"] as? String ?? ""
                        let conclusionStr = item["conclusion"] as? String ?? ""
                        let statusStr = item["status"] as? String ?? ""

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

                        let elapsed = Self.relativeTime(from: updatedAt)
                        runs.append(GitRun(id: dbID, name: name, title: title, branch: branch, elapsed: elapsed, status: status))
                    }
                }
                continuation.resume(returning: runs)
            }
        }
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

    private nonisolated static func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    nonisolated static func findGitRoot(from directory: String) -> String? {
        let result = shellRun("git", args: ["rev-parse", "--show-toplevel"], in: directory)
        return result.isEmpty ? nil : result
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

    private nonisolated static func shellRun(_ command: String, args: [String], in directory: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "")
        process.environment = env
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
