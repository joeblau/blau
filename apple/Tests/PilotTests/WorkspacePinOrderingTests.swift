import Foundation
import SwiftData
import Testing
@testable import Pilot

/// Pinning appends to the end of the pinned section; unpinning jumps to the
/// top of the unpinned section. The two directions are deliberately not
/// symmetric, so both are covered here.
@Suite("Workspace pin ordering", .serialized)
@MainActor
struct WorkspacePinOrderingTests {

    @Test("Pinning appends to the bottom of the pinned section")
    func pinningAppendsToPinnedSection() throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta", "Gamma"])
        let store = fixture.store

        store.togglePin(fixture.workspaces[0]) // Alpha
        store.togglePin(fixture.workspaces[1]) // Beta

        // Alpha was pinned first and keeps the top slot; Beta lands beneath it
        // rather than displacing it.
        #expect(names(ofPinned: true, in: store) == ["Alpha", "Beta"])

        store.togglePin(fixture.workspaces[2]) // Gamma
        #expect(names(ofPinned: true, in: store) == ["Alpha", "Beta", "Gamma"])
    }

    @Test("Unpinning moves to the top of the unpinned section")
    func unpinningPrependsToUnpinnedSection() throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta", "Gamma"])
        let store = fixture.store

        store.togglePin(fixture.workspaces[0]) // Alpha pinned
        store.togglePin(fixture.workspaces[0]) // Alpha unpinned again

        // Alpha returns above Beta and Gamma, which were never pinned.
        #expect(names(ofPinned: false, in: store) == ["Alpha", "Beta", "Gamma"])
        #expect(names(ofPinned: true, in: store).isEmpty)
    }

    @Test("Pinned workspaces sort ahead of unpinned ones")
    func pinnedSectionLeadsTheList() throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta", "Gamma"])
        let store = fixture.store

        store.togglePin(fixture.workspaces[2]) // Gamma

        #expect(store.workspaces.map(\.name) == ["Gamma", "Alpha", "Beta"])
    }

    private func names(ofPinned pinned: Bool, in store: WorkspaceStore) -> [String] {
        store.workspaces.filter { $0.isPinned == pinned }.map(\.name)
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
