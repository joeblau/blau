import Foundation
import SwiftData

enum PaneKind: String, Codable, CaseIterable {
    case terminal
    case browser
}

@Observable
final class TerminalPaneState {
    var currentDirectory: String = ""
}

enum AppearanceMode: String, Codable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

@Model
final class BrowserState {
    var urlText: String = "https://apple.com"
    var appearanceModeRaw: String = AppearanceMode.system.rawValue
    var navigationRequestID: Int = 0
    var inspectorToggleRequestID: Int = 0

    @Transient var pendingURL: URL? = nil
    @Transient var canGoBack: Bool = false
    @Transient var canGoForward: Bool = false
    @Transient var isLoading: Bool = false
    @Transient var showDevTools: Bool = false
    @Transient var needsInspectorToggle: Bool = false

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        set { appearanceModeRaw = newValue.rawValue }
    }

    init() {
        self.pendingURL = URL(string: urlText)
    }

    func navigate() {
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            text = "https://\(text)"
            urlText = text
        }
        issueNavigationRequest(URL(string: text))
    }

    func requestNavigationCommand(_ command: String) {
        issueNavigationRequest(URL(string: command))
    }

    func toggleDeveloperTools() {
        showDevTools.toggle()
        needsInspectorToggle = true
        inspectorToggleRequestID += 1
    }

    private func issueNavigationRequest(_ request: URL?) {
        pendingURL = request
        navigationRequestID += 1
    }
}

@Model
final class Pane {
    #Unique([\Pane.id])

    var id: UUID = UUID()
    var kindRaw: String = PaneKind.terminal.rawValue
    var sortOrder: Int = 0

    @Relationship(deleteRule: .cascade)
    var browserState: BrowserState?

    var workspace: Workspace?

    @Transient var terminalState: TerminalPaneState = TerminalPaneState()

    var kind: PaneKind {
        get { PaneKind(rawValue: kindRaw) ?? .terminal }
        set { kindRaw = newValue.rawValue }
    }

    init(kind: PaneKind = .terminal, sortOrder: Int = 0) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.sortOrder = sortOrder
        if kind == .browser {
            self.browserState = BrowserState()
        }
    }
}

enum PaneAxis: String, Codable {
    case vertical
    case horizontal
}

@Model
final class Workspace {
    #Unique([\Workspace.id])

    var id: UUID = UUID()
    var name: String = ""
    var selectedPaneID: UUID?
    var axisRaw: String = PaneAxis.vertical.rawValue

    @Relationship(deleteRule: .cascade, inverse: \Pane.workspace)
    var panes: [Pane] = []

    var selectedPane: Pane? {
        sortedPanes.first { $0.id == selectedPaneID }
    }

    var sortedPanes: [Pane] {
        panes.sorted { $0.sortOrder < $1.sortOrder }
    }

    var axis: PaneAxis {
        get { PaneAxis(rawValue: axisRaw) ?? .vertical }
        set { axisRaw = newValue.rawValue }
    }

    init(name: String) {
        self.id = UUID()
        self.name = name
        let initialPane = Pane(kind: .terminal)
        self.panes = [initialPane]
        self.selectedPaneID = initialPane.id
    }

    func addPane(kind: PaneKind, side: Side) {
        let maxOrder = panes.map(\.sortOrder).max() ?? -1
        let pane = Pane(kind: kind, sortOrder: maxOrder + 1)

        if let selectedID = selectedPaneID,
           let selectedPane = sortedPanes.first(where: { $0.id == selectedID }),
           let index = sortedPanes.firstIndex(where: { $0.id == selectedID }) {
            let insertOrder: Int
            if side == .left {
                insertOrder = selectedPane.sortOrder
                for p in panes where p.sortOrder >= insertOrder {
                    p.sortOrder += 1
                }
            } else {
                let nextIndex = index + 1
                if nextIndex < sortedPanes.count {
                    insertOrder = sortedPanes[nextIndex].sortOrder
                    for p in panes where p.sortOrder >= insertOrder {
                        p.sortOrder += 1
                    }
                } else {
                    insertOrder = selectedPane.sortOrder + 1
                }
            }
            pane.sortOrder = insertOrder
        }

        panes.append(pane)
        selectedPaneID = pane.id
    }

    func removePane(_ pane: Pane) {
        panes.removeAll { $0.id == pane.id }
        if selectedPaneID == pane.id {
            selectedPaneID = sortedPanes.first?.id
        }
    }

    enum Side {
        case left, right
    }
}
