import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    var syncService: PeerSyncService
    var peerDeviceStatus: DeviceStatus
    var localAudioOutput: AudioOutputDevice?
    var isPlotterConnected: Bool
    var remoteInkModel: RemoteInkModel
    /// Reflects whether a Copilot peer is currently push-to-talking. The
    /// transcription itself runs on the iPhone now — Pilot only paints
    /// the "listening" indicator and pastes the finished text.
    var isPeerRecording: Bool
    @State private var gitStore = GitCommitStore()
    @State private var tasksStore = GitHubTasksStore()
    @State private var isDrawingActive = false
    @AppStorage("sidebar.pinnedExpanded") private var pinnedSectionExpanded = true
    @AppStorage("sidebar.workspacesExpanded") private var workspacesSectionExpanded = true
    @FocusState private var isBrowserURLFieldFocused: Bool
    @State private var notesToggleMonitor: Any?

    var body: some View {
        let activeInspectorRepoPath = isInspectorPresentedForSelectedWorkspace ? selectedWorkspaceRootPath : nil
        let _ = store.changeCount  // observation dependency for pin/unpin re-sort
        let workspaces = store.workspaces
        let workspaceShortcutIDs = workspaces.prefix(9).map(\.id)

        NavigationSplitView {
            List(selection: sidebarSelectionBinding) {
                let pinned = workspaces.filter(\.isPinned)
                let unpinned = workspaces.filter { !$0.isPinned }

                Section {
                    Label("Notes", systemImage: "note.text")
                        .tag(SidebarSelection.notes)
                    Label("Remote Desktop", systemImage: "macbook.and.iphone")
                        .tag(SidebarSelection.remoteDesktop)
                }

                if !pinned.isEmpty {
                    Section(isExpanded: $pinnedSectionExpanded) {
                        ForEach(pinned) { workspace in
                            workspaceRow(workspace)
                        }
                        .onMove(perform: store.movePinnedWorkspaces)
                    } header: {
                        Text("Pinned")
                    }
                }

                Section(isExpanded: $workspacesSectionExpanded) {
                    ForEach(unpinned) { workspace in
                        workspaceRow(workspace)
                    }
                    .onMove(perform: store.moveUnpinnedWorkspaces)
                } header: {
                    Text("Workspaces")
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    RecordingStatusIndicator(isRecording: isPeerRecording)

                    Spacer(minLength: 0)

                    HStack(spacing: 12) {
                        ForEach(connectedDevices) { device in
                            Image(systemName: device.kind.systemImageName)
                                .symbolVariant(device.kind.usesFillVariant ? .fill : .none)
                                .foregroundStyle(device.isConnected ? .green : .secondary)
                                .help(device.name ?? device.kind.displayName)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            ZStack {
                if workspaces.isEmpty {
                    ContentUnavailableView("No Workspace Selected",
                                           systemImage: "rectangle.on.rectangle.slash",
                                           description: Text("Create a workspace with the + button."))
                } else {
                    // The workspace stack stays mounted at all times — even in
                    // Notes mode — so entering Notes never tears down live
                    // terminals/browsers. Notes just deactivates every
                    // workspace, exactly like switching between workspaces does.
                    ZStack {
                        ForEach(workspaces) { workspace in
                            let isActive = !store.isNotesMode
                                && !store.isRemoteDesktopMode
                                && workspace.id == store.selectedWorkspaceID
                            WorkspaceView(workspace: workspace, isActive: isActive)
                                .zIndex(isActive ? 1 : 0)
                                .opacity(isActive ? 1 : 0)
                                .allowsHitTesting(isActive)
                                .accessibilityHidden(!isActive)
                        }
                    }

                    if !store.isNotesMode && !store.isRemoteDesktopMode && !hasSelectedWorkspace {
                        ContentUnavailableView("No Workspace Selected",
                                               systemImage: "rectangle.on.rectangle.slash",
                                               description: Text("Select a workspace from the sidebar."))
                    }
                }

                if store.isNotesMode {
                    NotesView(store: store)
                        .zIndex(100)
                }

                if store.isRemoteDesktopMode {
                    RemoteDesktopView(store: store)
                        .zIndex(100)
                }

                if isDrawingActive && !store.isNotesMode && !store.isRemoteDesktopMode && !workspaces.isEmpty {
                    InkOverlay(isActive: $isDrawingActive)
                        .zIndex(60)
                }
            }
            .navigationTitle(navigationTitle)
        }
        .inspector(isPresented: selectedWorkspaceInspectorPresentedBinding) {
            InspectorPanelView(
                gitStore: gitStore,
                tasksStore: tasksStore,
                selectedTab: selectedWorkspaceInspectorTabBinding
            )
                .inspectorColumnWidth(min: 220, ideal: 280, max: 400)
        }
        .onChange(of: activeInspectorRepoPath) {
            syncInspectorRepo(activeInspectorRepoPath)
        }
        .onChange(of: store.selectedWorkspaceID) {
            syncSelectedWorkspaceRootPath()
            if let workspace = store.selectedWorkspace {
                for pane in workspace.panes where pane.kind == .terminal {
                    pane.resetBellCount()
                }
            }
            focusSelectedWorkspaceTerminal()
        }
        .onChange(of: remoteInkModel.changeID) {
            guard remoteInkModel.hasInk,
                  !store.isNotesMode,
                  !workspaces.isEmpty else { return }
            isDrawingActive = true
        }
        .task {
            syncSelectedWorkspaceRootPath()
            syncInspectorRepo(activeInspectorRepoPath)
            focusSelectedWorkspaceTerminal()
        }
        .onAppear { installNotesToggleMonitor() }
        .onDisappear { removeNotesToggleMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: .pilotFocusBrowserAddressBar)) { _ in
            focusBrowserAddressBar()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: store.addWorkspace) {
                    Label("New Workspace", systemImage: "plus")
                }
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                if !store.isNotesMode,
                   let pane = store.selectedWorkspace?.selectedPane,
                   pane.kind == .browser,
                   let browserState = pane.browserState {
                    browserToolbar(state: browserState)
                } else if !store.isNotesMode,
                          let pane = store.selectedWorkspace?.selectedPane,
                          pane.kind == .device {
                    deviceToolbar(paneID: pane.id)
                } else if !store.isNotesMode,
                          let pane = store.selectedWorkspace?.selectedPane,
                          pane.kind == .simulator {
                    simulatorToolbar(paneID: pane.id)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                ControlGroup {
                    // ⌘T / ⌘B live as main-menu commands (see PilotApp.commands)
                    // so a focused browser web view can't swallow them.
                    Button {
                        store.selectedWorkspace?.addPane(kind: .terminal, side: .right)
                    } label: {
                        Label("New Terminal", systemImage: "terminal")
                    }

                    Button {
                        store.selectedWorkspace?.addPane(kind: .browser, side: .right)
                    } label: {
                        Label("New Browser", systemImage: "safari")
                    }

                    Button {
                        store.selectedWorkspace?.addPane(kind: .device, side: .right)
                    } label: {
                        Label("New Device", systemImage: "apps.iphone")
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])

                    Button {
                        store.selectedWorkspace?.addPane(kind: .simulator, side: .right)
                    } label: {
                        Label("New Simulator", systemImage: "ipad.landscape.and.ipod")
                    }
                    .keyboardShortcut("s", modifiers: [.command, .shift])

                    editorToolbarButton

                    openInFinderButton
                }
                // Render the six "New …" pane actions as one connected group
                // rather than separate circular toolbar buttons.
                .controlGroupStyle(.navigation)
                .disabled(store.selectedWorkspace == nil || store.isNotesMode)
                Button {
                    isDrawingActive.toggle()
                } label: {
                    Label("Annotate",
                          systemImage: isDrawingActive ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                }
                .disabled(store.selectedWorkspace == nil || store.isNotesMode)
                .help("Draw over the active pane (⇧⌘D)")
                Button {
                    guard let workspace = store.selectedWorkspace else { return }
                    workspace.setInspectorPresented(!workspace.isInspectorPresented)
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .disabled(store.selectedWorkspace == nil || store.isNotesMode || store.isRemoteDesktopMode)
            }
        }
        .background {
            Group {
                ForEach(1...9, id: \.self) { index in
                    Button("") {
                        guard index - 1 < workspaceShortcutIDs.count else { return }
                        store.isNotesMode = false
                        store.isRemoteDesktopMode = false
                        store.selectedWorkspaceID = workspaceShortcutIDs[index - 1]
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    .hidden()
                }
            }
            .id(workspaceShortcutIDs)
            Button("") {
                // ⌘W closes what's in front: the active note tab in Notes
                // mode, otherwise the selected workspace pane.
                if store.isNotesMode {
                    guard let note = store.selectedNote else { return }
                    store.requestCloseNote(note)
                    return
                }
                guard let workspace = store.selectedWorkspace,
                      let pane = workspace.selectedPane else { return }
                workspace.removePane(pane)
            }
            .keyboardShortcut("w", modifiers: .command)
            .hidden()
            Button("") {
                guard store.selectedWorkspace != nil, !store.isNotesMode else { return }
                isDrawingActive.toggle()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .hidden()
            Button("") {
                store.selectedWorkspace?.selectNextPane()
                focusSelectedPaneIfTerminal()
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .hidden()
            Button("") {
                store.selectedWorkspace?.selectPreviousPane()
                focusSelectedPaneIfTerminal()
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .hidden()
        }
        // Remote ink (from Plotter) overlays the entire Pilot window — sidebar
        // and detail — so its strokes line up with what Plotter mirrors, which
        // is the whole window. It's non-interactive, so the UI beneath stays
        // fully usable.
        .overlay {
            if remoteInkModel.hasInk {
                RemoteInkOverlay(model: remoteInkModel)
                    .ignoresSafeArea()
            }
        }
        // Undo / clear controls for the Plotter-drawn ink. Interactive (unlike
        // the render-only overlay above); commands round-trip to the iPad.
        .overlay(alignment: .bottomTrailing) {
            if remoteInkModel.hasInk {
                RemoteInkControls(model: remoteInkModel)
                    .padding(16)
            }
        }
    }

    /// Bridges the single-typed `List` selection to the store's split state:
    /// Notes mode lives in `isNotesMode`, workspace selection in
    /// `selectedWorkspaceID`. Selecting a workspace row (even the one already
    /// backing `selectedWorkspaceID`) flips out of Notes mode, because the
    /// selection value changes from `.notes` to `.workspace`.
    private var navigationTitle: String {
        if store.isNotesMode { return "Notes" }
        if store.isRemoteDesktopMode { return "Remote Desktop" }
        return store.selectedWorkspace?.name ?? ""
    }

    private var sidebarSelectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: {
                if store.isNotesMode { return .notes }
                if store.isRemoteDesktopMode { return .remoteDesktop }
                if let id = store.selectedWorkspaceID { return .workspace(id) }
                return nil
            },
            set: { newValue in
                switch newValue {
                case .notes:
                    store.enterNotesMode()
                case .remoteDesktop:
                    store.enterRemoteDesktopMode()
                case .workspace(let id):
                    store.isNotesMode = false
                    store.isRemoteDesktopMode = false
                    store.selectedWorkspaceID = id
                case nil:
                    break
                }
            }
        )
    }

    /// ⌘0 toggles Notes ↔ the current workspace from anywhere. We use a local
    /// `NSEvent` monitor rather than only a menu shortcut because monitors run
    /// before key-equivalent dispatch and before the focused view — so it beats
    /// both Ghostty (which binds ⌘0 to reset-font-size) and the notes editor's
    /// field editor. `⌥⌘0` (Actual Size) is excluded by the exact-flags check.
    private func installNotesToggleMonitor() {
        guard notesToggleMonitor == nil else { return }
        notesToggleMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command,
                  event.charactersIgnoringModifiers == "0" else {
                return event
            }
            store.toggleNotesMode()
            return nil
        }
    }

    private func removeNotesToggleMonitor() {
        if let monitor = notesToggleMonitor {
            NSEvent.removeMonitor(monitor)
            notesToggleMonitor = nil
        }
    }

    private func focusSelectedPaneIfTerminal() {
        guard let pane = store.selectedWorkspace?.selectedPane,
              pane.kind == .terminal else { return }
        DispatchQueue.main.async {
            _ = GhosttyMetalView.focus(paneID: pane.id)
        }
    }

    private var connectedDevices: [ConnectedDevice] {
        let audioDevice = ConnectedDevice(
            kind: localAudioOutput?.kind ?? .headphonesBluetooth,
            isConnected: localAudioOutput != nil,
            name: localAudioOutput?.name
        )
        return [
            ConnectedDevice(kind: .iphone, isConnected: syncService.isConnected),
            ConnectedDevice(kind: .ipad, isConnected: isPlotterConnected),
            ConnectedDevice(kind: .appleWatch, isConnected: peerDeviceStatus.isWatchConnected),
            audioDevice
        ]
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        HStack {
            TextField("Name", text: Bindable(workspace).name)
            if workspace.badgeCount > 0 {
                Text("\(workspace.badgeCount)")
                    .scaledFont(size: 10, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red, in: Capsule())
            }
        }
        .tag(SidebarSelection.workspace(workspace.id))
        .contextMenu {
            Button {
                presentRootPathPicker(for: workspace)
            } label: {
                Label("Update Root Path", systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()

            Button {
                store.togglePin(workspace)
            } label: {
                Label(
                    workspace.isPinned ? "Unpin" : "Pin to Top",
                    systemImage: workspace.isPinned ? "pin.slash" : "pin"
                )
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.deleteWorkspace(workspace)
            }
        }
    }

    @ViewBuilder
    private func deviceToolbar(paneID: UUID) -> some View {
        let session = DeviceCaptureRegistry.shared.session(for: paneID)
        let isStreaming = session.status == .streaming

        Button {
            session.toggleRecording()
        } label: {
            Label(
                session.isRecording ? "Stop Recording" : "Record Screen",
                systemImage: session.isRecording ? "stop.circle.fill" : "record.circle"
            )
            .foregroundStyle(session.isRecording ? .red : .primary)
        }
        .disabled(!isStreaming)
        .help(session.isRecording ? "Stop recording" : "Record the iPhone screen")

        Button {
            session.takeScreenshot()
        } label: {
            Label("Take Screenshot", systemImage: "camera")
        }
        .disabled(!isStreaming)
        .help("Save a screenshot of the iPhone screen to the Desktop")

        Button {
            session.copyScreenshotToClipboard()
        } label: {
            Label("Copy Screenshot", systemImage: "doc.on.clipboard")
        }
        .disabled(!isStreaming)
        .help("Copy a screenshot of the iPhone screen to the clipboard")

        // Same hammer the browser pane shows — opens the debugger for the
        // phone. Safari hosts iOS remote Web Inspector; this brings it
        // frontmost with the connected device ready (#75).
        Button {
            SafariWebInspector.open()
        } label: {
            Label("Developer Tools", systemImage: "hammer")
        }
        .help("Open Safari Web Inspector to debug this device")
    }

    @ViewBuilder
    private func simulatorToolbar(paneID: UUID) -> some View {
        let session = SimulatorRegistry.shared.session(for: paneID)
        let isStreaming = session.status == .streaming

        Button {
            session.chooseAnotherDevice()
        } label: {
            Label("Choose Device", systemImage: "list.bullet")
        }
        .help("Pick a different simulator")

        Button {
            session.shutdownSimulator()
        } label: {
            Label("Shutdown Simulator", systemImage: "power")
        }
        .disabled(session.bootedUDID == nil)
        .help("Power off the booted simulator")

        if isStreaming {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
                .help("Live")
        }
    }

    @ViewBuilder
    private func browserToolbar(state: BrowserState) -> some View {
        ControlGroup {
            Button { state.requestNavigationCommand("blau://back") } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!state.canGoBack)

            Button { state.requestNavigationCommand("blau://forward") } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!state.canGoForward)
        }

        browserAddressField(state: state)

        Menu {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                Button {
                    state.appearanceMode = mode
                } label: {
                    HStack {
                        Text(mode.rawValue)
                        if state.appearanceMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label("Appearance", systemImage: appearanceIcon(for: state.appearanceMode))
        }

        Menu {
            Button("Default Profile") {}
            Divider()
            Button("Manage Profiles...") {}
        } label: {
            Label("Profile", systemImage: "person.circle")
        }

        Button {
            state.toggleAnnotateMode()
        } label: {
            Label("Annotate", systemImage: "pencil.and.outline")
        }
        .foregroundStyle(state.annotateMode ? Color.accentColor : .primary)
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .help(state.annotateMode
              ? "Turn off Annotate (⇧⌘A)"
              : "Annotate a web element and send it to a terminal agent (⇧⌘A)")

        Button {
            state.toggleDeveloperTools()
        } label: {
            Label("Developer Tools", systemImage: "hammer")
        }
    }

    private func browserAddressField(state: BrowserState) -> some View {
        TextField("URL", text: Bindable(state).urlText)
            .textFieldStyle(.plain)
            .scaledFont(size: 13, weight: .medium)
            .focused($isBrowserURLFieldFocused)
            .onSubmit { state.navigate() }
            .padding(.leading, 12)
            .padding(.trailing, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                browserReloadButton(state: state)
                    .padding(.trailing, 10)
            }
            .frame(minWidth: 240, idealWidth: 420, maxWidth: 560)
    }

    private func browserReloadButton(state: BrowserState) -> some View {
        Button {
            if state.isLoading {
                state.requestNavigationCommand("blau://stop")
            } else {
                state.requestNavigationCommand("blau://reload")
            }
        } label: {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .scaledFont(size: 12, weight: .medium)
                    .opacity(state.isLoading ? 0 : 1)

                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help(state.isLoading ? "Stop" : "Reload")
    }

    private func appearanceIcon(for mode: AppearanceMode) -> String {
        switch mode {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    private var selectedWorkspaceInspectorTabBinding: Binding<InspectorTab> {
        Binding(
            get: { self.store.selectedWorkspace?.inspectorTab ?? .actions },
            set: { tab in
                self.store.selectedWorkspace?.setInspectorTab(tab)
            }
        )
    }

    private var selectedWorkspaceInspectorPresentedBinding: Binding<Bool> {
        Binding(
            get: { isInspectorPresentedForSelectedWorkspace },
            set: { isPresented in
                // Notes / Remote Desktop transiently hide the inspector by
                // forcing `get` to false. SwiftUI echoes that back through this
                // setter, which would otherwise persist `false` into the
                // workspace and lose its real state. Ignore writes while a
                // global mode is showing; only genuine in-workspace toggles
                // persist — so the panel restores to what it was on return.
                guard !store.isNotesMode, !store.isRemoteDesktopMode else { return }
                store.selectedWorkspace?.setInspectorPresented(isPresented)
            }
        )
    }

    private var isInspectorPresentedForSelectedWorkspace: Bool {
        !store.isNotesMode && !store.isRemoteDesktopMode
            && (store.selectedWorkspace?.isInspectorPresented ?? false)
    }

    private var hasSelectedWorkspace: Bool {
        guard let id = store.selectedWorkspaceID else { return false }
        return store.workspaces.contains { $0.id == id }
    }

    private var selectedBrowserState: BrowserState? {
        guard let pane = store.selectedWorkspace?.selectedPane,
              pane.kind == .browser else { return nil }
        return pane.browserState
    }

    private func focusBrowserAddressBar() {
        guard selectedBrowserState != nil else { return }

        // SwiftUI's `@FocusState` is flaky when the target TextField lives
        // inside a `ToolbarItem`, and `NSApp.sendAction(selectAll:)` only
        // works once the field editor is already first responder. Drop to
        // AppKit: walk the key window for our URL field (matched by
        // placeholder) and call `selectText(_:)`, which both takes first
        // responder and selects the existing text — exactly what Safari's
        // "Open Location" command does.
        isBrowserURLFieldFocused = true
        DispatchQueue.main.async {
            for window in NSApp.windows {
                if let field = Self.findAddressTextField(in: window.contentView)
                    ?? Self.findAddressTextField(in: window.contentView?.superview) {
                    field.selectText(nil)
                    return
                }
            }
        }
    }

    private static func findAddressTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField,
           field.placeholderString == "URL" {
            return field
        }
        for sub in view.subviews {
            if let found = findAddressTextField(in: sub) {
                return found
            }
        }
        return nil
    }

    private func focusSelectedWorkspaceTerminal() {
        guard let workspace = store.selectedWorkspace,
              let pane = workspace.frontmostTerminalPane else { return }
        workspace.setFrontmostTerminalPaneID(pane.id)
        DispatchQueue.main.async {
            _ = GhosttyMetalView.focus(paneID: pane.id)
        }
    }

    private var selectedWorkspaceRootPath: String? {
        store.selectedWorkspace?.effectiveRootPath
    }

    @ViewBuilder
    private var editorToolbarButton: some View {
        let rootPath = selectedWorkspaceRootPath
        Button {
            store.selectedWorkspace?.addPane(kind: .editor, side: .right)
        } label: {
            Label("Open Editor", systemImage: "curlybraces")
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(rootPath == nil)
        .help(rootPath == nil ? "Set a workspace root path to open the editor" : "Open a file editor with fuzzy file search")
    }

    /// Reveals the selected workspace's root directory in macOS Finder.
    @ViewBuilder
    private var openInFinderButton: some View {
        let rootPath = selectedWorkspaceRootPath
        Button {
            if let rootPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: rootPath))
            }
        } label: {
            Label("Open in Finder", systemImage: "folder")
        }
        .disabled(rootPath == nil)
        .help(rootPath == nil ? "Set a workspace root path to open it in Finder" : "Open the workspace folder in Finder")
    }

    private func syncSelectedWorkspaceRootPath() {
        store.selectedWorkspace?.syncDefaultRootPathIfNeeded()
    }

    /// Browse to and pick the workspace's root directory with AppKit's native
    /// folder panel (issue #65). The panel only returns directories that exist,
    /// so we get validation for free; cancelling leaves the path unchanged.
    /// Pilot ships unsandboxed, so the returned path is usable directly with no
    /// security-scoped bookmark.
    private func presentRootPathPicker(for workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Set Root Path"
        panel.message = "Choose the root directory for “\(workspace.name)”."
        // Seed the browser at the current root when one is set.
        if let current = workspace.effectiveRootPath {
            panel.directoryURL = URL(fileURLWithPath: current)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.setRootPath(url.path)
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

private struct RecordingStatusIndicator: View {
    let isRecording: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isRecording ? "waveform.circle.fill" : "waveform.circle")
                .foregroundStyle(isRecording ? .red : .secondary)

            Text(isRecording ? "Recording" : "Mic Idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Single-typed selection model for the sidebar `List`, which mixes the
/// permanent Notes row with the per-workspace rows.
enum SidebarSelection: Hashable {
    case notes
    case remoteDesktop
    case workspace(UUID)
}

extension Notification.Name {
    static let pilotFocusBrowserAddressBar = Notification.Name("pilotFocusBrowserAddressBar")
}


@MainActor
private enum ContentViewPreviewData {
    static let container: ModelContainer = {
        let schema = Schema([Workspace.self, Pane.self, BrowserState.self, EditorState.self, Note.self, RemoteDesktopConnection.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: configuration)
    }()
}

#Preview {
    ContentView(
        store: WorkspaceStore(modelContext: ContentViewPreviewData.container.mainContext),
        syncService: PeerSyncService(role: .advertiser, displayName: "Preview"),
        peerDeviceStatus: DeviceStatus(),
        localAudioOutput: nil,
        isPlotterConnected: false,
        remoteInkModel: RemoteInkModel(),
        isPeerRecording: false
    )
    .modelContainer(ContentViewPreviewData.container)
}
