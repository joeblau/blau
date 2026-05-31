import AppKit
import SwiftUI

/// A GitHub issue surfaced as a "task" in the inspector.
struct GitHubTask: Identifiable, Decodable, Equatable {
    let number: Int
    let title: String
    let url: String
    let state: String
    var id: Int { number }
}

/// Loads open GitHub issues for the active workspace's repo via the `gh` CLI.
@Observable
@MainActor
final class GitHubTasksStore {
    private(set) var tasks: [GitHubTask] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var directory: String?
    private var loadTask: Task<Void, Never>?
    private var pollTimer: Timer?

    /// How often to re-poll `gh issue list` while the inspector is showing.
    /// Matches `GitCommitStore`'s commit/Actions cadence.
    private static let pollInterval: TimeInterval = 30

    /// Point the store at a repo (or `nil` to clear). Fetches immediately and
    /// keeps the list live via a background poll, so the inspector auto-updates
    /// without a manual refresh.
    func load(directory: String?) {
        let trimmed = directory?.trimmingCharacters(in: .whitespaces)
        guard let trimmed, !trimmed.isEmpty else {
            stopPolling()
            self.directory = nil
            tasks = []
            errorMessage = nil
            isLoading = false
            return
        }

        let isNewRepo = (trimmed != self.directory)
        self.directory = trimmed

        if isNewRepo {
            // Switching repos: drop the previous repo's issues and show the
            // spinner until the first fetch lands.
            tasks = []
            errorMessage = nil
            startPolling()
        }
        // Spinner only when we have nothing to show; background polls update
        // silently so the list doesn't flash.
        fetch(showSpinner: tasks.isEmpty)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in
                self.fetch(showSpinner: false)
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        loadTask?.cancel()
        loadTask = nil
    }

    private func fetch(showSpinner: Bool) {
        guard let directory else { return }
        loadTask?.cancel()
        if showSpinner { isLoading = true }
        loadTask = Task {
            let (issues, error) = await Self.fetch(in: directory)
            if Task.isCancelled { return }
            isLoading = false
            errorMessage = error
            // Keep the last good list on a transient poll failure; only swap
            // in new data on success so the inspector doesn't blink to an
            // error screen mid-poll. Insertions animate in the view layer.
            if error == nil {
                tasks = issues
            }
        }
    }

    nonisolated private static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func fetch(in directory: String) async -> ([GitHubTask], String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let gh = ghPath() else {
                    continuation.resume(returning: ([], "GitHub CLI (gh) not found."))
                    return
                }
                let process = Process()
                let out = Pipe()
                let err = Pipe()
                process.executableURL = URL(fileURLWithPath: gh)
                process.arguments = ["issue", "list", "--state", "open", "--limit", "100",
                                     "--json", "number,title,url,state"]
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                process.standardOutput = out
                process.standardError = err
                process.environment = ProcessInfo.processInfo.environment
                do {
                    try process.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let message = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: (
                            [], (message?.isEmpty == false) ? message! : "Couldn’t load GitHub issues."))
                        return
                    }
                    if let issues = try? JSONDecoder().decode([GitHubTask].self, from: data) {
                        continuation.resume(returning: (issues, nil))
                    } else {
                        continuation.resume(returning: ([], "Couldn’t parse gh output."))
                    }
                } catch {
                    continuation.resume(returning: ([], "Couldn’t run gh."))
                }
            }
        }
    }
}

/// Inspector tab listing open GitHub issues. Click a title to open it on
/// GitHub; click the `#number` to copy it for handing to an LLM.
struct GitHubTasksView: View {
    var store: GitHubTasksStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(store.tasks.isEmpty ? "Issues" : "\(store.tasks.count) open")
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
            // Subtle activity hint on the initial load. Background polls are
            // silent — the list just auto-updates, no manual refresh.
            if store.isLoading && store.tasks.isEmpty {
                ProgressView()
                    .controlSize(.mini)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        // Prefer showing data: once we have issues, keep showing them even if
        // a later poll errors out, so the inspector never blinks to an error
        // screen mid-poll.
        if !store.tasks.isEmpty {
            List(store.tasks) { task in
                GitHubTaskRow(task: task)
                    .listRowSeparator(.hidden)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            .listStyle(.inset)
            .animation(.snappy, value: store.tasks)
        } else if store.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.errorMessage {
            ContentUnavailableView("No Issues", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else {
            ContentUnavailableView("No Open Issues", systemImage: "checkmark.circle",
                                   description: Text("This repo has no open GitHub issues."))
        }
    }
}

private struct GitHubTaskRow: View {
    let task: GitHubTask
    @State private var sent = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: sendImplementPrompt) {
                Text("#\(task.number)")
                    .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                    .foregroundStyle(sent ? Color.green : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Run an \u{201C}implement #\(task.number)\u{201D} task in the active terminal")

            Text(task.title)
                .scaledFont(size: 12)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
                .help("Open #\(task.number) on GitHub")
        }
        .padding(.vertical, 3)
    }

    /// Click the number to drop an agent-ready prompt into the active terminal:
    /// fetch the issue from GitHub and build the fix. Pilot does the paste
    /// (it owns the terminal); we just announce the prompt.
    private func sendImplementPrompt() {
        let prompt = "Implement GitHub issue #\(task.number). "
            + "Read it first with `gh issue view \(task.number)`, then build and apply the fix."
        NotificationCenter.default.post(
            name: .pilotSendIssuePrompt,
            object: nil,
            userInfo: ["prompt": prompt]
        )
        sent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sent = false }
    }

    private func open() {
        guard let url = URL(string: task.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension Notification.Name {
    /// Posted by the Issues inspector when the user clicks an issue number;
    /// `userInfo["prompt"]` carries the text to paste into the active terminal.
    static let pilotSendIssuePrompt = Notification.Name("pilotSendIssuePrompt")
}
