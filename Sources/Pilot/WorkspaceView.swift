import SwiftUI
import SwiftTerm
@preconcurrency import WebKit

struct WorkspaceView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        panesContainer
            .navigationTitle(workspace.name)
            .toolbar { paneToolbar }
    }

    private var panesContainer: some View {
        HStack(spacing: 0) {
            ForEach(workspace.panes) { pane in
                paneCell(pane)
                if pane.id != workspace.panes.last?.id {
                    Divider()
                }
            }
        }
    }

    private func paneCell(_ pane: Pane) -> some View {
        PaneView(pane: pane, isSelected: workspace.selectedPaneID == pane.id)
            .onTapGesture { workspace.selectedPaneID = pane.id }
            .overlay(alignment: .top) {
                if workspace.selectedPaneID == pane.id && workspace.panes.count > 1 {
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                }
            }
            .contextMenu {
                Button("Close Pane", role: .destructive) {
                    workspace.removePane(pane)
                }
                .disabled(workspace.panes.count <= 1)
            }
    }

    @ToolbarContentBuilder
    private var paneToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("Add Left") {
                    Button("Terminal", systemImage: "terminal") {
                        workspace.addPane(kind: .terminal, side: .left)
                    }
                    Button("Browser", systemImage: "safari") {
                        workspace.addPane(kind: .browser, side: .left)
                    }
                }
                Section("Add Right") {
                    Button("Terminal", systemImage: "terminal") {
                        workspace.addPane(kind: .terminal, side: .right)
                    }
                    Button("Browser", systemImage: "safari") {
                        workspace.addPane(kind: .browser, side: .right)
                    }
                }
            } label: {
                Label("Add Pane", systemImage: "rectangle.split.1x2")
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
