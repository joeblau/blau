import SwiftUI

enum TerminalToolbarSelection {
    static func pane(for pane: Pane?) -> Pane? {
        guard let pane,
              !pane.isCollapsed,
              pane.kind == .terminal else { return nil }
        return pane
    }
}

/// Per-terminal address-style command field. Actions are installed as separate
/// toolbar items so Play and Stop do not sit inside the field's capsule.
struct TerminalFastCommandToolbarField: View {
    let pane: Pane

    @AppStorage private var command: String

    init(pane: Pane) {
        self.pane = pane
        _command = AppStorage(
            wrappedValue: "",
            TerminalFastCommandStore.preferenceKey(for: pane.id)
        )
    }

    var body: some View {
        TextField("Fast Command", text: $command)
            .textFieldStyle(.plain)
            .scaledFont(size: 13, weight: .medium, design: .monospaced)
            .onSubmit(run)
            .padding(.horizontal, 12)
            .frame(minWidth: 220, idealWidth: 360, maxWidth: 480)
            .layoutPriority(1)
            .accessibilityIdentifier("terminal.fast-command")
    }

    private func run() {
        guard let command = TerminalFastCommandStore.executableCommand(from: command) else {
            return
        }
        Task {
            _ = await PersistentTerminalSession.runFastCommand(
                command,
                sessionName: pane.persistentSessionName
            )
        }
    }
}

struct TerminalFastCommandToolbarActions: View {
    let pane: Pane

    @AppStorage private var command: String
    @State private var activeAction: Action?

    private enum Action {
        case play
        case stop
    }

    init(pane: Pane) {
        self.pane = pane
        _command = AppStorage(
            wrappedValue: "",
            TerminalFastCommandStore.preferenceKey(for: pane.id)
        )
    }

    var body: some View {
        ControlGroup {
            Button(action: run) {
                actionLabel(for: .play, systemImage: "play.fill")
            }
            .disabled(activeAction != nil || executableCommand == nil)
            .help("Stop the active process and run this command")
            .accessibilityIdentifier("terminal.fast-command.play")

            Button(action: stop) {
                actionLabel(for: .stop, systemImage: "stop.fill")
            }
            .disabled(activeAction != nil)
            .help("Stop the active terminal process")
            .accessibilityIdentifier("terminal.fast-command.stop")
        }
        .controlGroupStyle(.navigation)
    }

    @ViewBuilder
    private func actionLabel(for action: Action, systemImage: String) -> some View {
        if activeAction == action {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: systemImage)
                .frame(width: 14, height: 14)
        }
    }

    private var executableCommand: String? {
        TerminalFastCommandStore.executableCommand(from: command)
    }

    private func run() {
        guard activeAction == nil, let executableCommand else { return }
        activeAction = .play
        Task {
            _ = await PersistentTerminalSession.runFastCommand(
                executableCommand,
                sessionName: pane.persistentSessionName
            )
            activeAction = nil
        }
    }

    private func stop() {
        guard activeAction == nil else { return }
        activeAction = .stop
        Task {
            _ = await PersistentTerminalSession.stopForegroundCommand(
                sessionName: pane.persistentSessionName
            )
            activeAction = nil
        }
    }
}
