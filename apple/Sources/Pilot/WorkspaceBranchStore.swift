import Foundation
import Observation

/// Current git branch per workspace, for the sidebar's secondary text.
///
/// Every lookup is a `git` subprocess, and the sidebar can list dozens of
/// workspaces, so refreshes are bounded in width, skip workspaces whose root
/// path hasn't changed unless the interval has elapsed, and never block the
/// main actor beyond publishing the result.
@Observable
@MainActor
final class WorkspaceBranchStore {
    private(set) var branches: [UUID: String] = [:]

    /// Root path each entry was resolved from, so a workspace that is
    /// re-pointed at a different directory refreshes immediately instead of
    /// showing the previous repository's branch.
    @ObservationIgnored private var resolvedPaths: [UUID: String] = [:]
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Branch changes are user-driven (a checkout in a terminal pane), so this
    /// only needs to be fresh enough to feel live, not instantaneous.
    private static let refreshInterval: TimeInterval = 20
    /// Concurrent `git` invocations. Enough to keep a large sidebar responsive
    /// without spawning one subprocess per workspace at once.
    private static let maximumConcurrentLookups = 4

    /// One workspace's identity for lookup purposes, decoupled from SwiftData
    /// so the refresh can run off the main actor.
    struct Target: Sendable, Equatable {
        let id: UUID
        let rootPath: String
    }

    /// Refresh the given workspaces. Cheap to call on every sidebar render: it
    /// no-ops unless a root path changed or the interval elapsed.
    func refresh(_ targets: [Target], force: Bool = false) {
        let stale = force
            || lastRefresh.map { Date().timeIntervalSince($0) >= Self.refreshInterval } ?? true
        let changed = targets.filter { resolvedPaths[$0.id] != $0.rootPath }

        let work = stale ? targets : changed
        guard !work.isEmpty else { return }

        // Drop entries for workspaces that no longer exist or lost their path.
        let liveIDs = Set(targets.map(\.id))
        branches = branches.filter { liveIDs.contains($0.key) }
        resolvedPaths = resolvedPaths.filter { liveIDs.contains($0.key) }

        lastRefresh = Date()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.lookup(work)
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func lookup(_ targets: [Target]) async {
        var remaining = targets[...]
        await withTaskGroup(of: (UUID, String, String?).self) { group in
            func addNext() {
                guard let target = remaining.popFirst() else { return }
                group.addTask {
                    let branch = await GitStatus.currentBranch(directory: target.rootPath)
                    return (target.id, target.rootPath, branch)
                }
            }

            for _ in 0..<Self.maximumConcurrentLookups { addNext() }

            while let (id, path, branch) = await group.next() {
                guard !Task.isCancelled else { break }
                resolvedPaths[id] = path
                if let branch {
                    branches[id] = branch
                } else {
                    // Not a repository: drop any stale value rather than
                    // leaving the previous branch on screen.
                    branches.removeValue(forKey: id)
                }
                addNext()
            }
        }
    }
}
