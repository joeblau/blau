import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import WebKit

// Use plainText for drag type since custom UTTypes require Info.plist registration
private let paneTabDragType = UTType.plainText

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
            focusTerminalIfNeededForWorkspaceActivation()
        }
        .onChange(of: isActive) {
            focusTerminalIfNeededForWorkspaceActivation()
        }
        .onChange(of: workspace.selectedPaneID) {
            focusSelectedTerminalIfNeeded()
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 1) {
            ForEach(workspace.sortedPanes) { pane in
                tabItem(pane)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func tabItem(_ pane: Pane) -> some View {
        let isSelected = workspace.selectedPaneID == pane.id

        return TabItemContent(
            pane: pane,
            isSelected: isSelected,
            isHovering: hoveredPaneID == pane.id,
            canClose: workspace.sortedPanes.count > 1,
            onClose: { workspace.removePane(pane) }
        )
        .padding(.horizontal, 14)
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
        .onTapGesture { workspace.selectedPaneID = pane.id }
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
            Button("Close", role: .destructive) {
                workspace.removePane(pane)
            }
            .disabled(workspace.sortedPanes.count <= 1)
        }
    }

    // MARK: - Pane Content

    @ViewBuilder
    private var panesContent: some View {
        let isVertical = workspace.axis == .vertical
        let layout = isVertical ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            ForEach(workspace.sortedPanes) { pane in
                PaneView(pane: pane, isSelected: workspace.selectedPaneID == pane.id)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            workspace.selectedPaneID = pane.id
                        }
                    )
                if pane.id != workspace.sortedPanes.last?.id {
                    Divider()
                }
            }
        }
    }

}

private extension WorkspaceView {
    func focusTerminalIfNeededForWorkspaceActivation() {
        guard isActive, let pane = workspace.frontmostTerminalPane else { return }
        workspace.setFrontmostTerminalPaneID(pane.id)
        DispatchQueue.main.async {
            _ = GhosttyMetalView.focus(paneID: pane.id)
        }
    }

    func focusSelectedTerminalIfNeeded() {
        guard isActive,
              let pane = workspace.selectedPane,
              pane.kind == .terminal else { return }
        workspace.setFrontmostTerminalPaneID(pane.id)
        DispatchQueue.main.async {
            _ = GhosttyMetalView.focus(paneID: pane.id)
        }
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

        workspace.selectedPaneID = draggingPaneID
        return true
    }
}

struct TabItemContent: View {
    let pane: Pane
    let isSelected: Bool
    let isHovering: Bool
    let canClose: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if isHovering && canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            Image(systemName: pane.kind == .terminal ? "terminal" : "safari")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .primary : .secondary)
            Text(pane.kind == .terminal ? "Terminal" : "Browser")
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}

struct PaneView: View {
    let pane: Pane
    let isSelected: Bool

    var body: some View {
        switch pane.kind {
        case .terminal:
            TerminalViewRepresentable(pane: pane)
        case .browser:
            if let state = pane.browserState {
                BrowserPaneView(state: state)
            }
        }
    }
}

// MARK: - Terminal (Ghostty)

struct TerminalViewRepresentable: View {
    let pane: Pane

    var body: some View {
        GhosttyTerminalView(pane: pane)
    }
}

// MARK: - Browser

struct BrowserPaneView: View {
    let state: BrowserState

    var body: some View {
        WebViewRepresentable(
            state: state,
            navigationRequestID: state.navigationRequestID,
            inspectorToggleRequestID: state.inspectorToggleRequestID,
            appearanceMode: state.appearanceMode
        )
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let state: BrowserState
    let navigationRequestID: Int
    let inspectorToggleRequestID: Int
    let appearanceMode: AppearanceMode

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        if let url = initialURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        _ = navigationRequestID
        _ = inspectorToggleRequestID

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
