import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import WebKit

// Use plainText for drag type since custom UTTypes require Info.plist registration
private let paneTabDragType = UTType.plainText
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
    @State private var draggingPaneID: UUID?
    @State private var hoveredPaneID: UUID?

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
            canClose: workspace.sortedPanes.count > 1,
            onClose: { workspace.removePane(pane) },
            onHide: { workspace.collapsePane(pane) },
            onUnhide: { workspace.expandPane(pane) }
        )
        .padding(.horizontal, pane.isCollapsed ? 0 : 14)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(isSelected ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
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
        .onDrag {
            draggingPaneID = pane.id
            return NSItemProvider(object: pane.id.uuidString as NSString)
        } preview: {
            HStack(spacing: 6) {
                Image(systemName: pane.kind == .terminal ? "terminal" : "safari")
                    .font(.system(size: 11))
                Text(pane.kind == .terminal ? "Terminal" : "Browser")
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .onDrop(
            of: [paneTabDragType],
            delegate: PaneTabDropDelegate(
                targetPane: pane,
                workspace: workspace,
                draggingPaneID: $draggingPaneID
            )
        )
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
            .disabled(workspace.sortedPanes.count <= 1)

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

private struct PaneTabDropDelegate: DropDelegate {
    let targetPane: Pane
    let workspace: Workspace
    @Binding var draggingPaneID: UUID?

    func dropEntered(info: DropInfo) {
        _ = reorderDraggingPane()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let didReorder = reorderDraggingPane()
        draggingPaneID = nil
        return didReorder
    }

    func dropExited(info: DropInfo) {
        if !info.hasItemsConforming(to: [paneTabDragType]) {
            draggingPaneID = nil
        }
    }

    private func reorderDraggingPane() -> Bool {
        guard let draggingPaneID,
              draggingPaneID != targetPane.id,
              let fromIndex = workspace.sortedPanes.firstIndex(where: { $0.id == draggingPaneID }),
              let toIndex = workspace.sortedPanes.firstIndex(where: { $0.id == targetPane.id }),
              fromIndex != toIndex else { return false }

        var reorderedPanes = workspace.sortedPanes
        let movedPane = reorderedPanes.remove(at: fromIndex)
        reorderedPanes.insert(movedPane, at: toIndex)

        for (index, pane) in reorderedPanes.enumerated() where pane.sortOrder != index {
            pane.sortOrder = index
        }

        workspace.syncDefaultRootPathIfNeeded()
        if !movedPane.isCollapsed {
            workspace.selectedPaneID = draggingPaneID
        }
        return true
    }
}

struct TabItemContent: View {
    let pane: Pane
    let isSelected: Bool
    let isHovering: Bool
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

            Image(systemName: pane.kind == .terminal ? "terminal" : "safari")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .primary : .secondary)

            Text(pane.kind == .terminal ? "Terminal" : "Browser")
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Spacer(minLength: 0)

            if isHovering {
                headerButton(systemName: "eye.slash", help: "Hide \(paneTitle)", action: onHide)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    private var paneTitle: String {
        pane.kind == .terminal ? "Terminal" : "Browser"
    }

    private func headerButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
        }
        .buttonStyle(.plain)
        .help(
            pane.kind == .terminal
                ? "Show Terminal. Hidden terminals keep running."
                : "Unhide Browser"
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
            TerminalViewRepresentable(pane: pane, isActive: isWorkspaceActive)
        case .browser:
            if let state = pane.browserState {
                BrowserPaneView(state: state, isActive: isWorkspaceActive, isSelected: isSelected)
            }
        case .simulator:
            if let state = pane.simulatorState {
                SimulatorPaneView(state: state, isActive: isWorkspaceActive, isSelected: isSelected)
            }
        }
    }
}

// MARK: - Terminal (Ghostty)

struct TerminalViewRepresentable: View {
    let pane: Pane
    let isActive: Bool

    var body: some View {
        GhosttyTerminalView(pane: pane, isActive: isActive)
    }
}

// MARK: - Browser

struct BrowserPaneView: View {
    let state: BrowserState
    let isActive: Bool
    let isSelected: Bool

    var body: some View {
        WebViewRepresentable(
            state: state,
            navigationRequestID: state.navigationRequestID,
            inspectorToggleRequestID: state.inspectorToggleRequestID,
            appearanceMode: state.appearanceMode,
            isActive: isActive,
            isSelected: isSelected
        )
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let state: BrowserState
    let navigationRequestID: Int
    let inspectorToggleRequestID: Int
    let appearanceMode: AppearanceMode
    let isActive: Bool
    let isSelected: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = BrowserWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        webView.isHidden = !isActive
        webView.isPaneSelected = isSelected
        webView.onReload = { state.requestNavigationCommand("blau://reload") }
        if let url = initialURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        _ = navigationRequestID
        _ = inspectorToggleRequestID

        if let browserView = nsView as? BrowserWebView {
            browserView.isPaneSelected = isSelected
            browserView.onReload = { state.requestNavigationCommand("blau://reload") }
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
        Coordinator(state: state)
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        let state: BrowserState

        init(state: BrowserState) {
            self.state = state
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.isLoading = true
            updateNavState(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.isLoading = false
            if let url = webView.url {
                state.urlText = url.absoluteString
                state.pendingURL = nil
            }
            updateNavState(webView)
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

final class BrowserWebView: WKWebView {
    var onReload: (() -> Void)?
    var isPaneSelected = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isPaneSelected,
           event.type == .keyDown,
           event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "r" {
            onReload?()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
