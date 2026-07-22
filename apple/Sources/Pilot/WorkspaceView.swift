import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import WebKit

extension UTType {
    static let pilotPane = UTType(exportedAs: "app.blau.pilot.pane")
}

enum WorkspacePaneSurface: String, Codable, Hashable {
    case main
    case `extension`
}

struct WorkspacePaneDragPayload: Codable, Hashable, Transferable {
    let paneID: UUID
    let sourceWorkspaceID: UUID
    let projectID: UUID
    let sourceSurface: WorkspacePaneSurface

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pilotPane)
    }
}

private enum PaneLayoutMetrics {
    static let dividerLineThickness: CGFloat = 1
    static let dividerHitThickness: CGFloat = 6
    static let collapsedPaneThickness: CGFloat = 28
}

private struct PaneLayoutPlan {
    let sizes: [UUID: CGFloat]
    let expandedSize: CGFloat
}

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    let isActive: Bool
    let projectID: UUID
    let surface: WorkspacePaneSurface
    let onPaneDrop: (WorkspacePaneDragPayload, Pane) -> Bool
    @State private var hoveredPaneID: UUID?
    @State private var dropTargetPaneID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            panesContent
        }
        .onAppear {
            syncFocusForSelectedPane()
        }
        .onChange(of: isActive) {
            syncFocusForSelectedPane()
        }
        .onChange(of: workspace.selectedPaneID) {
            workspace.syncDefaultRootPathIfNeeded()
            syncFocusForSelectedPane()
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        Group {
            if workspace.axis == .vertical {
                resizableTabBar
                    .padding(.vertical, 6)
            } else {
                let sorted = workspace.sortedPanes
                HStack(spacing: 1) {
                    ForEach(sorted) { pane in
                        tabItem(pane)
                            .frame(width: pane.isCollapsed ? PaneLayoutMetrics.collapsedPaneThickness : nil)
                            .frame(maxWidth: pane.isCollapsed ? nil : .infinity)
                    }

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .background(.bar)
    }

    private func tabItem(_ pane: Pane) -> some View {
        let isSelected = workspace.selectedPaneID == pane.id && !pane.isCollapsed

        return TabItemContent(
            pane: pane,
            isSelected: isSelected,
            isHovering: hoveredPaneID == pane.id,
            isWorkspaceActive: isActive,
            // The extension surface may close its last pane (its empty state
            // invites re-adding); the main window always keeps one.
            canClose: workspace.sortedPanes.count > 1 || surface == .extension,
            onClose: { workspace.removePane(pane) },
            onHide: { workspace.collapsePane(pane) },
            onUnhide: { workspace.expandPane(pane) }
        )
        .padding(.horizontal, pane.isCollapsed ? 0 : 14)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(
            dropTargetPaneID == pane.id
                ? Color.accentColor.opacity(0.22)
                : (isSelected ? .white.opacity(0.1) : .clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            if dropTargetPaneID == pane.id {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovering in
            if isHovering {
                hoveredPaneID = pane.id
            } else if hoveredPaneID == pane.id {
                hoveredPaneID = nil
            }
        }
        .onTapGesture {
            if pane.isCollapsed {
                workspace.expandPane(pane)
            } else {
                workspace.selectedPaneID = pane.id
            }
        }
        .draggable(
            WorkspacePaneDragPayload(
                paneID: pane.id,
                sourceWorkspaceID: workspace.id,
                projectID: projectID,
                sourceSurface: surface
            )
        ) {
            HStack(spacing: 6) {
                Image(systemName: pane.kind.systemImageName)
                    .scaledFont(size: 11)
                Text(pane.displayTitle)
                    .scaledFont(size: 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: WorkspacePaneDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            defer { dropTargetPaneID = nil }
            return onPaneDrop(payload, pane)
        } isTargeted: { isTargeted in
            dropTargetPaneID = isTargeted ? pane.id : nil
        }
        .contextMenu {
            if pane.isCollapsed {
                Button("Unhide") {
                    workspace.expandPane(pane)
                }
            } else {
                Button("Hide") {
                    workspace.collapsePane(pane)
                }
            }

            Divider()

            Button("Close", role: .destructive) {
                workspace.removePane(pane)
            }
            .disabled(workspace.sortedPanes.count <= 1 && surface != .extension)

            if workspace.sortedPanes.count > 1 {
                Divider()
                Button("Reset Pane Sizes") {
                    workspace.resetPaneSizes()
                }
            }
        }
    }

    // MARK: - Pane Content

    @ViewBuilder
    private var panesContent: some View {
        let isVertical = workspace.axis == .vertical
        let sorted = workspace.sortedPanes

        if sorted.isEmpty {
            emptyPanesView
        } else {
            filledPanesContent(isVertical: isVertical, sorted: sorted)
        }
    }

    /// Reached when the last pane is closed (the extension surface allows
    /// that): an explicit invitation to add panes, mirroring the toolbar
    /// launcher's options.
    private var emptyPanesView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "No Panes",
                systemImage: "rectangle.dashed",
                description: Text("Add a pane to get started.")
            )
            .frame(maxHeight: 220)

            HStack(spacing: 8) {
                addPaneButton(.terminal)
                addPaneButton(.browser)
                addPaneButton(.device)
                addPaneButton(.simulator)
                addPaneButton(.android)
                addPaneButton(.editor)
                    .disabled(workspace.effectiveRootPath == nil)
                    .help(workspace.effectiveRootPath == nil
                        ? "Set a workspace root path to open the editor"
                        : "Open a file editor with fuzzy file search")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addPaneButton(_ kind: PaneKind) -> some View {
        Button {
            workspace.addPane(kind: kind, side: .right)
        } label: {
            Label(kind.displayName, systemImage: kind.systemImageName)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func filledPanesContent(isVertical: Bool, sorted: [Pane]) -> some View {
        GeometryReader { geometry in
            let totalSize = isVertical ? geometry.size.width : geometry.size.height
            let dividerThickness = PaneLayoutMetrics.dividerHitThickness
            let dividerCount = CGFloat(max(sorted.count - 1, 0))
            let availableSize = max(0, totalSize - dividerCount * dividerThickness)
            let layout = paneLayoutPlan(totalSize: availableSize, sorted: sorted)

            let stack = isVertical ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, pane in
                    let paneSize = layout.sizes[pane.id] ?? 0

                    ZStack {
                        PaneView(
                            pane: pane,
                            isSelected: workspace.selectedPaneID == pane.id && !pane.isCollapsed,
                            isWorkspaceActive: isActive
                        )
                        .opacity(pane.isCollapsed ? 0 : 1)
                        .allowsHitTesting(!pane.isCollapsed)

                        if pane.isCollapsed {
                            CollapsedPaneSlit(
                                pane: pane,
                                isVertical: isVertical,
                                onUnhide: { workspace.expandPane(pane) }
                            )
                        }
                    }
                        .frame(
                            width: isVertical ? max(0, paneSize) : nil,
                            height: isVertical ? nil : max(0, paneSize)
                        )
                        // AppKit-backed panes can retain a document width larger
                        // than their SwiftUI allocation while a divider moves.
                        // Keep every surface inside the pane it was assigned.
                        .clipped()
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                if pane.isCollapsed {
                                    workspace.expandPane(pane)
                                } else {
                                    workspace.selectedPaneID = pane.id
                                }
                            }
                        )

                    if index < sorted.count - 1 {
                        let trailingPane = sorted[index + 1]
                        PaneResizeHandle(
                            isVertical: isVertical,
                            totalSize: layout.expandedSize,
                            leadingID: pane.id,
                            trailingID: trailingPane.id,
                            workspace: workspace,
                            isEnabled: workspace.canResizePanes(
                                leadingID: pane.id,
                                trailingID: trailingPane.id
                            )
                        )
                    }
                }
            }
        }
    }

}

private extension WorkspaceView {
    var resizableTabBar: some View {
        let sorted = workspace.sortedPanes

        return GeometryReader { geometry in
            let dividerCount = CGFloat(max(sorted.count - 1, 0))
            let availableWidth = max(0, geometry.size.width - dividerCount * PaneLayoutMetrics.dividerHitThickness)
            let layout = paneLayoutPlan(totalSize: availableWidth, sorted: sorted)

            HStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, pane in
                    let tabWidth = layout.sizes[pane.id] ?? 0

                    tabItem(pane)
                        .frame(width: max(0, tabWidth))

                    if index < sorted.count - 1 {
                        let trailingPane = sorted[index + 1]
                        PaneResizeHandle(
                            isVertical: true,
                            totalSize: layout.expandedSize,
                            leadingID: pane.id,
                            trailingID: trailingPane.id,
                            workspace: workspace,
                            isEnabled: workspace.canResizePanes(
                                leadingID: pane.id,
                                trailingID: trailingPane.id
                            )
                        )
                    }
                }
            }
        }
        .frame(height: 28)
    }

    func syncFocusForSelectedPane() {
        guard isActive else { return }
        guard workspace.selectedPane?.isCollapsed != true else { return }

        if let pane = workspace.selectedPane, pane.kind == .browser {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            return
        }

        guard let pane = workspace.selectedPane ?? workspace.frontmostTerminalPane,
              pane.kind == .terminal else { return }
        workspace.setFrontmostTerminalPaneID(pane.id)
        DispatchQueue.main.async {
            _ = GhosttyMetalView.focus(paneID: pane.id)
        }
    }

    func paneLayoutPlan(totalSize: CGFloat, sorted: [Pane]) -> PaneLayoutPlan {
        guard !sorted.isEmpty else { return PaneLayoutPlan(sizes: [:], expandedSize: 0) }

        let collapsedPanes = sorted.filter(\.isCollapsed)
        let expandedPanes = sorted.filter { !$0.isCollapsed }
        let maxCollapsedThickness = totalSize / CGFloat(max(sorted.count, 1))
        let collapsedThickness = min(PaneLayoutMetrics.collapsedPaneThickness, max(0, maxCollapsedThickness))
        let collapsedTotal = CGFloat(collapsedPanes.count) * collapsedThickness
        let expandedSize = expandedPanes.isEmpty ? 0 : max(0, totalSize - collapsedTotal)
        let fractions = workspace.normalizedExpandedSizeFractions

        var sizes: [UUID: CGFloat] = [:]
        for pane in sorted {
            if pane.isCollapsed {
                sizes[pane.id] = collapsedThickness
            } else {
                let fraction = fractions[pane.id] ?? (1.0 / Double(max(expandedPanes.count, 1)))
                sizes[pane.id] = expandedSize * CGFloat(fraction)
            }
        }

        return PaneLayoutPlan(sizes: sizes, expandedSize: expandedSize)
    }
}

private struct PaneResizeHandle: View {
    let isVertical: Bool
    let totalSize: CGFloat
    let leadingID: UUID
    let trailingID: UUID
    let workspace: Workspace
    let isEnabled: Bool
    @State private var isDragging = false
    @State private var isHovering = false
    @State private var lastDragLocation: CGFloat = 0

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(isHovering || isDragging ? 0.18 : 0.08))

            Rectangle()
                .fill(isDragging || isHovering ? Color.accentColor : Color(nsColor: .separatorColor))
                .frame(
                    width: isVertical ? PaneLayoutMetrics.dividerLineThickness : nil,
                    height: isVertical ? nil : PaneLayoutMetrics.dividerLineThickness
                )
        }
        .frame(
            width: isVertical ? PaneLayoutMetrics.dividerHitThickness : nil,
            height: isVertical ? nil : PaneLayoutMetrics.dividerHitThickness
        )
        .contentShape(Rectangle())
        .zIndex(1)
        .onDisappear {
            isHovering = false
            NSCursor.arrow.set()
        }
        .onContinuousHover { phase in
            guard isEnabled else {
                isHovering = false
                NSCursor.arrow.set()
                return
            }

            switch phase {
            case .active:
                isHovering = true
                resizeCursor.set()
            case .ended:
                isHovering = false
                NSCursor.arrow.set()
            }
        }
        .onTapGesture(count: 2) {
            guard isEnabled else { return }
            workspace.resetPaneSizes()
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    guard isEnabled else { return }
                    guard totalSize > 0 else { return }
                    let current = isVertical ? value.location.x : value.location.y
                    if !isDragging {
                        isDragging = true
                        lastDragLocation = current
                        return
                    }
                    let moved = current - lastDragLocation
                    lastDragLocation = current
                    let delta = Double(moved / totalSize)
                    workspace.resizePanes(leadingID: leadingID, trailingID: trailingID, delta: delta)
                }
                .onEnded { _ in
                    guard isEnabled else { return }
                    isDragging = false
                    workspace.persistPaneSizes()
                }
        )
    }

    private var resizeCursor: NSCursor {
        isVertical ? .resizeLeftRight : .resizeUpDown
    }
}

