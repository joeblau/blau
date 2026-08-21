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

                // The count outranks both the name field and the branch for
                // space. The field is greedy, so without a higher priority and
                // a fixed size the digits get truncated away and the capsule
                // renders empty.
                if workspace.badgeCount > 0 {
                    Text("\(workspace.badgeCount)")
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.red, in: Capsule())
                        .fixedSize()
                        .layoutPriority(2)
                }
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
