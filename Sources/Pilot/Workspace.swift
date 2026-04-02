import Foundation

enum PaneKind: String, CaseIterable {
    case terminal
    case browser
}

@Observable
final class Pane: Identifiable {
    let id: UUID
    var kind: PaneKind

    init(kind: PaneKind = .terminal) {
        self.id = UUID()
        self.kind = kind
    }
}

@Observable
final class Workspace: Identifiable {
    let id: UUID
    var name: String
    var panes: [Pane]
    var selectedPaneID: UUID?

    init(name: String) {
        self.id = UUID()
        self.name = name
        let initialPane = Pane(kind: .terminal)
        self.panes = [initialPane]
        self.selectedPaneID = initialPane.id
    }

    func addPane(kind: PaneKind, side: Side) {
        let pane = Pane(kind: kind)
        if let selectedID = selectedPaneID,
           let index = panes.firstIndex(where: { $0.id == selectedID }) {
            let insertIndex = side == .left ? index : index + 1
            panes.insert(pane, at: insertIndex)
        } else {
            if side == .left {
                panes.insert(pane, at: 0)
            } else {
                panes.append(pane)
            }
        }
        selectedPaneID = pane.id
    }

    func removePane(_ pane: Pane) {
        panes.removeAll { $0.id == pane.id }
        if selectedPaneID == pane.id {
            selectedPaneID = panes.first?.id
        }
    }

    enum Side {
        case left, right
    }
}
