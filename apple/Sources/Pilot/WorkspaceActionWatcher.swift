import Foundation

enum ActionRunFetchError: Error, Sendable {
    case launchFailed(String)
    case commandFailed(Int32)
    case invalidJSON
}

struct ActionCompletionTracker {
    private(set) var seenCompleted: Set<Int> = []
    private(set) var hasBaseline = false

    /// Returns the number of genuinely new completions to badge. A failed fetch
    /// is not an empty snapshot: it leaves both baseline and history untouched.
    mutating func ingest(_ result: Result<Set<Int>, ActionRunFetchError>, isSelected: Bool) -> Int {
        guard case .success(let completed) = result else { return 0 }
        guard hasBaseline else {
            seenCompleted = completed
            hasBaseline = true
            return 0
        }
        let fresh = completed.subtracting(seenCompleted)
        seenCompleted.formUnion(completed)
        return isSelected ? 0 : fresh.count
    }
}

/// Background poller that badges a workspace when a GitHub Action run completes
/// for its repo while you're looking at a *different* workspace. Complements
/// the terminal-bell badge (which already covers "a CLI finished"). The active
/// `GitCommitStore` only polls the selected repo, so this sweeps them all.
@MainActor
final class WorkspaceActionWatcher {
    private weak var store: WorkspaceStore?
    private var timer: Timer?
    private var trackers: [UUID: ActionCompletionTracker] = [:]
    private var fetchTasks: [UUID: Task<Void, Never>] = [:]
    private var fetchGenerations: [UUID: Int] = [:]

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
        fetchTasks.values.forEach { $0.cancel() }
        fetchTasks.removeAll()
    }

    private func sweep() {
        guard let store else { return }
        for workspace in store.workspaces {
            let dir = workspace.effectiveRootPath ?? ""
            guard !dir.isEmpty else { continue }
            let wsID = workspace.id
            fetchTasks[wsID]?.cancel()
            let generation = (fetchGenerations[wsID] ?? 0) + 1
            fetchGenerations[wsID] = generation
            fetchTasks[wsID] = Task { [weak self] in
                let result = await Self.completedRunIDs(in: dir)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.fetchGenerations[wsID] == generation else { return }
                    self.fetchTasks[wsID] = nil
                    self.process(workspaceID: wsID, result: result)
                }
            }
        }
    }

    private func process(workspaceID: UUID, result: Result<Set<Int>, ActionRunFetchError>) {
        var tracker = trackers[workspaceID] ?? ActionCompletionTracker()
        let count = tracker.ingest(result, isSelected: store?.selectedWorkspaceID == workspaceID)
        trackers[workspaceID] = tracker
        for _ in 0..<count {
            store?.badgeActionCompletion(workspaceID: workspaceID)
        }
    }

    // MARK: - gh (off the main actor)

    /// IDs of runs currently in the `completed` status for the repo at `dir`.
    /// Any newly-completed run (vs. the last sweep) is what we badge on.
    private nonisolated static func completedRunIDs(
        in dir: String
    ) async -> Result<Set<Int>, ActionRunFetchError> {
        guard let repository = await RepositoryPollingScheduler.shared.repository(for: dir) else {
            return .failure(.launchFailed("Not a Git repository"))
        }
        let data: Data
        do {
            data = try await RepositoryPollingScheduler.shared.data(
                for: .workflowRuns,
                repository: repository,
                policy: .automatic
            )
        } catch let error as ProcessRunnerError {
            if case .launch(_, let message) = error { return .failure(.launchFailed(message)) }
            let status: Int32
            switch error.result?.termination {
            case .exit(let code), .signal(let code): status = code
            case nil: status = -1
            }
            return .failure(.commandFailed(status))
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .failure(.invalidJSON)
        }
        var ids: Set<Int> = []
        for item in items where (item["status"] as? String) == "completed" {
            if let id = item["databaseId"] as? Int { ids.insert(id) }
        }
        return .success(ids)
    }

}
