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
        fetch(showSpinner: tasks.isEmpty, policy: .automatic)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in
                self.fetch(showSpinner: false, policy: .automatic)
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        loadTask?.cancel()
        loadTask = nil
    }

    func refresh() {
        fetch(showSpinner: tasks.isEmpty, policy: .manual)
    }

    private func fetch(showSpinner: Bool, policy: RepositoryRefreshPolicy) {
        guard let directory else { return }
        loadTask?.cancel()
        if showSpinner { isLoading = true }
        loadTask = Task {
            let (issues, error) = await Self.fetch(in: directory, policy: policy)
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

    nonisolated private static func fetch(
        in directory: String,
        policy: RepositoryRefreshPolicy
    ) async -> ([GitHubTask], String?) {
        guard let repository = await RepositoryPollingScheduler.shared.repository(for: directory) else {
            return ([], "This folder is not a Git repository.")
        }
        do {
            let data = try await RepositoryPollingScheduler.shared.data(
                for: .issues,
                repository: repository,
                policy: policy
            )
            guard let issues = try? JSONDecoder().decode([GitHubTask].self, from: data) else {
                return ([], "Couldn’t parse gh output.")
            }
            return (issues, nil)
        } catch let error as RepositoryPollingError {
            return ([], error.localizedDescription)
        } catch let error as ProcessRunnerError {
            let detail = error.result?.standardErrorString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty { return ([], detail) }
            return ([], "Couldn’t load GitHub issues.")
        } catch {
            return ([], "Couldn’t load GitHub issues.")
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
            // Fill the remaining height so the header stays pinned to the top
            // and the empty/loading states center in the space below it.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
            .help("Refresh GitHub issues")
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
            ScrollViewReader { proxy in
                List(store.tasks) { task in
                    GitHubTaskRow(task: task)
                        .listRowSeparator(.hidden)
                        // Fade in rather than sliding from the top edge: the
                        // `.move(edge: .top)` transition left a newly-injected
                        // first row offset under the header on the inset List,
                        // clipping it (issue #47).
                        .transition(.opacity)
                }
                .listStyle(.inset)
                .animation(.snappy, value: store.tasks)
                // When a new issue is injected at the top, the inset List keeps
                // its scroll offset and hides the fresh first row behind the
                // header — scroll it back into view so it renders fully.
                .onChange(of: store.tasks.first?.id) { _, newFirstID in
                    guard let newFirstID else { return }
                    withAnimation(.snappy) {
                        proxy.scrollTo(newFirstID, anchor: .top)
                    }
                }
            }
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
            + "Read it first with `gh issue view \(task.number)`, then build and apply the fix. "
            + "When you open the pull request, include `fixes #\(task.number)` in the commit "
            + "message so merging auto-closes the issue."
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
