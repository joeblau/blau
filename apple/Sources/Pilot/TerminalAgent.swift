import Darwin
import Foundation

/// A CLI coding agent that Pilot flags in a terminal tab header while it owns
/// the pane's pty. Detection walks the pane shell's descendants and inspects
/// each process's executable path and argv; it never runs a subprocess.
enum TerminalAgent: String, CaseIterable, Sendable {
    case claude
    case codex
    case gemini
    case aider
    case kimi
    case grok

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .aider: "Aider"
        case .kimi: "Kimi"
        case .grok: "Grok"
        }
    }

    /// Path fragments identifying the agent. Native installs exec a binary
    /// named after the agent (`~/.local/bin/claude`); npm installs exec a
    /// runtime against a package script (`node …/claude-code/cli.js`), where
    /// only the package directory carries the name.
    private var pathFragments: [String] {
        switch self {
        case .claude: ["claude-code", "claude"]
        case .codex: ["codex-cli", "codex"]
        case .gemini: ["gemini-cli", "gemini"]
        case .aider: ["aider"]
        // Installs to `~/.kimi-code/bin/kimi` but execs with argv[0]
        // `kimi-code`, so neither name alone covers both halves.
        case .kimi: ["kimi-code", "kimi-cli", "kimi"]
        // Native installs exec `~/.local/bin/grok`; npm installs exec a
        // runtime against the `grok-cli` package script.
        case .grok: ["grok-cli", "grok"]
        }
    }

    /// Runtimes whose first argument names the real program. Only these get
    /// their argv inspected, so an editor opened on `claude.md` isn't mistaken
    /// for the agent itself.
    private static let scriptRuntimes: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby",
    ]

    /// Depth of the process walk below the recorded shell. An agent launched
    /// straight from the prompt is depth 1; a couple of extra levels cover
    /// wrappers like `env`, `npx`, or a nested shell.
    private static let maxDepth = 4

    /// Claude can leave its composer cursor visible while delegated work is
    /// active, while Kimi and Grok keep the native cursor hidden even when
    /// idle. Those agents therefore also need status text near the bottom of
    /// the viewport to distinguish an active turn from an open, idle TUI.
    var needsVisibleTerminalContentsForActivity: Bool {
        self == .claude || self == .grok || self == .kimi
    }

    func activity(
        cursorVisible: Bool,
        visibleTerminalContents: String? = nil
    ) -> TerminalProcessActivity {
        // Only inspect the status area. Completed responses can contain words
        // such as "thinking" or "running" higher in the viewport, and a
        // background command is not the same thing as an active agent turn.
        let statusLines = visibleTerminalContents?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(14)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? []
        switch self {
        case .claude:
            // Claude's footer is authoritative when a background task or
            // subagent leaves the input composer usable during the turn.
            let isActive = statusLines.suffix(4).contains { line in
                line.contains("esc to interrupt")
            }
            return !cursorVisible || isActive ? .running : .idle
        case .grok:
            let activeStatusMarkers = [
                "command still running",
                "commands still running",
                "compacting",
                "responding",
                "retrying (",
                "running tool",
                "running:",
                "thinking",
            ]
            let isActive = statusLines.contains { line in
                activeStatusMarkers.contains { line.contains($0) }
                    && !line.contains("expand thinking")
            }
            return isActive ? .running : .idle
        case .kimi:
            let isActive = statusLines.contains { line in
                line.contains("coder agent running")
                    || line.contains("thinking...")
                    || line.contains("thinking…")
            }
            return isActive ? .running : .idle
        case .codex, .gemini, .aider:
            return cursorVisible ? .idle : .running
        }
    }

    /// The first agent found among `pid`'s descendants, or `nil` if none is
    /// started. `pid` itself is the shell, so it is never matched.
    static func started(under pid: pid_t) -> TerminalAgent? {
        descendantAgent(of: pid, depth: 0)
    }

    private static func descendantAgent(of pid: pid_t, depth: Int) -> TerminalAgent? {
        guard depth < maxDepth else { return nil }
        for child in childPIDs(of: pid) {
            if let agent = agent(ofPID: child) { return agent }
            if let agent = descendantAgent(of: child, depth: depth + 1) { return agent }
        }
        return nil
    }

    private static func agent(ofPID pid: pid_t) -> TerminalAgent? {
        match(executablePath: executablePath(of: pid), arguments: processArguments(of: pid))
    }

    /// The agent identified by a process's executable path and argument vector,
    /// or `nil` for anything else. Pure and side-effect free so the matching
    /// rules can be tested without live processes.
    static func match(executablePath: String?, arguments: [String]) -> TerminalAgent? {
        var candidates: [String] = []
        if let executablePath { candidates.append(executablePath) }

        if let argv0 = arguments.first {
            candidates.append(argv0)
            // A script runtime's own name never identifies the agent, but the
            // script it was handed does. Restricting argv inspection to these
            // keeps `vim /tmp/claude.md` from reading as the agent itself.
            if scriptRuntimes.contains(basename(argv0).lowercased()), arguments.count > 1 {
                candidates.append(arguments[1])
            }
        }

        for candidate in candidates.map({ $0.lowercased() }) {
            let name = basename(candidate)
            // Match whole path components so `claude` hits `…/claude-code/cli.js`
            // and `…/share/claude/versions/2.1.215`, but not `…/notclaude/run.js`.
            let components = candidate.split(separator: "/").map(String.init)
            for agent in TerminalAgent.allCases {
                if name == agent.rawValue { return agent }
                if agent.pathFragments.contains(where: components.contains) { return agent }
            }
        }
        return nil
    }

    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func executablePath(of pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` is a macro that doesn't import into Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        // The sizing call reports bytes, but the filling call returns a *count*
        // of pids. Size generously from the hint and pad for children forked
        // between the two calls.
        let sizeHint = proc_listchildpids(pid, nil, 0)
        guard sizeHint > 0 else { return [] }
        let capacity = Int(sizeHint) / MemoryLayout<pid_t>.size + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listchildpids(pid, $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(Int(count), capacity))).filter { $0 > 0 }
    }

    /// Reads a process's argument vector via `KERN_PROCARGS2`. The buffer holds
    /// `argc` as an `Int32`, then the NUL-terminated exec path, then NUL
    /// padding, then `argc` NUL-terminated arguments.
    private static func processArguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var start = index
        while index < size, arguments.count < Int(argc) {
            if buffer[index] == 0 {
                if index > start, let argument = String(bytes: buffer[start..<index], encoding: .utf8) {
                    arguments.append(argument)
                }
                start = index + 1
            }
            index += 1
        }
        return arguments
    }
}

struct LiveTerminalAgent: Equatable, Sendable {
    let agent: TerminalAgent
    let activity: TerminalProcessActivity
}
