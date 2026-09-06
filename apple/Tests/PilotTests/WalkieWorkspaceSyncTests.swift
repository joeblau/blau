import Foundation
import SwiftData
import Testing
@testable import Pilot

@Suite("Walkie workspace sync", .serialized)
@MainActor
struct WalkieWorkspaceSyncTests {
    @Test("Saved computers appear as pinned Remote Desktop tabs without changing workspace summaries")
    func remoteTabsArePublished() throws {
        try withStore { store, workspaces, connections in
            let localSummaries = store.summaries
            store.selectedRemoteConnectionID = connections[1].id
            let published = store.syncSummaries
            let remote = try #require(published.first)

            #expect(remote.id == WorkspaceStore.remoteDesktopWorkspaceID)
            #expect(remote.name == "Remote Desktop")
            #expect(remote.isPinned)
            #expect(remote.tabs.map(\.id) == connections.map(\.id))
            #expect(remote.tabs.map(\.title) == ["Mini01", "mini02.local"])
            #expect(remote.tabs.allSatisfy { $0.systemImageName == "display" })
            #expect(remote.selectedTabID == connections[1].id)
            #expect(Array(published.dropFirst()) == localSummaries)
            #expect(store.summaries == localSummaries)
            #expect(store.selectedSyncWorkspaceID == workspaces[0].id)
            #expect(store.workspaces.allSatisfy { $0.id != WorkspaceStore.remoteDesktopWorkspaceID })
        }
    }

    @Test("Remote tab selection enters Remote Desktop and returning to a workspace restores local sync selection")
    func remoteAndLocalSelectionStayInSync() throws {
        try withStore { store, workspaces, connections in
            store.enterNotesMode()
            #expect(store.selectRemoteDesktopTab(connections[1].id))
            #expect(store.isRemoteDesktopMode)
            #expect(!store.isNotesMode)
            #expect(store.selectedRemoteConnectionID == connections[1].id)
            #expect(store.selectedWorkspaceID == workspaces[0].id)
            #expect(store.selectedSyncWorkspaceID == WorkspaceStore.remoteDesktopWorkspaceID)
            #expect(store.syncSummaries.first?.selectedTabID == connections[1].id)

            store.selectWorkspace(workspaces[1].id)
            #expect(!store.isRemoteDesktopMode)
            #expect(store.isWorkspaceDetailVisible)
            #expect(store.selectedSyncWorkspaceID == workspaces[1].id)
            #expect(store.syncSummaries.first?.selectedTabID == connections[1].id)
        }
    }

    @Test("Stale remote tab IDs leave both the workspace and remote selection unchanged")
    func staleRemoteSelectionIsRejected() throws {
        try withStore { store, workspaces, connections in
            store.selectedRemoteConnectionID = connections[0].id
            #expect(!store.selectRemoteDesktopTab(UUID()))
            #expect(store.selectedWorkspaceID == workspaces[0].id)
            #expect(store.selectedRemoteConnectionID == connections[0].id)
            #expect(!store.isRemoteDesktopMode)
            #expect(store.selectedSyncWorkspaceID == workspaces[0].id)

            #expect(store.selectRemoteDesktopTab(connections[1].id))
            #expect(!store.selectRemoteDesktopTab(UUID()))
            #expect(store.isRemoteDesktopMode)
            #expect(store.selectedRemoteConnectionID == connections[1].id)
            #expect(store.selectedSyncWorkspaceID == WorkspaceStore.remoteDesktopWorkspaceID)
        }
    }

    @Test("An empty Remote Desktop row appears only while its global mode is active")
    func emptyRemoteDesktopOnlyAppearsWhenActive() throws {
        try withStore(includeConnections: false) { store, workspaces, _ in
            #expect(store.syncSummaries == store.summaries)
            #expect(store.selectedSyncWorkspaceID == workspaces[0].id)

            store.enterRemoteDesktopMode()
            let remote = try #require(store.syncSummaries.first)
            #expect(remote.id == WorkspaceStore.remoteDesktopWorkspaceID)
            #expect(remote.tabs.isEmpty)
            #expect(remote.selectedTabID == nil)
            #expect(store.selectedSyncWorkspaceID == WorkspaceStore.remoteDesktopWorkspaceID)

            store.selectWorkspace(workspaces[0].id)
            #expect(store.syncSummaries == store.summaries)
            #expect(store.selectedSyncWorkspaceID == workspaces[0].id)
        }
    }

    private func withStore(
        includeConnections: Bool = true,
        _ body: (WorkspaceStore, [Workspace], [RemoteDesktopConnection]) throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        let keys = [
            "selectedWorkspaceID", "selectedRemoteConnectionID", "selectedNoteID",
            "notesMode", "remoteDesktopMode", "dockerMode", "agenticUseMode",
        ]
        let originalValues = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, originalValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        let schema = Schema([
            Workspace.self, Pane.self, BrowserState.self, EditorState.self,
            Note.self, RemoteDesktopConnection.self, ExtensionWorkspaceLink.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let workspaces = [Workspace(name: "Alpha"), Workspace(name: "Beta")]
        workspaces[1].isPinned = true
        for workspace in workspaces { container.mainContext.insert(workspace) }
        let connections = includeConnections ? [
            RemoteDesktopConnection(host: "mini01.local", nickname: " Mini01 ", sortOrder: 0),
            RemoteDesktopConnection(host: "mini02.local", sortOrder: 1),
        ] : []
        for connection in connections.reversed() { container.mainContext.insert(connection) }
        try container.mainContext.save()
        let store = WorkspaceStore(modelContext: container.mainContext)
        store.selectWorkspace(workspaces[0].id)
        store.selectedRemoteConnectionID = nil
        try body(store, workspaces, connections)
        withExtendedLifetime(container) {}
    }
}
