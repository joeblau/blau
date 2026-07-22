import Foundation
import Testing
@testable import Pilot

/// The rules deciding whether a process running under a terminal pane's shell
/// is a coding agent. Real installs vary a lot in shape — native binaries,
/// version-numbered executables, and npm shims that exec a JS runtime — and a
/// false positive puts a wrong badge on the tab, so the negative cases matter
/// as much as the positive ones.
@Suite("Terminal agent process matching")
struct TerminalAgentTests {
    // MARK: - Native installs

    @Test
    func matchesNativeBinaryByName() {
        let agent = TerminalAgent.match(
            executablePath: "/Users/j/.local/bin/claude",
            arguments: ["/Users/j/.local/bin/claude"]
        )
        #expect(agent == .claude)
    }

    /// Claude Code's native install execs a version-numbered file, so the
    /// basename carries no agent name at all — only the enclosing directory.
    @Test
    func matchesVersionedNativeBinaryByDirectory() {
        let agent = TerminalAgent.match(
            executablePath: "/Users/j/.local/share/claude/versions/2.1.215",
            arguments: ["/Users/j/.local/share/claude/versions/2.1.215"]
        )
        #expect(agent == .claude)
    }

    @Test
    func matchesCodexVendorBinary() {
        let path = "/Users/j/.nvm/versions/node/v24.10.0/lib/node_modules/@openai/codex"
            + "/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        #expect(TerminalAgent.match(executablePath: path, arguments: [path]) == .codex)
    }

    // MARK: - Script-runtime installs

    /// An npm install execs `node …/claude-code/cli.js`: the executable is the
    /// runtime, and only argv[1] names the agent.
    @Test
    func matchesNpmShimThroughScriptRuntime() {
        let agent = TerminalAgent.match(
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]
        )
        #expect(agent == .claude)
    }

    @Test
    func matchesAiderThroughPython() {
        let agent = TerminalAgent.match(
            executablePath: "/opt/homebrew/bin/python3",
            arguments: ["python3", "/opt/homebrew/lib/python3.12/site-packages/aider/main.py"]
        )
        #expect(agent == .aider)
    }

    // MARK: - Non-agents

    /// The case that motivates restricting argv inspection to script runtimes:
    /// an editor opened on a file named after an agent is not the agent.
    @Test
    func doesNotMatchEditorOpenedOnAgentNamedFile() {
        let agent = TerminalAgent.match(
            executablePath: "/usr/bin/vim",
            arguments: ["vim", "/Users/j/project/claude.md"]
        )
        #expect(agent == nil)
    }

    @Test
    func doesNotMatchArbitraryArgumentsOfNonRuntime() {
        let agent = TerminalAgent.match(
            executablePath: "/bin/cat",
            arguments: ["cat", "/Users/j/.claude/settings.json"]
        )
        #expect(agent == nil)
    }

    /// Component matching must not fire on a directory that merely embeds an
    /// agent name inside a longer word.
    @Test
    func doesNotMatchSubstringOfLongerPathComponent() {
        let agent = TerminalAgent.match(
            executablePath: "/Users/j/src/notclaude/build/run",
            arguments: ["/Users/j/src/notclaude/build/run"]
        )
        #expect(agent == nil)
    }

    @Test
    func doesNotMatchIdleShell() {
        #expect(TerminalAgent.match(executablePath: "/bin/zsh", arguments: ["-zsh"]) == nil)
    }

    @Test
    func doesNotMatchBareScriptRuntime() {
        let agent = TerminalAgent.match(
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/Users/j/src/app/server.js"]
        )
        #expect(agent == nil)
    }

    @Test
    func returnsNilWithoutAnyProcessInformation() {
        #expect(TerminalAgent.match(executablePath: nil, arguments: []) == nil)
    }
}
