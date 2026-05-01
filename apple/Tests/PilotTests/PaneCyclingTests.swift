import Foundation
import Testing
@testable import Pilot

@Suite("Pane cycling (⌘← / ⌘→)")
struct PaneCyclingTests {

    @Test
    func nextWrapsAround() {
        let workspace = Workspace(name: "Test")
        let a = Pane(kind: .terminal, sortOrder: 0)
        let b = Pane(kind: .browser, sortOrder: 1)
        let c = Pane(kind: .terminal, sortOrder: 2)
        attach(workspace: workspace, panes: [a, b, c], selectedPaneID: a.id)

        workspace.selectNextPane()
        #expect(workspace.selectedPaneID == b.id)
        workspace.selectNextPane()
        #expect(workspace.selectedPaneID == c.id)
        workspace.selectNextPane()
        #expect(workspace.selectedPaneID == a.id) // wrapped
    }

    @Test
    func previousWrapsAround() {
        let workspace = Workspace(name: "Test")
        let a = Pane(kind: .terminal, sortOrder: 0)
        let b = Pane(kind: .browser, sortOrder: 1)
        attach(workspace: workspace, panes: [a, b], selectedPaneID: a.id)

        workspace.selectPreviousPane()
        #expect(workspace.selectedPaneID == b.id) // wrapped backward
    }

    @Test
    func collapsedPanesAreSkipped() {
        let workspace = Workspace(name: "Test")
        let a = Pane(kind: .terminal, sortOrder: 0)
        let b = Pane(kind: .browser, sortOrder: 1)
        let c = Pane(kind: .terminal, sortOrder: 2)
        b.isCollapsed = true
        attach(workspace: workspace, panes: [a, b, c], selectedPaneID: a.id)

        workspace.selectNextPane()
        #expect(workspace.selectedPaneID == c.id) // skipped collapsed `b`
    }

    @Test
    func singleVisiblePaneIsNoOp() {
        let workspace = Workspace(name: "Test")
        let a = Pane(kind: .terminal, sortOrder: 0)
        let b = Pane(kind: .browser, sortOrder: 1)
        b.isCollapsed = true
        attach(workspace: workspace, panes: [a, b], selectedPaneID: a.id)

        workspace.selectNextPane()
        #expect(workspace.selectedPaneID == a.id)
        workspace.selectPreviousPane()
        #expect(workspace.selectedPaneID == a.id)
    }

    @Test
    func focusModeCyclesFullScreenedPane() {
        let workspace = Workspace(name: "Test")
        let a = Pane(kind: .terminal, sortOrder: 0)
        let b = Pane(kind: .browser, sortOrder: 1)
        let c = Pane(kind: .terminal, sortOrder: 2)
        attach(workspace: workspace, panes: [a, b, c], selectedPaneID: a.id)
        workspace.focusPane(a)
        #expect(workspace.focusedPaneID == a.id)
        #expect(b.isCollapsed && c.isCollapsed)

        workspace.selectNextPane()
        #expect(workspace.focusedPaneID == b.id)
        #expect(workspace.selectedPaneID == b.id)
        #expect(!b.isCollapsed)
        #expect(a.isCollapsed && c.isCollapsed)

        workspace.selectNextPane()
        #expect(workspace.focusedPaneID == c.id)

        workspace.selectNextPane()
        #expect(workspace.focusedPaneID == a.id) // wrapped
    }

    @Test
    func focusModePreviousWraps() {
        let workspace = Workspace(name: "Test")
        let a = Pane(kind: .terminal, sortOrder: 0)
        let b = Pane(kind: .browser, sortOrder: 1)
        attach(workspace: workspace, panes: [a, b], selectedPaneID: a.id)
        workspace.focusPane(a)

        workspace.selectPreviousPane()
        #expect(workspace.focusedPaneID == b.id) // wrapped backward
    }

    @Test
    func cyclingOntoTerminalUpdatesFrontmostTerminalID() {
        let workspace = Workspace(name: "Test")
        let browser = Pane(kind: .browser, sortOrder: 0)
        let terminal = Pane(kind: .terminal, sortOrder: 1)
        attach(workspace: workspace, panes: [browser, terminal], selectedPaneID: browser.id)
        workspace.frontmostTerminalPaneID = nil

        workspace.selectNextPane()
        #expect(workspace.selectedPaneID == terminal.id)
        #expect(workspace.frontmostTerminalPaneID == terminal.id)
    }

    private func attach(workspace: Workspace, panes: [Pane], selectedPaneID: UUID) {
        workspace.panes = panes
        for pane in panes { pane.workspace = workspace }
        workspace.selectedPaneID = selectedPaneID
    }
}
