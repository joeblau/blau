import SwiftUI
import SwiftTerm
@preconcurrency import WebKit

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @State private var draggingPaneID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            panesContent
        }
        .navigationTitle(workspace.name)
        .toolbar { paneToolbar }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 1) {
            ForEach(workspace.panes) { pane in
                tabItem(pane)
            }
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
            canClose: workspace.panes.count > 1,
            onClose: { workspace.removePane(pane) }
        )
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(isSelected ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { workspace.selectedPaneID = pane.id }
        .draggable(pane.id.uuidString) {
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
        .dropDestination(for: String.self) { items, _ in
            guard let droppedIDString = items.first,
                  let droppedID = UUID(uuidString: droppedIDString),
                  let fromIndex = workspace.panes.firstIndex(where: { $0.id == droppedID }),
                  let toIndex = workspace.panes.firstIndex(where: { $0.id == pane.id }),
                  fromIndex != toIndex else { return false }
            workspace.panes.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            return true
        }
        .contextMenu {
            Button("Close", role: .destructive) {
                workspace.removePane(pane)
            }
            .disabled(workspace.panes.count <= 1)
        }
    }

    // MARK: - Pane Content

    @ViewBuilder
    private var panesContent: some View {
        let isVertical = workspace.axis == .vertical
        let layout = isVertical ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            ForEach(workspace.panes) { pane in
                PaneView(pane: pane, isSelected: workspace.selectedPaneID == pane.id)
                    .onTapGesture { workspace.selectedPaneID = pane.id }
                if pane.id != workspace.panes.last?.id {
                    Divider()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var paneToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                workspace.addPane(kind: .terminal, side: .right)
            } label: {
                Label("New Terminal", systemImage: "terminal")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                workspace.addPane(kind: .browser, side: .right)
            } label: {
                Label("New Browser", systemImage: "safari")
            }
        }
    }
}

struct TabItemContent: View {
    let pane: Pane
    let isSelected: Bool
    let canClose: Bool
    let onClose: () -> Void
    @State private var isHovering = false

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
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}

struct PaneView: View {
    let pane: Pane
    let isSelected: Bool

    var body: some View {
        switch pane.kind {
        case .terminal:
            TerminalViewRepresentable()
        case .browser:
            BrowserPaneView()
        }
    }
}

// MARK: - Terminal

struct TerminalViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let vibrantContainer = NSVisualEffectView(frame: .zero)
        vibrantContainer.material = .hudWindow
        vibrantContainer.blendingMode = .behindWindow
        vibrantContainer.state = .active

        let terminalView = LocalProcessTerminalView(frame: .zero)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        terminalView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        terminalView.nativeBackgroundColor = .clear
        terminalView.startProcess(executable: shell, environment: nil, execName: "-" + (shell as NSString).lastPathComponent)
        terminalView.send(txt: "cd \(home)\r")

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        vibrantContainer.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: vibrantContainer.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: vibrantContainer.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: vibrantContainer.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: vibrantContainer.trailingAnchor),
        ])

        return vibrantContainer
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Browser

@Observable
final class BrowserState {
    var urlText: String = "https://apple.com"
    var pendingURL: URL?

    init() {
        pendingURL = URL(string: urlText)
    }

    func navigate() {
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            text = "https://\(text)"
            urlText = text
        }
        pendingURL = URL(string: text)
    }
}

struct BrowserPaneView: View {
    @State private var state = BrowserState()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("URL", text: $state.urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.navigate() }
            }
            .padding(8)

            WebViewRepresentable(state: state)
        }
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let state: BrowserState

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        if let url = state.pendingURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let pending = state.pendingURL else { return }
        if nsView.url != pending {
            nsView.load(URLRequest(url: pending))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let state: BrowserState

        init(state: BrowserState) {
            self.state = state
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url {
                state.urlText = url.absoluteString
                state.pendingURL = nil
            }
        }
    }
}
