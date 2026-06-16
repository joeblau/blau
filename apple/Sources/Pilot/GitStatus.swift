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
        return await Task.detached(priority: .utility) {
            run(directory: dir)
        }.value
    }

    private nonisolated static func run(directory: String) -> Bool? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory, "status", "--porcelain"]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Inherit a sane PATH so `git` resolves under Homebrew and system installs.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env

        do {
            try process.run()
        } catch {
            return nil   // git missing / not launchable.
        }

        // Drain before waiting so a large porcelain listing can't deadlock the pipe.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Non-zero exit means "not a git repository" (or similar) → unknown.
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: data, encoding: .utf8) ?? ""
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
