import Foundation

/// Lightweight, on-demand git working-tree status for a directory. The terminal
/// tab header uses it to show whether the shell's current repo is Clean or
/// Dirty. Runs `git status --porcelain` off the main actor.
enum GitStatus {
    /// `true` if the work tree at `directory` has uncommitted changes (modified,
    /// staged, or untracked), `false` if it's clean, `nil` if `directory` isn't a
    /// git work tree or git can't be run.
    static func isDirty(directory: String) async -> Bool? {
        let dir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return nil }
        let invocation = ProcessInvocation.developerTool(
            "git",
            arguments: ["-C", dir, "status", "--porcelain"],
            timeout: .seconds(10),
            standardOutputLimit: 2 * 1_024 * 1_024
        )
        guard let result = try? await ProcessRunner.run(invocation) else { return nil }
        let output = result.standardOutputString
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Current branch for the work tree at `directory`, or nil when it isn't a
    /// git work tree. A detached HEAD reports no branch, so it falls back to the
    /// short commit — showing nothing there would read as "not a repo".
    static func currentBranch(directory: String) async -> String? {
        let dir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return nil }

        let branchInvocation = ProcessInvocation.developerTool(
            "git",
            arguments: ["-C", dir, "branch", "--show-current"],
            timeout: .seconds(10),
            standardOutputLimit: 64 * 1_024
        )
        guard let result = try? await ProcessRunner.run(branchInvocation) else { return nil }
        let branch = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty { return sanitizedReference(branch) }

        // Empty output means either a detached HEAD or not a repository at all;
        // rev-parse distinguishes them.
        let headInvocation = ProcessInvocation.developerTool(
            "git",
            arguments: ["-C", dir, "rev-parse", "--short", "HEAD"],
            timeout: .seconds(10),
            standardOutputLimit: 64 * 1_024
        )
        guard let headResult = try? await ProcessRunner.run(headInvocation) else { return nil }
        let head = headResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? nil : sanitizedReference(head)
    }

    /// Branch names come from the repository, not from Pilot, and land directly
    /// in a sidebar row — strip control characters and bound the length.
    static func sanitizedReference(_ raw: String) -> String? {
        let cleaned = UntrustedText.sanitized(raw, limit: 60)
        return cleaned.isEmpty ? nil : cleaned
    }
}
