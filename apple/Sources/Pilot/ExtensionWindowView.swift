import AppKit
import SwiftUI

enum PilotWindowID {
    static let `extension` = "pilot-extension"
}

/// Reports the concrete AppKit window that owns the main Pilot surface. The
/// screen mirror uses its window number (the same ID ScreenCaptureKit exposes)
/// so a larger extension window can never become the mirrored target.
@MainActor
struct PilotMainWindowReader: NSViewRepresentable {
    var onWindowChange: @MainActor (CGWindowID?) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        WindowReaderView(onWindowChange: onWindowChange)
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        nsView.onWindowChange = onWindowChange
    }

    @MainActor
    final class WindowReaderView: NSView {
        var onWindowChange: @MainActor (CGWindowID?) -> Void

        init(onWindowChange: @escaping @MainActor (CGWindowID?) -> Void) {
            self.onWindowChange = onWindowChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange(window.map { CGWindowID($0.windowNumber) })
        }
    }
}

/// Window-menu entry for restoring the singleton extension window after it has
/// been closed. `Window`, rather than `WindowGroup`, guarantees this action
/// focuses the existing companion instead of creating another copy.
struct PilotExtensionCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Show Extension") {
                openWindow(id: PilotWindowID.extension)
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
        }
    }
}

/// A lightweight companion to Pilot's live workspace window.
///
/// It intentionally hosts repository/usage tools rather than another
/// `WorkspaceView`: terminal, browser, device, and simulator surfaces have one
/// runtime owner per pane ID and cannot safely be mounted in two windows. Both
/// windows receive the same `WorkspaceStore`, so workspace selection is shared
/// directly and remains synchronized without a notification bridge.
struct ExtensionWindowView: View {
    @Bindable var store: WorkspaceStore

    @State private var gitStore = GitCommitStore()
    @State private var tasksStore = GitHubTasksStore()
    @State private var usageStore = UsageStore()

    var body: some View {
        let _ = store.changeCount // observe add/delete/reorder changes
        let workspaces = store.workspaces
        let repoPath = store.selectedWorkspace?.effectiveRootPath

        NavigationSplitView {
            List(selection: selectedWorkspaceIDBinding) {
                Section("Workspaces") {
                    ForEach(workspaces) { workspace in
                        workspaceRow(workspace)
                            .tag(workspace.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 280)
            .accessibilityIdentifier("extension.workspaces")
        } detail: {
            if let workspace = store.selectedWorkspace {
                InspectorPanelView(
                    gitStore: gitStore,
                    tasksStore: tasksStore,
                    usageStore: usageStore,
                    selectedTab: inspectorTabBinding(for: workspace)
                )
                .navigationTitle(workspace.name)
                .navigationSubtitle("Extension")
                .id(workspace.id)
                .accessibilityIdentifier("extension.inspector")
            } else {
                ContentUnavailableView(
                    workspaces.isEmpty ? "No Workspaces" : "No Workspace Selected",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text(
                        workspaces.isEmpty
                            ? "Create a workspace in the main Pilot window."
                            : "Select a workspace to show its extension tools."
                    )
                )
                .navigationTitle("Extension")
                .accessibilityIdentifier("extension.empty")
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .task {
            usageStore.start()
        }
        .task(id: repoPath) {
            syncInspectorRepo(repoPath)
        }
        .onChange(of: store.selectedWorkspace?.inspectorTab) { _, tab in
            if tab == .usage { usageStore.reload() }
        }
        .onDisappear {
            gitStore.stopWatching()
            tasksStore.load(directory: nil)
            usageStore.stop()
        }
    }

    private var selectedWorkspaceIDBinding: Binding<UUID?> {
        Binding(
            get: { store.selectedWorkspaceID },
            set: { workspaceID in
                guard let workspaceID else { return }
                store.selectWorkspace(workspaceID)
            }
        )
    }

    private func inspectorTabBinding(for workspace: Workspace) -> Binding<InspectorTab> {
        Binding(
            get: { workspace.inspectorTab },
            set: { workspace.setInspectorTab($0) }
        )
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        HStack(spacing: 8) {
            Image(systemName: workspace.isPinned ? "pin.fill" : "rectangle.stack")
                .foregroundStyle(workspace.isPinned ? .secondary : .tertiary)
                .frame(width: 16)

            Text(workspace.name)
                .lineLimit(1)

            Spacer(minLength: 4)

            if workspace.badgeCount > 0 {
                Text("\(workspace.badgeCount)")
                    .scaledFont(size: 10, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red, in: Capsule())
            }
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("extension.workspace.\(workspace.id.uuidString)")
    }

    private func syncInspectorRepo(_ repoPath: String?) {
        guard let repoPath else {
            gitStore.stopWatching()
            tasksStore.load(directory: nil)
            return
        }

        gitStore.startWatching(directory: repoPath)
        tasksStore.load(directory: repoPath)
    }
}
