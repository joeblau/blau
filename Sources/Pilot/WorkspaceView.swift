import SwiftUI
import SwiftTerm

struct WorkspaceView: View {
    let workspace: Workspace

    var body: some View {
        TerminalViewRepresentable()
            .navigationTitle(workspace.name)
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminalView = LocalProcessTerminalView(frame: .zero)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        terminalView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        terminalView.startProcess(executable: shell, environment: nil, execName: "-" + (shell as NSString).lastPathComponent)
        terminalView.send(txt: "cd \(home)\r")

        return terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
