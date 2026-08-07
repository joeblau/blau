import Foundation
import SwiftData
import Testing
@testable import Pilot

/// The empty detail area offers pinned workspaces as quick-jump buttons. The
/// shortcut hint on each button is the risky part: it is derived from position
/// rather than stored, so it has to stay in step with the ⌘1…⌘9 binding, which
/// covers only the first nine workspaces.
@Suite("Pinned quick jump", .serialized)
@MainActor
struct PinnedQuickJumpTests {
    @Test("Only pinned workspaces appear")
    func listsOnlyPinnedWorkspaces() throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta", "Gamma"])
        let store = fixture.store
        store.togglePin(fixture.workspaces[1])   // Beta

        let targets = PinnedQuickJumpTarget.targets(in: store.workspaces)
        #expect(targets.map(\.name) == ["Beta"])
    }

    @Test("Nothing is offered when nothing is pinned")
    func emptyWithoutPins() throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta"])
        #expect(PinnedQuickJumpTarget.targets(in: fixture.store.workspaces).isEmpty)
    }

    @Test("Shortcut numbers match the ⌘-number binding order")
    func shortcutsMatchWorkspaceOrder() throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta", "Gamma"])
        let store = fixture.store
        store.togglePin(fixture.workspaces[2])   // Gamma pinned first
        store.togglePin(fixture.workspaces[0])   // Alpha pinned second

        // Pinned workspaces sort to the front, so they take ⌘1 and ⌘2 — the same
        // slots `workspaces.prefix(9)` hands to WorkspaceNumberShortcuts.
        let ordered = store.workspaces
        #expect(ordered.map(\.name) == ["Gamma", "Alpha", "Beta"])

        let targets = PinnedQuickJumpTarget.targets(in: ordered)
        #expect(targets.map(\.name) == ["Gamma", "Alpha"])
        #expect(targets.map(\.shortcutNumber) == [1, 2])
    }

    @Test("The cap keeps every advertised shortcut inside the ⌘1…⌘9 window")
    func capKeepsShortcutsValid() throws {
        let fixture = try makeFixture(names: (1...12).map { "W\($0)" })
        for workspace in fixture.workspaces { fixture.store.togglePin(workspace) }

        let targets = PinnedQuickJumpTarget.targets(in: fixture.store.workspaces)
        #expect(targets.count == PinnedQuickJumpTarget.maximumCount)
        // This is the invariant the cap exists to guarantee: no button can claim
        // a ⌘-number that the shortcut binding does not actually deliver.
        #expect(targets.allSatisfy { $0.shortcutNumber <= PinnedQuickJumpTarget.highestShortcutNumber })
        #expect(targets.map(\.shortcutNumber) == Array(1...PinnedQuickJumpTarget.maximumCount))
    }

    @Test("An unnamed workspace still gets a readable button")
    func namesBlankWorkspaces() throws {
        let fixture = try makeFixture(names: ["   "])
        fixture.store.togglePin(fixture.workspaces[0])

        let target = try #require(PinnedQuickJumpTarget.targets(in: fixture.store.workspaces).first)
        #expect(target.name == "Untitled Workspace")
    }

    private func makeFixture(names: [String]) throws -> (
        container: ModelContainer,
        store: WorkspaceStore,
        workspaces: [Workspace]
    ) {
        let schema = Schema([
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self,
            ExtensionWorkspaceLink.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let workspaces = names.enumerated().map { index, name -> Workspace in
            let workspace = Workspace(name: name)
            workspace.workspaceSortOrder = index
            container.mainContext.insert(workspace)
            return workspace
        }
        try container.mainContext.save()

        let store = WorkspaceStore(modelContext: container.mainContext)
        store.isNotesMode = false
        store.isRemoteDesktopMode = false
        store.isDockerMode = false
        return (container, store, workspaces)
    }
}
