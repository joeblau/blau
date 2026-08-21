import SwiftUI

/// One workspace row in the sidebar: an in-place rename field, the current
/// git branch as secondary text, the badge count, and the row's context menu.
///
/// Pinned rows put the branch on its own line under the name; unpinned rows
/// keep it trailing inline so their single-line height is preserved.
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

                if !workspace.isPinned, let branch {
                    branchLabel(branch)
                        .layoutPriority(0)
                }

                // The gauge outranks both the name field and the branch for
                // space. The field is greedy, so without a higher priority and
                // a fixed size the ring gets truncated away.
                WorkspaceLLMGauge(workspace: workspace)
                    .fixedSize()
                    .layoutPriority(2)
            }

            if workspace.isPinned, let branch {
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

    var body: some View {
        Group {
            if total > 0 {
                let fraction = Double(working) / Double(total)
                ZStack {
                    Circle()
                        .stroke(.secondary.opacity(0.25), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(
                            working == total ? Color.green : Color.accentColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 11, height: 11)
                .animation(.easeInOut(duration: 0.2), value: fraction)
                .help("\(working) of \(total) LLM panes working")
                .accessibilityLabel("\(working) of \(total) LLM panes working")
            }
        }
        .task {
            while !Task.isCancelled {
                let terminals = workspace.panes.filter { $0.kind == .terminal }
                total = terminals.count
                working = terminals.count { $0.liveShellAgent() != nil }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
