import AppKit
import SwiftUI

/// A GitHub issue surfaced as a "task" in the inspector.
struct GitHubTask: Identifiable, Decodable {
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

    func load(directory: String?) {
        loadTask?.cancel()
        guard let directory, !directory.trimmingCharacters(in: .whitespaces).isEmpty else {
            self.directory = nil
            tasks = []
            errorMessage = nil
            isLoading = false
            return
        }
        self.directory = directory
        isLoading = true
        errorMessage = nil
        loadTask = Task {
            let (issues, error) = await Self.fetch(in: directory)
            if Task.isCancelled { return }
            isLoading = false
            tasks = issues
            errorMessage = error
        }
    }

    func reload() { load(directory: directory) }

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
        HStack {
            Text(store.tasks.isEmpty ? "Issues" : "\(store.tasks.count) open")
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
            Spacer()
            Button { store.reload() } label: {
                Image(systemName: "arrow.clockwise").scaledFont(size: 11)
            }
            .buttonStyle(.plain)
            .help("Refresh issues")
            .disabled(store.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.tasks.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.errorMessage {
            ContentUnavailableView("No Issues", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if store.tasks.isEmpty {
            ContentUnavailableView("No Open Issues", systemImage: "checkmark.circle",
                                   description: Text("This repo has no open GitHub issues."))
        } else {
            List(store.tasks) { task in
                GitHubTaskRow(task: task)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
        }
    }
}

private struct GitHubTaskRow: View {
    let task: GitHubTask
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: copyNumber) {
                Text("#\(task.number)")
                    .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                    .foregroundStyle(copied ? Color.green : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Copy #\(task.number) to clipboard")

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

    private func copyNumber() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("#\(task.number)", forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
    }

    private func open() {
        guard let url = URL(string: task.url) else { return }
        NSWorkspace.shared.open(url)
    }
}
