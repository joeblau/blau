import Foundation
import Testing

@testable import Copilot

@Suite("SyncMessage Encoding")
struct SyncMessagesTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("WorkspaceState round-trip")
    func workspaceStateRoundTrip() throws {
        let state = WorkspaceState(
            workspaces: [
                WorkspaceSummary(id: UUID(), name: "Terminal"),
                WorkspaceSummary(id: UUID(), name: "Browser"),
            ],
            selectedWorkspaceID: nil
        )
        let message = SyncMessage.workspaceState(state)
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(SyncMessage.self, from: data)

        if case .workspaceState(let decodedState) = decoded {
            #expect(decodedState.workspaces.count == 2)
            #expect(decodedState.workspaces[0].name == "Terminal")
            #expect(decodedState.workspaces[1].name == "Browser")
            #expect(decodedState.selectedWorkspaceID == nil)
        } else {
            Issue.record("Expected workspaceState case")
        }
    }

    @Test("WorkspaceState with selection round-trip")
    func workspaceStateWithSelectionRoundTrip() throws {
        let id = UUID()
        let state = WorkspaceState(
            workspaces: [WorkspaceSummary(id: id, name: "Selected")],
            selectedWorkspaceID: id
        )
        let message = SyncMessage.workspaceState(state)
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(SyncMessage.self, from: data)

        if case .workspaceState(let decodedState) = decoded {
            #expect(decodedState.selectedWorkspaceID == id)
            #expect(decodedState.workspaces[0].id == id)
        } else {
            Issue.record("Expected workspaceState case")
        }
    }

    @Test("SelectWorkspace round-trip")
    func selectWorkspaceRoundTrip() throws {
        let id = UUID()
        let message = SyncMessage.selectWorkspace(SelectWorkspace(workspaceID: id))
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(SyncMessage.self, from: data)

        if case .selectWorkspace(let sel) = decoded {
            #expect(sel.workspaceID == id)
        } else {
            Issue.record("Expected selectWorkspace case")
        }
    }

    @Test("Empty workspace list round-trip")
    func emptyWorkspaceListRoundTrip() throws {
        let state = WorkspaceState(workspaces: [], selectedWorkspaceID: nil)
        let message = SyncMessage.workspaceState(state)
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(SyncMessage.self, from: data)

        if case .workspaceState(let decodedState) = decoded {
            #expect(decodedState.workspaces.isEmpty)
        } else {
            Issue.record("Expected workspaceState case")
        }
    }

    @Test("WorkspaceSummary preserves UUID identity")
    func workspaceSummaryIdentity() throws {
        let id = UUID()
        let summary = WorkspaceSummary(id: id, name: "Test")
        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(WorkspaceSummary.self, from: data)
        #expect(decoded.id == id)
        #expect(decoded.name == "Test")
    }

    @Test("WorkspaceSummary preserves badgeCount")
    func workspaceSummaryBadgeCount() throws {
        let summary = WorkspaceSummary(id: UUID(), name: "Test", badgeCount: 3)
        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(WorkspaceSummary.self, from: data)
        #expect(decoded.badgeCount == 3)
    }

    @Test("WorkspaceSummary badgeCount defaults to zero")
    func workspaceSummaryBadgeCountDefault() throws {
        let summary = WorkspaceSummary(id: UUID(), name: "Test")
        #expect(summary.badgeCount == 0)
    }

    @Test("AudioControl round-trip")
    func audioControlRoundTrip() throws {
        for control in [AudioControl.start, AudioControl.stop] {
            let message = SyncMessage.audioControl(control)
            let data = try encoder.encode(message)
            let decoded = try decoder.decode(SyncMessage.self, from: data)

            if case .audioControl(let decodedControl) = decoded {
                #expect(decodedControl == control)
            } else {
                Issue.record("Expected audioControl case for \(control)")
            }
        }
    }

    @Test("AudioChunk round-trip")
    func audioChunkRoundTrip() throws {
        let pcmBytes = Data(repeating: 0x7F, count: 1024)
        let message = SyncMessage.audioChunk(pcmBytes)
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(SyncMessage.self, from: data)

        if case .audioChunk(let decodedData) = decoded {
            #expect(decodedData == pcmBytes)
            #expect(decodedData.count == 1024)
        } else {
            Issue.record("Expected audioChunk case")
        }
    }
}
