import AppKit
import SwiftData
import SwiftUI

/// The connected pane launcher shared by Pilot's main and extension windows.
/// Supplying the owning workspace lets Extension reuse the exact controls while
/// keeping independent runtime IDs for every terminal, browser, and device.
struct WorkspacePaneLauncher: View {
    let workspace: Workspace?
    let isCompact: Bool

    init(workspace: Workspace?, isCompact: Bool = false) {
        self.workspace = workspace
        self.isCompact = isCompact
    }

    @ViewBuilder
    var body: some View {
        if isCompact {
            Menu {
                paneButtons
            } label: {
                Label("New Pane", systemImage: "plus.rectangle.on.rectangle")
            }
            .disabled(workspace == nil)
            .help("Open a view in this workspace")
            .accessibilityIdentifier("workspace.pane-launcher")
        } else {
            ControlGroup {
                paneButtons
            }
            .controlGroupStyle(.navigation)
            .disabled(workspace == nil)
            .accessibilityIdentifier("workspace.pane-launcher")
        }
    }

    @ViewBuilder
    private var paneButtons: some View {
        Button {
            workspace?.addPane(kind: .terminal, side: .right)
        } label: {
            Label("New Terminal", systemImage: PaneKind.terminal.systemImageName)
        }

        Button {
            workspace?.addPane(kind: .browser, side: .right)
        } label: {
            Label("New Browser", systemImage: PaneKind.browser.systemImageName)
        }

        Menu {
            Button {
                workspace?.addPane(kind: .simulator, side: .right)
            } label: {
                Label("Simulator", systemImage: PaneKind.simulator.systemImageName)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button {
                workspace?.addPane(kind: .device, side: .right)
            } label: {
                Label("Device Stream", systemImage: PaneKind.device.systemImageName)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        } label: {
            Label("Apple", systemImage: "apple.logo")
        }
        .help("Open an Apple Simulator or QuickTime device stream")
        .accessibilityIdentifier("workspace.apple-pane-launcher")

        Button {
            workspace?.addPane(kind: .android, side: .right)
        } label: {
            Label("New Android", systemImage: PaneKind.android.systemImageName)
        }

        Button {
            workspace?.addPane(kind: .editor, side: .right)
        } label: {
            Label("Open Editor", systemImage: PaneKind.editor.systemImageName)
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(workspace?.effectiveRootPath == nil)
        .help(
            workspace?.effectiveRootPath == nil
                ? "Set a workspace root path to open the editor"
                : "Open a file editor with fuzzy file search"
        )

        Button {
            if let rootPath = workspace?.effectiveRootPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: rootPath))
            }
        } label: {
            Label("Open in Finder", systemImage: "folder")
        }
        .disabled(workspace?.effectiveRootPath == nil)
        .help(
            workspace?.effectiveRootPath == nil
                ? "Set a workspace root path to open it in Finder"
                : "Open the workspace folder in Finder"
        )
    }
}

/// Shared ⌘1…⌘9 workspace-number mapping plus Main-window key
/// equivalents. Extension uses the same visible ordering from a scene menu so
/// focused AppKit panes cannot swallow its shortcuts.
struct WorkspaceNumberShortcut: Identifiable, Equatable {
    let number: Int
    let workspaceID: UUID

    var id: UUID { workspaceID }
}

struct WorkspaceNumberShortcuts: View {
    let workspaceIDs: [UUID]
    let onSelect: (UUID) -> Void

    var body: some View {
        Group {
            ForEach(Self.shortcuts(for: workspaceIDs)) { shortcut in
                Button("") {
                    onSelect(shortcut.workspaceID)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(shortcut.number)")), modifiers: .command)
                .hidden()
            }
        }
        .id(workspaceIDs)
    }

    static func shortcuts(for workspaceIDs: [UUID]) -> [WorkspaceNumberShortcut] {
        Array(workspaceIDs.prefix(9).enumerated()).map { index, workspaceID in
            WorkspaceNumberShortcut(number: index + 1, workspaceID: workspaceID)
        }
    }
}

/// Resolves the browser toolbar from the pane that owns it. Main and Extension
/// both use this gate so a collapsed/non-browser pane cannot leave stale
/// controls behind, and Extension always binds to its own persisted
/// `BrowserState` rather than the similarly selected pane in Main.
enum BrowserToolbarSelection {
    static func state(for pane: Pane?) -> BrowserState? {
        guard let pane,
              !pane.isCollapsed,
              pane.kind == .browser else { return nil }
        return pane.browserState
    }
}

struct BrowserBackForwardToolbarControls: View {
    let state: BrowserState

