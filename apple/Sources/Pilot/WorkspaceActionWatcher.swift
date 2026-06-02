import Foundation

/// Background poller that badges a workspace when a GitHub Action run completes
/// for its repo while you're looking at a *different* workspace. Complements
/// the terminal-bell badge (which already covers "a CLI finished"). The active
/// `GitCommitStore` only polls the selected repo, so this sweeps them all.
@MainActor
final class WorkspaceActionWatcher {
    private weak var store: WorkspaceStore?
    private var timer: Timer?

    /// Run IDs already counted as completed, per workspace. Seeded on the first
    /// sweep so runs that were already finished at launch never badge.
    private var seenCompleted: [UUID: Set<Int>] = [:]
    /// Workspaces whose baseline has been recorded.
    private var baselined: Set<UUID> = []

    /// Gentle cadence — Actions change less often than commits, and this hits
    /// `gh` once per workspace per tick.
    private static let interval: TimeInterval = 60

    func start(store: WorkspaceStore) {
        self.store = store
        timer?.invalidate()
        sweep()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sweep() {
        guard let store else { return }
        let selectedID = store.selectedWorkspaceID
        for workspace in store.workspaces {
            let dir = workspace.effectiveRootPath ?? ""
            guard !dir.isEmpty else { continue }
            let wsID = workspace.id
            let isSelected = (wsID == selectedID)
            let firstSweep = !baselined.contains(wsID)
            Task.detached(priority: .utility) {
                let completed = Self.completedRunIDs(in: dir)
                await MainActor.run {
                    self.process(workspaceID: wsID, completed: completed, isSelected: isSelected, firstSweep: firstSweep)
                }
            }
        }
    }

    private func process(workspaceID: UUID, completed: Set<Int>, isSelected: Bool, firstSweep: Bool) {
        let seen = seenCompleted[workspaceID] ?? []
        let fresh = completed.subtracting(seen)
        seenCompleted[workspaceID] = seen.union(completed)
        baselined.insert(workspaceID)

        // Baseline sweep just records state; never badge pre-existing runs.
        // Don't badge the workspace you're already looking at.
        guard !firstSweep, !isSelected, !fresh.isEmpty else { return }
        for _ in fresh {
            store?.badgeActionCompletion(workspaceID: workspaceID)
        }
    }

    // MARK: - gh (off the main actor)

    /// IDs of runs currently in the `completed` status for the repo at `dir`.
    /// Any newly-completed run (vs. the last sweep) is what we badge on.
    private nonisolated static func completedRunIDs(in dir: String) -> Set<Int> {
        let output = shell("gh", ["run", "list", "--limit", "30", "--json", "databaseId,status"], in: dir)
        guard let data = output.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var ids: Set<Int> = []
        for item in items where (item["status"] as? String) == "completed" {
            if let id = item["databaseId"] as? Int { ids.insert(id) }
        }
        return ids
    }

    private nonisolated static func shell(_ command: String, _ args: [String], in dir: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
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
