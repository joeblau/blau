import Foundation
import SwiftData
import Testing
@testable import Pilot

@Suite("Walkie terminal and remote delivery", .serialized)
@MainActor
struct PilotWalkieDeliveryTests {
    @Test("Remote dictation and Enter stay on the original computer after selecting another tab")
    func remoteDeliveryRemainsPinned() throws {
        try withFixture { store, _, connections in
            let recorder = DeliveryRecorder()
            let sessionID = UUID()
            recorder.sessions[connections[0].id] = sessionID
            recorder.sessions[connections[1].id] = UUID()
            let delivery = recorder.delivery(store: store)
            let recordingID = UUID()
            let workspaceID = WorkspaceStore.remoteDesktopWorkspaceID
            store.selectRemoteDesktopTab(connections[0].id)
            var state = PilotWalkieInputState()
            delivery.start(.init(control: .start, workspaceID: workspaceID, recordingID: recordingID), state: &state)

            store.selectRemoteDesktopTab(connections[1].id)
            #expect(delivery.receive(.init(workspaceID: workspaceID, text: "echo hello\nworld",
                                          recordingID: recordingID), state: &state))
            #expect(delivery.execute(.init(recordingID: recordingID, workspaceID: workspaceID), state: &state))
            #expect(!delivery.execute(.init(recordingID: recordingID, workspaceID: workspaceID), state: &state))

            let target = PilotWalkieInputState.Target(workspaceID: workspaceID, destination: .remoteDesktop(
                connectionID: connections[0].id, sessionID: sessionID
            ))
            #expect(recorder.events == [.text(target, "echo hello world"), .enter(target)])
            #expect(recorder.terminalLookups == 0)
        }
    }

    @Test("Reconnection before transcript delivery never types into the new VNC session")
    func reconnectionBeforeTextRejectsDelivery() throws {
        try withFixture { store, _, connections in
            let recorder = DeliveryRecorder()
            recorder.sessions[connections[0].id] = UUID()
            let delivery = recorder.delivery(store: store)
            let recordingID = UUID()
            let workspaceID = WorkspaceStore.remoteDesktopWorkspaceID
            store.selectRemoteDesktopTab(connections[0].id)
            var state = PilotWalkieInputState()
            delivery.start(.init(control: .start, workspaceID: workspaceID, recordingID: recordingID), state: &state)
            recorder.sessions[connections[0].id] = UUID()

            #expect(!delivery.receive(.init(workspaceID: workspaceID, text: "do not send",
                                           recordingID: recordingID), state: &state))
            #expect(!delivery.execute(.init(recordingID: recordingID, workspaceID: workspaceID), state: &state))
            #expect(recorder.events.isEmpty)
            #expect(recorder.terminalLookups == 0)
        }
    }

    @Test("Reconnection after text delivery cannot execute in a replacement VNC session")
    func reconnectionBeforeEnterRejectsExecution() throws {
        try withFixture { store, _, connections in
            let recorder = DeliveryRecorder()
            recorder.sessions[connections[0].id] = UUID()
            let delivery = recorder.delivery(store: store)
            let recordingID = UUID()
            let workspaceID = WorkspaceStore.remoteDesktopWorkspaceID
            store.selectRemoteDesktopTab(connections[0].id)
            var state = PilotWalkieInputState()
            delivery.start(.init(control: .start, workspaceID: workspaceID, recordingID: recordingID), state: &state)
            #expect(delivery.receive(.init(workspaceID: workspaceID, text: "git status",
                                          recordingID: recordingID), state: &state))
            recorder.sessions[connections[0].id] = UUID()

            #expect(!delivery.execute(.init(recordingID: recordingID, workspaceID: workspaceID), state: &state))
            #expect(recorder.events.count == 1)
        }
    }

    @Test("An offline remote computer cannot fall back to a local terminal")
    func unavailableRemoteNeverUsesTerminal() throws {
        try withFixture { store, _, connections in
            let recorder = DeliveryRecorder()
            let delivery = recorder.delivery(store: store)
            let recordingID = UUID()
            let workspaceID = WorkspaceStore.remoteDesktopWorkspaceID
            store.selectRemoteDesktopTab(connections[0].id)
            var state = PilotWalkieInputState()
            delivery.start(.init(control: .start, workspaceID: nil, recordingID: recordingID), state: &state)
            #expect(!delivery.receive(.init(workspaceID: nil, text: "offline", recordingID: recordingID), state: &state))
            #expect(!delivery.execute(.init(recordingID: recordingID, workspaceID: workspaceID), state: &state))
            #expect(!delivery.enterSelection())
            #expect(recorder.events.isEmpty)
            #expect(recorder.terminalLookups == 0)
        }
    }

    @Test("Local dictation remains pinned when the user opens Remote Desktop")
    func localDeliveryStillUsesTerminal() throws {
        try withFixture { store, workspace, connections in
            let recorder = DeliveryRecorder()
            let delivery = recorder.delivery(store: store)
            let recordingID = UUID()
            var state = PilotWalkieInputState()
            delivery.start(.init(control: .start, workspaceID: workspace.id, recordingID: recordingID), state: &state)
            store.selectRemoteDesktopTab(connections[0].id)
            #expect(delivery.receive(.init(workspaceID: workspace.id, text: "pwd", recordingID: recordingID), state: &state))
            #expect(delivery.execute(.init(recordingID: recordingID, workspaceID: workspace.id), state: &state))
            let target = PilotWalkieInputState.Target(workspaceID: workspace.id, paneID: recorder.paneID)
            #expect(recorder.events == [.text(target, "pwd"), .enter(target)])
        }
    }

    private func withFixture(_ body: (WorkspaceStore, Workspace, [RemoteDesktopConnection]) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = ["selectedWorkspaceID", "selectedRemoteConnectionID", "selectedNoteID",
                    "notesMode", "remoteDesktopMode", "dockerMode", "agenticUseMode"]
        let original = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, original) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        let schema = Schema([Workspace.self, Pane.self, BrowserState.self, EditorState.self,
                             Note.self, RemoteDesktopConnection.self, ExtensionWorkspaceLink.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: true
        ))
        let workspace = Workspace(name: "Local")
        container.mainContext.insert(workspace)
        let connections = [RemoteDesktopConnection(host: "mini01.local"), RemoteDesktopConnection(host: "mini02.local")]
        for connection in connections { container.mainContext.insert(connection) }
        try container.mainContext.save()
        let store = WorkspaceStore(modelContext: container.mainContext)
        store.selectWorkspace(workspace.id)
        try body(store, workspace, connections)
        withExtendedLifetime(container) {}
    }
}

@MainActor
private final class DeliveryRecorder {
    enum Event: Equatable {
        case text(PilotWalkieInputState.Target, String)
        case enter(PilotWalkieInputState.Target)
    }
    let paneID = UUID()
    var terminalLookups = 0
    var sessions: [UUID: UUID] = [:]
    var events: [Event] = []

    func delivery(store: WorkspaceStore) -> PilotWalkieDelivery {
        PilotWalkieDelivery(store: store, terminalPaneID: { [self] _ in
            terminalLookups += 1
            return paneID
        }, remoteSessionID: { [self] in sessions[$0] }, insertText: { [self] target, text in
            guard isAvailable(target) else { return false }
            events.append(.text(target, text))
            return true
        }, sendEnter: { [self] target in
            guard isAvailable(target) else { return false }
            events.append(.enter(target))
            return true
        })
    }

    private func isAvailable(_ target: PilotWalkieInputState.Target) -> Bool {
        switch target.destination {
        case .terminal: return true
        case .remoteDesktop(let connectionID, let sessionID): return sessions[connectionID] == sessionID
        }
    }
}