    var body: some View {
        ControlGroup {
            Button { state.requestNavigationCommand("blau://back") } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!state.canGoBack)
            .accessibilityIdentifier("browser.back")

            Button { state.requestNavigationCommand("blau://forward") } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!state.canGoForward)
            .accessibilityIdentifier("browser.forward")
        }
    }
}

/// The principal browser location field. A state-backed focus request lets ⌘L
/// reveal a collapsed browser first and focus this field when it actually
/// appears, instead of racing SwiftUI's toolbar installation.
struct BrowserAddressToolbarControl: View {
    let state: BrowserState
    let addressMinWidth: CGFloat
    let addressIdealWidth: CGFloat
    let addressMaxWidth: CGFloat

    @FocusState private var isAddressFocused: Bool

    init(
        state: BrowserState,
        addressMinWidth: CGFloat = 240,
        addressIdealWidth: CGFloat = 420,
        addressMaxWidth: CGFloat = 560
    ) {
        self.state = state
        self.addressMinWidth = addressMinWidth
        self.addressIdealWidth = addressIdealWidth
        self.addressMaxWidth = addressMaxWidth
    }

    var body: some View {

        TextField("URL", text: Bindable(state).urlText)
            .textFieldStyle(.plain)
            .scaledFont(size: 13, weight: .medium)
            .focused($isAddressFocused)
            .onSubmit { state.navigate() }
            .padding(.leading, 12)
            .padding(.trailing, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                browserReloadButton
                    .padding(.trailing, 10)
            }
            .frame(
                minWidth: addressMinWidth,
                idealWidth: addressIdealWidth,
                maxWidth: addressMaxWidth
            )
            .layoutPriority(1)
            .accessibilityIdentifier("browser.address")
            .onAppear(perform: fulfillFocusRequestIfNeeded)
            .onChange(of: state.needsAddressFocus) {
                fulfillFocusRequestIfNeeded()
            }
    }

    private func fulfillFocusRequestIfNeeded() {
        guard state.needsAddressFocus else { return }
        state.needsAddressFocus = false
        isAddressFocused = true
        BrowserAddressFocus.selectAddressFieldInKeyWindow()
    }

    private var browserReloadButton: some View {
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
        .accessibilityIdentifier("browser.reload")
    }
}

/// Complete navigation/location composition used by Main. Extension installs
/// these as separate navigation and principal toolbar items.
struct BrowserNavigationToolbarControls: View {
    let state: BrowserState

    var body: some View {
        BrowserBackForwardToolbarControls(state: state)
        BrowserAddressToolbarControl(state: state)
    }
}

/// Lower-priority browser actions are split from navigation so AppKit can move
/// them into toolbar overflow without also removing the address field.
struct BrowserToolsToolbarControls: View {
    let state: BrowserState

