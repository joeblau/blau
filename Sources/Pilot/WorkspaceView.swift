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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.panes) { pane in
                    tabItem(pane)
                }
            }
        }
        .frame(height: 30)
        .background(.bar)
    }

    private func tabItem(_ pane: Pane) -> some View {
        let isSelected = workspace.selectedPaneID == pane.id

        return HStack(spacing: 4) {
            Image(systemName: pane.kind == .terminal ? "terminal" : "safari")
                .font(.caption2)
            Text(pane.kind == .terminal ? "Terminal" : "Browser")
                .font(.caption)
                .lineLimit(1)

            if workspace.panes.count > 1 {
                Button {
                    workspace.removePane(pane)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectedPaneID = pane.id }
        .draggable(pane.id.uuidString) {
            Text(pane.kind == .terminal ? "Terminal" : "Browser")
                .padding(6)
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
                workspace.axis = workspace.axis == .vertical ? .horizontal : .vertical
            } label: {
                Label("Toggle Layout",
                      systemImage: workspace.axis == .vertical
                          ? "rectangle.split.1x2"
                          : "rectangle.split.2x1")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            let beforeLabel = workspace.axis == .vertical ? "Add Left" : "Add Above"
            let afterLabel = workspace.axis == .vertical ? "Add Right" : "Add Below"
            Menu {
                Section(beforeLabel) {
                    Button("Terminal", systemImage: "terminal") {
                        workspace.addPane(kind: .terminal, side: .left)
                    }
                    Button("Browser", systemImage: "safari") {
                        workspace.addPane(kind: .browser, side: .left)
                    }
                }
                Section(afterLabel) {
                    Button("Terminal", systemImage: "terminal") {
                        workspace.addPane(kind: .terminal, side: .right)
                    }
                    Button("Browser", systemImage: "safari") {
                        workspace.addPane(kind: .browser, side: .right)
                    }
                }
            } label: {
                Label("Add Pane", systemImage: "plus.rectangle")
            }
        }
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
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminalView = LocalProcessTerminalView(frame: .zero)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        terminalView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        terminalView.startProcess(executable: shell, environment: nil, execName: "-" + (shell as NSString).lastPathComponent)
        terminalView.send(txt: "cd \(home)\r")

        return terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
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
