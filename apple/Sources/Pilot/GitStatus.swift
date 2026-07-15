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
}