    var body: some View {

        Menu {
            Button("Default Profile") {}
            Divider()
            Button("Manage Profiles...") {}
        } label: {
            Label("Profile", systemImage: "person.circle")
        }
        .accessibilityIdentifier("browser.profile")

        ControlGroup {
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
                Label("Appearance", systemImage: appearanceIcon)
            }
            .help("Browser appearance: System, Light, or Dark")
            .accessibilityIdentifier("browser.appearance")

            Toggle(isOn: Binding(
                get: { state.annotateMode },
                set: { state.setAnnotateMode($0) }
            )) {
                Label("Lasso", systemImage: "lasso")
            }
            .toggleStyle(.button)
            .help(state.annotateMode
                  ? "Turn off Lasso (⇧⌘A)"
                  : "Select a web element and tell an agent what to fix (⇧⌘A)")
            .accessibilityIdentifier("browser.lasso")

            Button {
                state.toggleDeveloperTools()
            } label: {
                Label("Developer Tools", systemImage: "hammer")
            }
            .help(state.showDevTools ? "Close Developer Tools" : "Open Developer Tools")
            .accessibilityIdentifier("browser.developer-tools")
        }
        .controlGroupStyle(.navigation)
        .accessibilityIdentifier("browser.tools")
    }

    private var appearanceIcon: String {
        switch state.appearanceMode {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

/// Complete browser toolbar used by Main. Extension installs the same two
/// pieces as distinct toolbar items to retain the address field at small sizes.
struct BrowserToolbarControls: View {
    let state: BrowserState

    var body: some View {
        BrowserNavigationToolbarControls(state: state)
        BrowserToolsToolbarControls(state: state)
    }
}

/// AppKit bridge for Safari-style ⌘L behavior. Restricting the lookup to the
/// key window is what lets Main and Extension expose simultaneous address
/// fields without one window stealing focus from the other.
@MainActor
enum BrowserAddressFocus {
    static func selectAddressFieldInKeyWindow() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow,
                  let field = findAddressTextField(in: window.contentView)
                    ?? findAddressTextField(in: window.contentView?.superview) else { return }
            field.selectText(nil)
        }
    }

    private static func findAddressTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField,
           field.placeholderString == "URL" {
            return field
        }
        for subview in view.subviews {
            if let found = findAddressTextField(in: subview) {
                return found
            }
        }
        return nil
    }
}

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
    @State private var usageStore = UsageStore()
    @State private var isDrawingActive = false
    @AppStorage("sidebar.pinnedExpanded") private var pinnedSectionExpanded = true
    @AppStorage("sidebar.workspacesExpanded") private var workspacesSectionExpanded = true
    /// Persisted inspector column width. SwiftUI's `.inspector` resets to its
    /// `ideal` every time it re-presents (e.g. toggling Notes/Remote Desktop),
    /// so we remember the user's chosen width and feed it back as the ideal.
    @AppStorage("inspector.width") private var inspectorWidth = 280.0
    @State private var notesToggleMonitor: Any?
    @State private var persistenceFailure: PersistenceFailure?

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
                            WorkspaceView(
                                workspace: workspace,
                                isActive: isActive,
                                projectID: workspace.id,
                                surface: .main,
                                onPaneDrop: { payload, targetPane in
                                    store.movePane(payload, to: workspace, before: targetPane)
                                }
                            )
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
                usageStore: usageStore,
                selectedTab: selectedWorkspaceInspectorTabBinding
            )
                // Capture the user's resize so the width survives re-presentation.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    let clamped = min(max(Double(width), 220), 600)
                    if abs(clamped - inspectorWidth) > 1 { inspectorWidth = clamped }
                }
                .inspectorColumnWidth(min: 220, ideal: CGFloat(inspectorWidth), max: 600)
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
            usageStore.start()
        }
        // Refetch usage the moment the inspector switches to the Usage tab, so a
        // key just saved in Settings shows results without waiting for the poll.
        .onChange(of: store.selectedWorkspace?.inspectorTab) { _, tab in
            if tab == .usage { usageStore.reload() }
        }
        .onAppear { installNotesToggleMonitor() }
        .onDisappear {
            removeNotesToggleMonitor()
            usageStore.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pilotPersistenceSaveFailed)) { notification in
            let operation = notification.userInfo?["operation"] as? String ?? "Saving Pilot data"
            let message = notification.userInfo?["message"] as? String ?? "Unknown persistence error"
            persistenceFailure = PersistenceFailure(operation: operation, message: message)
        }
        .onReceive(NotificationCenter.default.publisher(for: UsageConsent.changedNotification)) { _ in
            usageStore.reload()
        }
        .alert(item: $persistenceFailure) { failure in
            Alert(
                title: Text("Changes could not be saved"),
                message: Text("\(failure.operation) failed: \(failure.message)\n\nYour non-destructive edits remain in memory. Free disk space or fix permissions, then retry."),
                primaryButton: .default(Text("Retry")) {
                    _ = store.modelContext.saveReporting(operation: "Retrying Pilot data save")
                },
                secondaryButton: .cancel()
            )
        }
        .focusedSceneValue(
            store.isNotesMode || store.isRemoteDesktopMode
                ? nil
                : store.selectedWorkspace
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: store.addWorkspace) {
                    Label("New Workspace", systemImage: "plus")
                }
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                if !store.isNotesMode,
                   !store.isRemoteDesktopMode,
                   let pane = store.selectedWorkspace?.selectedPane,
                   let browserState = BrowserToolbarSelection.state(for: pane) {
                    BrowserToolbarControls(state: browserState)
                } else if !store.isNotesMode,
                          !store.isRemoteDesktopMode,
                          let pane = store.selectedWorkspace?.selectedPane,
                          !pane.isCollapsed,
                          pane.kind == .device {
                    deviceToolbar(paneID: pane.id)
                } else if !store.isNotesMode,
                          !store.isRemoteDesktopMode,
                          let pane = store.selectedWorkspace?.selectedPane,
                          !pane.isCollapsed,
                          pane.kind == .simulator {
                    simulatorToolbar(paneID: pane.id)
                } else if !store.isNotesMode,
                          !store.isRemoteDesktopMode,
                          let pane = store.selectedWorkspace?.selectedPane,
                          !pane.isCollapsed,
                          pane.kind == .android {
                    androidToolbar(paneID: pane.id)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                // ⌘T / ⌘B live as main-menu commands (see PilotApp.commands)
                // so a focused browser web view can't swallow them.
                WorkspacePaneLauncher(workspace: store.selectedWorkspace)
                // Render the seven "New …" pane actions as one connected group
                // rather than separate circular toolbar buttons.
                    .disabled(store.isNotesMode)
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
            WorkspaceNumberShortcuts(
                workspaceIDs: workspaceShortcutIDs,
                onSelect: store.selectWorkspace
            )
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
                    store.selectWorkspace(id)
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
        DeviceToolbarControls(paneID: paneID)
    }

    @ViewBuilder
    private func simulatorToolbar(paneID: UUID) -> some View {
        let session = SimulatorRegistry.shared.session(for: paneID)
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
        .help(session.isRecording ? "Stop recording" : "Record the simulator screen")

        Button {
            session.takeScreenshot()
        } label: {
            Label("Take Screenshot", systemImage: "camera")
        }
        .disabled(!isStreaming)
        .help("Save a screenshot of the simulator screen to the Desktop")

        Button {
            session.copyScreenshotToClipboard()
        } label: {
            Label("Copy Screenshot", systemImage: "doc.on.clipboard")
        }
        .disabled(!isStreaming)
        .help("Copy a screenshot of the simulator screen to the clipboard")

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
    private func androidToolbar(paneID: UUID) -> some View {
        let session = AndroidDeviceRegistry.shared.session(for: paneID)
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
        .disabled(!isStreaming && !session.isRecording)
        .help(session.isRecording ? "Stop recording" : "Record the Android screen")

        Button {
            session.takeScreenshot()
        } label: {
            Label("Take Screenshot", systemImage: "camera")
        }
        .disabled(!isStreaming)
        .help("Save a screenshot of the Android screen to the Desktop")

        Button {
            session.copyScreenshotToClipboard()
        } label: {
            Label("Copy Screenshot", systemImage: "doc.on.clipboard")
        }
        .disabled(!isStreaming)
        .help("Copy a screenshot of the Android screen to the clipboard")

        Button {
            session.sendKeycode(AndroidKeyMap.Keycode.back)
        } label: {
            Label("Back", systemImage: "arrow.uturn.backward")
        }
        .disabled(!isStreaming)
        .help("Android Back")

        Button {
            session.sendKeycode(AndroidKeyMap.Keycode.home)
        } label: {
            Label("Home", systemImage: "circle")
        }
        .disabled(!isStreaming)
        .help("Android Home")

        Button {
            session.sendKeycode(AndroidKeyMap.Keycode.appSwitch)
        } label: {
            Label("App Switch", systemImage: "square.on.square")
        }
        .disabled(!isStreaming)
        .help("Android recent apps")

        Button {
            session.chooseAnotherDevice()
        } label: {
            Label("Choose Device", systemImage: "list.bullet")
        }
        .help("Pick a different Android device")

        if isStreaming {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
                .help("Live")
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

@MainActor
private enum ContentViewPreviewData {
    static let container: ModelContainer = {
        let schema = Schema([
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self,
            ExtensionWorkspaceLink.self,
        ])
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
