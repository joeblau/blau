import Foundation
import SwiftData
import Testing
@testable import Pilot

@Suite("Extension window workspace sync", .serialized)
@MainActor
struct ExtensionWindowSyncTests {
    @Test("Main and extension project the same canonical workspace")
    func sharedStoreSelectionIsBidirectional() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()

        // These aliases model the references injected into the two sibling
        // SwiftUI scenes. There must be one canonical store, not two stores
        // synchronized after the fact.
        let mainWindowStore = fixture.store
        let extensionWindowStore = fixture.store

        mainWindowStore.selectWorkspace(fixture.alpha.id)
        #expect(extensionWindowStore.selectedWorkspace?.id == fixture.alpha.id)

        extensionWindowStore.selectWorkspace(fixture.beta.id)
        #expect(mainWindowStore.selectedWorkspace?.id == fixture.beta.id)
    }

    @Test("Selecting from the extension exits global detail modes")
    func extensionSelectionReturnsMainWindowToWorkspaceMode() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()

        fixture.store.enterNotesMode()
        fixture.store.selectWorkspace(fixture.beta.id)
        #expect(!fixture.store.isNotesMode)
        #expect(!fixture.store.isRemoteDesktopMode)
        #expect(fixture.store.selectedWorkspaceID == fixture.beta.id)

        fixture.store.enterRemoteDesktopMode()
        fixture.store.selectWorkspace(fixture.alpha.id)
        #expect(!fixture.store.isNotesMode)
        #expect(!fixture.store.isRemoteDesktopMode)
        #expect(fixture.store.selectedWorkspaceID == fixture.alpha.id)
    }

    @Test("Each workspace restores its own extension tab")
    func extensionTabIsWorkspaceScoped() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()
        fixture.alpha.setInspectorTab(.filesystem)
        fixture.beta.setInspectorTab(.tasks)

        fixture.store.selectWorkspace(fixture.alpha.id)
        #expect(fixture.store.selectedWorkspace?.inspectorTab == .filesystem)

        fixture.store.selectWorkspace(fixture.beta.id)
        #expect(fixture.store.selectedWorkspace?.inspectorTab == .tasks)

        fixture.store.selectWorkspace(fixture.alpha.id)
        #expect(fixture.store.selectedWorkspace?.inspectorTab == .filesystem)
    }

    private func makeFixture() throws -> (
        container: ModelContainer,
        store: WorkspaceStore,
        alpha: Workspace,
        beta: Workspace
    ) {
        let schema = Schema([
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let alpha = Workspace(name: "Alpha")
        let beta = Workspace(name: "Beta")
        alpha.workspaceSortOrder = 0
        beta.workspaceSortOrder = 1
        container.mainContext.insert(alpha)
        container.mainContext.insert(beta)
        try container.mainContext.save()

        let store = WorkspaceStore(modelContext: container.mainContext)
        store.isNotesMode = false
        store.isRemoteDesktopMode = false
        return (container, store, alpha, beta)
    }
}

@MainActor
private struct DefaultsSnapshot {
    private static let keys = [
        "selectedWorkspaceID",
        "selectedNoteID",
        "notesMode",
        "selectedRemoteConnectionID",
        "remoteDesktopMode",
    ]

    private let values: [String: Any]
    private let missingKeys: Set<String>

    init(defaults: UserDefaults = .standard) {
        var values: [String: Any] = [:]
        var missingKeys: Set<String> = []
        for key in Self.keys {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            } else {
                missingKeys.insert(key)
            }
        }
        self.values = values
        self.missingKeys = missingKeys
    }

    func restore(defaults: UserDefaults = .standard) {
        for key in Self.keys {
            if missingKeys.contains(key) {
                defaults.removeObject(forKey: key)
            } else if let value = values[key] {
                defaults.set(value, forKey: key)
            }
        }
    }
}
