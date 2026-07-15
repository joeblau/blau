import SwiftData
import Testing
@testable import Pilot

@Suite("Runtime resource teardown")
@MainActor
struct RuntimeTeardownTests {
    @Test("Deleting a workspace removes device and simulator sessions")
    func deletingWorkspaceTearsDownEveryRuntimePane() throws {
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
        let store = WorkspaceStore(modelContext: container.mainContext)
        let workspace = Workspace(name: "Runtime teardown")
        let device = Pane(kind: .device, sortOrder: 0)
        let simulator = Pane(kind: .simulator, sortOrder: 1)
        workspace.panes = [device, simulator]
        device.workspace = workspace
        simulator.workspace = workspace
        container.mainContext.insert(workspace)
        try container.mainContext.save()

        _ = DeviceCaptureRegistry.shared.session(for: device.id)
        _ = SimulatorRegistry.shared.session(for: simulator.id)
        #expect(DeviceCaptureRegistry.shared.existingSession(for: device.id) != nil)
        #expect(SimulatorRegistry.shared.existingSession(for: simulator.id) != nil)

        store.deleteWorkspace(workspace)

        #expect(DeviceCaptureRegistry.shared.existingSession(for: device.id) == nil)
        #expect(SimulatorRegistry.shared.existingSession(for: simulator.id) == nil)
    }
}