struct TabItemContent: View {
    let pane: Pane
    let isSelected: Bool
    let isHovering: Bool
    let isWorkspaceActive: Bool
    let canClose: Bool
    let onClose: () -> Void
    let onHide: () -> Void
    let onUnhide: () -> Void

    var body: some View {
        if pane.isCollapsed {
            collapsedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            expandedContent
        }
    }

    @ViewBuilder
    private var collapsedContent: some View {
        if pane.kind == .terminal {
            headerButton(systemName: "eye", help: "Show Terminal. Hidden terminals keep running.", action: onUnhide)
        } else {
            headerButton(systemName: "eye", help: "Unhide \(paneTitle)", action: onUnhide)
        }
    }

    private var expandedContent: some View {
        HStack(spacing: 6) {
            if isHovering && canClose {
                headerButton(systemName: "xmark", help: "Close \(paneTitle)", action: onClose)
                    .background(.white.opacity(0.1), in: Circle())
                    .transition(.opacity)
            }

            Image(systemName: pane.kind.systemImageName)
                .scaledFont(size: 11)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Text(pane.displayTitle)
                .scaledFont(size: 12)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            if pane.kind == .terminal {
                TerminalAgentBadge(pane: pane, isWorkspaceActive: isWorkspaceActive)
                TerminalDirtyBadge(pane: pane, isWorkspaceActive: isWorkspaceActive)
            }

            Spacer(minLength: 0)

            if isHovering {
                headerButton(systemName: "eye.slash", help: "Hide \(paneTitle)", action: onHide)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    private var paneTitle: String {
        pane.kind.displayName
    }

    private func headerButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .scaledFont(size: 9, weight: .bold)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Accent capsule naming the coding agent (Claude, Codex, …) currently running
/// in a terminal pane, shown right after "Terminal". Polls the shell's process
/// tree every couple of seconds while its workspace is active; renders nothing
/// when the shell is idle at its prompt.
private struct TerminalAgentBadge: View {
    let pane: Pane
    let isWorkspaceActive: Bool
    @State private var agent: TerminalAgent?

    var body: some View {
        Group {
            if let agent {
                Text(agent.displayName)
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .help("\(agent.displayName) is running in this terminal")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: agent)
        // Restart polling when activation flips; only the visible workspace polls.
        .task(id: isWorkspaceActive) {
            guard isWorkspaceActive else { return }
            while !Task.isCancelled {
                agent = pane.liveShellAgent()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// "Clean" / "Dirty" word shown after "Terminal" in a terminal tab header,
/// reflecting whether the shell's current directory sits in a git work tree with
/// uncommitted changes. Polls `git status` every few seconds while its workspace
/// is active (it reads the shell's live cwd, so it tracks `cd` and file edits);
/// renders nothing when the directory isn't a git repo.
private struct TerminalDirtyBadge: View {
    let pane: Pane
    let isWorkspaceActive: Bool
    @State private var isDirty: Bool?

    var body: some View {
        Group {
            if let isDirty {
                Text(isDirty ? "Dirty" : "Clean")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(isDirty ? Color.orange : Color.green)
            }
        }
        // Restart polling when activation flips; only the visible workspace polls.
        .task(id: isWorkspaceActive) {
            guard isWorkspaceActive else { return }
            while !Task.isCancelled {
                let directory = pane.liveShellCurrentDirectory() ?? pane.currentDirectory
                let status: Bool? = directory.isEmpty ? nil : await GitStatus.isDirty(directory: directory)
                if Task.isCancelled { break }
                isDirty = status
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

private struct CollapsedPaneSlit: View {
    let pane: Pane
    let isVertical: Bool
    let onUnhide: () -> Void

    var body: some View {
        Group {
            if isVertical {
                VStack(spacing: 0) {
                    unhideButton
                    Spacer(minLength: 0)
                }
                .padding(.top, 6)
            } else {
                HStack(spacing: 0) {
                    unhideButton
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
        .overlay {
            Rectangle()
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private var unhideButton: some View {
        Button(action: onUnhide) {
            if pane.kind == .terminal {
                HiddenTerminalIndicator(compact: false)
            } else {
                Image(systemName: "eye")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
        }
        .buttonStyle(.plain)
        .help(
            pane.kind == .terminal
                ? "Show Terminal. Hidden terminals keep running."
                : "Unhide \(pane.kind.displayName)"
        )
    }
}

private struct HiddenTerminalIndicator: View {
    let compact: Bool
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(compact ? 0.12 : 0.16))
                .frame(width: compact ? 18 : 20, height: compact ? 18 : 20)

            Circle()
                .fill(Color.accentColor.opacity(isPulsing ? 0.95 : 0.45))
                .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
                .scaleEffect(isPulsing ? 1.0 : 0.72)
        }
        .frame(width: compact ? 18 : 20, height: compact ? 18 : 20)
        .accessibilityLabel("Hidden terminal is still running")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

struct PaneView: View {
    let pane: Pane
    let isSelected: Bool
    let isWorkspaceActive: Bool

    var body: some View {
        switch pane.kind {
        case .terminal:
            TerminalViewRepresentable(
                pane: pane,
                isActive: isWorkspaceActive,
                isCollapsed: pane.isCollapsed
            )
        case .browser:
            if let state = pane.browserState {
                BrowserPaneView(
                    state: state,
                    rootPath: pane.workspace?.effectiveRootPath,
                    isActive: isWorkspaceActive,
                    isSelected: isSelected,
                    onSelect: { pane.workspace?.selectedPaneID = pane.id },
                    targetTerminalPaneID: { pane.workspace?.frontmostTerminalPane?.id }
                )
            }
        case .device:
            DevicePaneView(
                paneID: pane.id,
                isActive: isWorkspaceActive,
                isSelected: isSelected,
                isCollapsed: pane.isCollapsed
            )
        case .simulator:
            SimulatorPaneView(paneID: pane.id, isActive: isWorkspaceActive, isSelected: isSelected)
        case .android:
            AndroidPaneView(
                paneID: pane.id,
                isActive: isWorkspaceActive,
                isSelected: isSelected,
                isCollapsed: pane.isCollapsed
            )
        case .editor:
            if let editorState = pane.editorState {
                EditorPaneView(state: editorState,
                               rootPath: pane.workspace?.effectiveRootPath,
                               isActive: isWorkspaceActive,
                               isSelected: isSelected,
                               onSelect: { pane.workspace?.selectedPaneID = pane.id })
            }
        }
    }
}

// MARK: - Terminal (Ghostty)

struct TerminalViewRepresentable: View {
    let pane: Pane
    let isActive: Bool
    let isCollapsed: Bool

    var body: some View {
        GhosttyTerminalView(pane: pane, isActive: isActive, isCollapsed: isCollapsed)
    }
}

// MARK: - Browser

struct BrowserPaneView: View {
    let state: BrowserState
    let rootPath: String?
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let targetTerminalPaneID: @MainActor () -> UUID?

    @State private var hasLoadedAnyURL: Bool = false
    @State private var openedWithBlankURL: Bool?

    var body: some View {
        if shouldShowStartPage {
            BrowserStartPageView(rootPath: rootPath) { server in
                onSelect()
                state.urlText = server.url.absoluteString
                state.navigate()
                hasLoadedAnyURL = true
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear { captureInitialURLState() }
        } else {
            WebViewRepresentable(
                state: state,
                navigationRequestID: state.navigationRequestID,
                inspectorToggleRequestID: state.inspectorToggleRequestID,
                annotateMode: state.annotateMode,
                annotateToggleRequestID: state.annotateToggleRequestID,
                appearanceMode: state.appearanceMode,
                isActive: isActive,
                isSelected: isSelected,
                onSelect: onSelect,
                targetTerminalPaneID: targetTerminalPaneID
            )
            .onAppear {
                captureInitialURLState()
                hasLoadedAnyURL = true
            }
        }
    }

    private var shouldShowStartPage: Bool {
        // Sticky: once a URL is loaded, never flip back even if the user
        // clears the address bar to type a new one. Persisted panes that
        // already have a `urlText` skip the start page entirely on launch.
        BrowserStartPageVisibility.shouldShow(
            hasLoadedAnyURL: hasLoadedAnyURL,
            openedWithBlankURL: openedWithBlankURL,
            urlText: state.urlText,
            hasPendingPageNavigation: state.pendingURL.map { $0.scheme != "blau" } ?? false
        )
    }

    private func captureInitialURLState() {
        guard openedWithBlankURL == nil else { return }
        openedWithBlankURL = state.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum BrowserStartPageVisibility {
    static func shouldShow(
        hasLoadedAnyURL: Bool,
        openedWithBlankURL: Bool?,
        urlText: String,
        hasPendingPageNavigation: Bool
    ) -> Bool {
        if hasLoadedAnyURL { return false }
        if hasPendingPageNavigation { return false }
        return openedWithBlankURL ?? urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    @Environment(\.uiZoom) private var uiZoom

    let state: BrowserState
    let navigationRequestID: Int
    let inspectorToggleRequestID: Int
    let annotateMode: Bool
    let annotateToggleRequestID: Int
    let appearanceMode: AppearanceMode
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let targetTerminalPaneID: @MainActor () -> UUID?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Browser Annotate: inject the in-page overlay + a message handler for
        // the single "send" round-trip.
        config.userContentController.add(
            context.coordinator,
            contentWorld: BrowserAnnotate.contentWorld,
            name: BrowserAnnotate.messageName
        )
        // Main frame only: the page snapshot covers the top document, so element
        // rects must be in top-document coordinates. Injecting into subframes
        // would let the box open inside an iframe with rects the screenshot
        // can't line up against.
        config.userContentController.addUserScript(
            WKUserScript(
                source: BrowserAnnotate.userScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: BrowserAnnotate.contentWorld
            )
        )
        let webView = BrowserWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        webView.isHidden = !isActive
        webView.isPaneSelected = isSelected
        webView.onReload = { state.requestNavigationCommand("blau://reload") }
        webView.onSelect = onSelect
        webView.pageZoom = uiZoom
        context.coordinator.observeURL(of: webView)
        if let url = initialURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        _ = navigationRequestID
        _ = inspectorToggleRequestID
        _ = annotateToggleRequestID

        if abs(nsView.pageZoom - uiZoom) > 0.001 {
            nsView.pageZoom = uiZoom
        }

        if let browserView = nsView as? BrowserWebView {
            browserView.isPaneSelected = isSelected
            browserView.onReload = { state.requestNavigationCommand("blau://reload") }
            browserView.onSelect = onSelect
        }

        nsView.isHidden = !isActive

        // Handle navigation commands
        if let pending = state.pendingURL {
            switch pending.absoluteString {
            case "blau://back":
                nsView.goBack()
                state.pendingURL = nil
            case "blau://forward":
                nsView.goForward()
                state.pendingURL = nil
            case "blau://reload":
                nsView.reload()
                state.pendingURL = nil
            case "blau://stop":
                nsView.stopLoading()
                state.pendingURL = nil
            default:
                nsView.load(URLRequest(url: pending))
                state.pendingURL = nil
            }
        }

        // Toggle Web Inspector (opens in separate window)
        if state.needsInspectorToggle {
            state.needsInspectorToggle = false
            InspectorHelper.toggleInspector(for: nsView, show: state.showDevTools)
        }

        // Browser Annotate: push the enabled state into the injected overlay.
        if context.coordinator.lastAnnotateToggleID != annotateToggleRequestID {
            context.coordinator.lastAnnotateToggleID = annotateToggleRequestID
            context.coordinator.setAnnotateMode(annotateMode, in: nsView)
        }

        // Always apply appearance — NSAppearance drives prefers-color-scheme in WKWebView
        let appearance: NSAppearance?
        switch appearanceMode {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        if nsView.appearance != appearance {
            nsView.appearance = appearance
            nsView.evaluateJavaScript(
                "document.documentElement.style.colorScheme = '\(appearanceMode == .dark ? "dark" : appearanceMode == .light ? "light" : "")'"
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, targetTerminalPaneID: targetTerminalPaneID)
    }

    private var initialURL: URL? {
        if let pendingURL = state.pendingURL,
           pendingURL.scheme != "blau" {
            return pendingURL
        }

        let trimmed = state.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        return URL(string: "https://\(trimmed)")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        let state: BrowserState
        let targetTerminalPaneID: @MainActor () -> UUID?
        /// Last annotate-toggle id pushed into the page, to dedupe updateNSView runs.
        var lastAnnotateToggleID = -1
        private var urlObservation: NSKeyValueObservation?
        private var pendingDestinations: [ObjectIdentifier: URL] = [:]
        private var annotateGrant: BrowserAnnotate.BridgeGrant?

        init(state: BrowserState, targetTerminalPaneID: @escaping @MainActor () -> UUID?) {
            self.state = state
            self.targetTerminalPaneID = targetTerminalPaneID
        }

        deinit {
            urlObservation?.invalidate()
        }

        // MARK: - Browser Annotate

        func setAnnotateMode(_ enabled: Bool, in webView: WKWebView) {
            guard enabled, let navigationURL = webView.url?.absoluteString else {
                annotateGrant = nil
                BrowserAnnotate.evaluate(BrowserAnnotate.setEnabledScript(false), in: webView)
                return
            }
            let token = UUID().uuidString
            annotateGrant = BrowserAnnotate.BridgeGrant(
                token: token,
                navigationURL: navigationURL,
                expiresAt: Date(timeIntervalSinceNow: BrowserAnnotate.grantLifetime)
            )
            BrowserAnnotate.evaluate(
                BrowserAnnotate.setEnabledScript(true, token: token),
                in: webView
            )
        }

        /// The isolated-world web→Swift hop. A main-frame, current-navigation,
        /// single-use grant is consumed before the asynchronous snapshot starts.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == BrowserAnnotate.messageName,
                  message.frameInfo.isMainFrame,
                  let payload = BrowserAnnotate.MessagePayload.parse(message.body) else { return }
            // WebKit calls this on the main thread.
            MainActor.assumeIsolated {
                guard state.annotateMode,
                      let webView = message.webView,
                      let currentURL = webView.url?.absoluteString,
                      annotateGrant?.consume(payload, currentURL: currentURL) == true else { return }
                annotateGrant = nil
                // Resolve the terminal synchronously while the user's last
                // terminal click is still authoritative. `takeSnapshot` is
                // asynchronous; looking it up in its completion can send to a
                // different LLM if the user changes panes/workspaces meanwhile.
                let dispatch = BrowserAnnotate.DispatchContext(
                    targetPaneID: targetTerminalPaneID()
                )
                webView.takeSnapshot(with: WKSnapshotConfiguration()) { [weak self, weak webView] image, _ in
                    Task { @MainActor in
                        guard let self, let webView,
                              webView.url?.absoluteString == payload.url else { return }
                        // Keep the trusted outline through capture, then clear it
                        // in the same isolated content world.
                        BrowserAnnotate.evaluate(
                            BrowserAnnotate.finishSendScript(selectionID: payload.selectionID),
                            in: webView
                        )
                        let path = BrowserAnnotate.writeScreenshot(image)
                        let prompt = BrowserAnnotate.buildPrompt(
                            instruction: payload.instruction,
                            url: payload.url,
                            selector: payload.selector,
                            outerHTML: payload.outerHTML,
                            rectX: payload.rectX,
                            rectY: payload.rectY,
                            rectW: payload.rectW,
                            rectH: payload.rectH,
                            screenshotPath: path
                        )
                        if self.confirmDispatch(instruction: payload.instruction, url: payload.url) {
                            NotificationCenter.default.post(
                                name: .pilotSendIssuePrompt,
                                object: nil,
                                userInfo: dispatch.notificationUserInfo(prompt: prompt)
                            )
                        }
                        if self.state.annotateMode {
                            self.setAnnotateMode(true, in: webView)
                        }
                    }
                }
            }
        }

        private func confirmDispatch(instruction: String, url: String) -> Bool {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Send browser annotation to the terminal?"
            alert.informativeText = "Instruction: \(instruction)\n\nPage: \(url)\n\nPage content is untrusted and will be clearly delimited in the prompt."
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }

        /// KVO on `WKWebView.url` so the address bar reflects every URL
        /// change — link clicks, server redirects, hash changes, and
        /// `history.pushState` from SPAs — not just `didFinish` loads.
        func observeURL(of webView: WKWebView) {
            urlObservation?.invalidate()
            urlObservation = webView.observe(\.url, options: [.new, .initial]) { [weak self] webView, _ in
                guard let self, let url = webView.url else { return }
                let absolute = url.absoluteString
                Task { @MainActor in
                    if self.state.urlText != absolute {
                        self.state.urlText = absolute
                    }
                }
            }
        }

        // MARK: - Download routing

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            // Anything WebKit can't render inline (zip, dmg, pkg, raw images
            // when triggered via Save As, etc.) is converted to a download.
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        // MARK: - WKDownloadDelegate

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @MainActor @Sendable @escaping (URL?) -> Void
        ) {
            let directory = FileManager.default.urls(
                for: .downloadsDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let destination = Self.uniqueDestination(in: directory, suggestedFilename: suggestedFilename)
            pendingDestinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let url = pendingDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            pendingDestinations.removeValue(forKey: ObjectIdentifier(download))
        }

        private static func uniqueDestination(in directory: URL, suggestedFilename: String) -> URL {
            let fallback = suggestedFilename.isEmpty ? "download" : suggestedFilename
            var candidate = directory.appendingPathComponent(fallback)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

            let ext = candidate.pathExtension
            let stem = candidate.deletingPathExtension().lastPathComponent
            for n in 1...999 {
                let nextName = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                candidate = directory.appendingPathComponent(nextName)
                if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            return candidate
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            annotateGrant = nil
            state.isLoading = true
            updateNavState(webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Earliest reliable point — URL is now the real destination
            // (after any provisional redirects).
            if let url = webView.url {
                state.urlText = url.absoluteString
            }
            updateNavState(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.isLoading = false
            if let url = webView.url {
                state.urlText = url.absoluteString
                state.pendingURL = nil
            }
            updateNavState(webView)
            // The user script re-injects (disabled) on each load — re-assert
            // annotate mode so it survives navigation.
            if state.annotateMode {
                setAnnotateMode(true, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            state.isLoading = false
            updateNavState(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            state.isLoading = false
            updateNavState(webView)
        }

        private func updateNavState(_ webView: WKWebView) {
            state.canGoBack = webView.canGoBack
            state.canGoForward = webView.canGoForward
        }
    }
}

enum BrowserWebShortcutPolicy {
    /// Browser editing shortcuts that should stay inside WKWebView. Shifted ⌘A
    /// is deliberately excluded because Pilot owns it for Lasso.
    static func keepsNativeEditingShortcut(characters: String, hasShift: Bool) -> Bool {
        (!hasShift && ["c", "v", "x", "a"].contains(characters))
            || characters == "z" // both ⌘Z and ⇧⌘Z (Redo)
    }
}

final class BrowserWebView: WKWebView {
    var onReload: (() -> Void)?
    var onSelect: (() -> Void)?
    var isPaneSelected = false

    override func mouseDown(with event: NSEvent) {
        // The WebView swallows clicks before SwiftUI's pane-level
        // `.onTapGesture` sees them, so the pane never becomes selected.
        // Notify out before the WebView consumes the event.
        onSelect?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let plainCommand = !event.modifierFlags.contains(.control)
            && !event.modifierFlags.contains(.option)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if isPaneSelected, plainCommand, chars == "r" {
            onReload?()
            return true
        }

        // Keep standard editing shortcuts native, but only plain ⌘A is Select
        // All. ⇧⌘A belongs to Pilot's Lasso command and must reach the menu.
        let hasShift = event.modifierFlags.contains(.shift)
        if plainCommand,
           BrowserWebShortcutPolicy.keepsNativeEditingShortcut(
               characters: chars,
               hasShift: hasShift
           ) {
            return super.performKeyEquivalent(with: event)
        }

        // Otherwise give the app's main menu first crack — a focused WKWebView
        // otherwise swallows global shortcuts (⌘T, ⌘B, ⌘L, ⌘0, ⌘±, …) before
        // they ever reach the menu.
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
