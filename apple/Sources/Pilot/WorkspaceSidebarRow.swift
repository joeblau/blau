import SwiftUI

/// One workspace row in the sidebar: an in-place rename field, the current
/// git branch as secondary text, the badge count, and the row's context menu.
///
/// Every row puts the branch on its own line under the name. Trailing it
/// inline instead loses it entirely on a narrow sidebar: the name field is
/// greedy, so the branch compresses to nothing before the field gives up any
/// width.
struct WorkspaceSidebarRow: View {
    let workspace: Workspace
    let branch: String?
    @FocusState.Binding var renamingWorkspaceID: UUID?
    let store: WorkspaceStore
    let onUpdateRootPath: () -> Void

    var body: some View {
        // Hidden while renaming so the branch never competes with the field
        // the user is typing in.
        let branch = renamingWorkspaceID == workspace.id ? nil : branch

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                TextField("Name", text: Bindable(workspace).name)
                    .focused($renamingWorkspaceID, equals: workspace.id)
                    .onSubmit {
                        renamingWorkspaceID = nil
                    }
                    .layoutPriority(1)

                // The gauge outranks the name field for space. The field is
                // greedy, so without a higher priority and a fixed size the
                // ring gets truncated away.
                WorkspaceLLMGauge(workspace: workspace, store: store)
                    .fixedSize()
                    .layoutPriority(2)
            }

            if let branch {
                branchLabel(branch)
            }
        }
        .tag(SidebarSelection.workspace(workspace.id))
        .contextMenu {
            Button {
                let workspaceID = workspace.id
                DispatchQueue.main.async {
                    renamingWorkspaceID = workspaceID
                }
            } label: {
                Label("Rename Workspace", systemImage: "pencil")
            }

            Button(action: onUpdateRootPath) {
                Label("Update Root Path", systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()

            Button {
                store.togglePin(workspace)
            } label: {
                Label(
                    workspace.isPinned ? "Unpin" : "Pin",
                    systemImage: workspace.isPinned ? "pin.slash" : "pin"
                )
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.deleteWorkspace(workspace)
            }
        }
    }

    private func branchLabel(_ branch: String) -> some View {
        Text(branch)
            .scaledFont(size: 10)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help("On branch \(branch)")
            .accessibilityLabel("On branch \(branch)")
    }
}

/// Ring gauge showing `agents working / agents started` for a workspace. A
/// terminal with an idle agent TUI contributes only to the denominator, so
/// three agents all waiting for input reads `0/3`. Hidden when no agent is
/// currently started, even if the workspace has ordinary terminal panes.
///
/// Polls the process tree every couple of seconds — the same walk the pane
/// header's agent capsule uses, resolving each pane's shell pid from tmux.
///
/// Clicking the ring while at least one agent is running jumps straight to
/// the working pane: it activates the workspace (leaving Notes or any other
/// full-detail mode), expands the pane if collapsed, and selects it.
private struct WorkspaceLLMGauge: View {
    let workspace: Workspace
    let store: WorkspaceStore
    @State private var running = 0
    @State private var started = 0
    @State private var runningPaneIDs: Set<UUID> = []

    /// Row budget for the gauge, and the factor that gets `.accessoryCircular`
    /// down to it. Kept together so the two never drift apart: the scale is
    /// what makes the style fit the frame, not an independent tuning knob.
    private static let diameter: CGFloat = 26
    private static let scale: CGFloat = 0.5

    var body: some View {
        // A ZStack, never a Group: Group hands its modifiers to its children,
        // and this one starts with no children because `started` is 0 until the
        // first poll. The `.task` had nothing to attach to, so the poll never
        // ran, so `started` stayed 0 — the gauge could never appear. A real
        // container keeps the task alive while the ring is still absent.
        ZStack {
            if started > 0 {
                // Keep the title label empty so the compact style spends all
                // of its center on the explicit running/started ratio.
                Gauge(value: Double(running), in: 0...Double(started)) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(running)/\(started)")
                        .monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
                .tint(gaugeTint)
                // `.accessoryCircular` is sized for widgets and watch
                // complications, so at natural size it is several times the
                // height of a sidebar row. Scale the rendered gauge down and
                // pin the layout box to what the row can actually spend.
                .scaleEffect(Self.scale)
                .frame(width: Self.diameter, height: Self.diameter)
                .animation(.easeInOut(duration: 0.2), value: running)
                .animation(.easeInOut(duration: 0.2), value: started)
                .help(gaugeDescription)
                .accessibilityLabel(gaugeDescription)
                // Tappable only while an agent is running; an idle ring has
                // no pane to jump to.
                .contentShape(Rectangle())
                .onTapGesture(perform: selectRunningPane)
                .allowsHitTesting(running > 0)
            }
        }
        // Zero-width while empty so a workspace with no started agent does not
        // reserve a hole where the ring would be.
        .frame(width: started > 0 ? Self.diameter : 0)
        .task {
            while !Task.isCancelled {
                let terminals = workspace.panes.filter { $0.kind == .terminal }
                var nextStarted = 0
                var nextRunningPaneIDs: Set<UUID> = []
                for pane in terminals {
                    guard let status = await pane.liveShellAgentStatus() else { continue }
                    nextStarted += 1
                    if status.activity == .running {
                        nextRunningPaneIDs.insert(pane.id)
                    }
                }
                started = nextStarted
                runningPaneIDs = nextRunningPaneIDs
                running = nextRunningPaneIDs.count
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Jump to the first pane reported active by the latest poll.
    private func selectRunningPane() {
        let terminals = workspace.panes.filter { $0.kind == .terminal }
        guard let pane = terminals.first(where: { runningPaneIDs.contains($0.id) }) else { return }
        store.selectWorkspace(workspace.id)
        if pane.isCollapsed {
            workspace.expandPane(pane)
        }
        workspace.selectedPaneID = pane.id
    }

    /// Idle drops to the quaternary label color so quiet workspaces recede
    /// into the sidebar instead of every ring sitting at accent strength. A
    /// concrete NSColor, not the hierarchical `.quaternary`: the gauge's tint
    /// doesn't resolve hierarchical styles and falls back to accent.
    private var gaugeTint: Color {
        if running == 0 { return Color(nsColor: .quaternaryLabelColor) }
        if running == started { return .green }
        return .accentColor
    }

    /// Spell out both sides for the tooltip and VoiceOver.
    private var gaugeDescription: String {
        let agents = started == 1 ? "agent" : "agents"
        if running == 0 {
            return "0 of \(started) started \(agents) working"
        }
        return "\(running) of \(started) started \(agents) working. Click to jump to a pane."
    }
}
