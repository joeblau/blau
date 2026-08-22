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
                WorkspaceLLMGauge(workspace: workspace)
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

/// Ring gauge showing how much of a workspace's LLM capacity is in use: the
/// fraction of its terminal panes whose shell currently has a coding agent
/// (Claude, Codex, …) running underneath it. A full ring means every terminal
/// pane is working. Hidden for workspaces with no terminal panes.
///
/// Polls the process tree every couple of seconds — the same cheap
/// kernel-level walk the pane header's agent capsule uses, never a subprocess.
private struct WorkspaceLLMGauge: View {
    let workspace: Workspace
    @State private var working = 0
    @State private var total = 0

    /// Row budget for the gauge, and the factor that gets `.accessoryCircular`
    /// down to it. Kept together so the two never drift apart: the scale is
    /// what makes the style fit the frame, not an independent tuning knob.
    private static let diameter: CGFloat = 22
    private static let scale: CGFloat = 0.42

    var body: some View {
        // A ZStack, never a Group: Group hands its modifiers to its children,
        // and this one starts with no children because `total` is 0 until the
        // first poll. The `.task` had nothing to attach to, so the poll never
        // ran, so `total` stayed 0 — the gauge could never appear. A real
        // container keeps the task alive while the ring is still absent.
        ZStack {
            if total > 0 {
                // No label view: `.accessoryCircular` renders one under the
                // ring, where a word at this scale is an illegible smudge.
                // VoiceOver still gets the full description below.
                Gauge(value: Double(working), in: 0...Double(total)) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(working)")
                }
                .gaugeStyle(.accessoryCircular)
                .tint(working == total ? Color.green : Color.accentColor)
                // `.accessoryCircular` is sized for widgets and watch
                // complications, so at natural size it is several times the
                // height of a sidebar row. Scale the rendered gauge down and
                // pin the layout box to what the row can actually spend.
                .scaleEffect(Self.scale)
                .frame(width: Self.diameter, height: Self.diameter)
                // Idle is the common state, so the whole gauge recedes rather
                // than sitting at full strength on every quiet workspace. The
                // system draws `.accessoryCircular`'s track for us, so this is
                // the knob we have for "very subtle".
                .opacity(working == 0 ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.2), value: working)
                .help(gaugeDescription)
                .accessibilityLabel(gaugeDescription)
            }
        }
        // Zero-width while empty so a workspace with no terminal panes does not
        // reserve a hole where the ring would be.
        .frame(width: total > 0 ? Self.diameter : 0)
        .task {
            while !Task.isCancelled {
                let terminals = workspace.panes.filter { $0.kind == .terminal }
                total = terminals.count
                working = terminals.count { $0.liveShellAgent() != nil }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Spelled out for the tooltip and VoiceOver, where "0 of 4" alone reads as
    /// a broken gauge rather than an idle one.
    private var gaugeDescription: String {
        let panes = total == 1 ? "pane" : "panes"
        if working == 0 {
            return "No agents running in \(total) terminal \(panes)"
        }
        return "\(working) of \(total) terminal \(panes) running an agent"
    }
}
