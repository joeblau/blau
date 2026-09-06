import Foundation
import Testing
@testable import Pilot

@Suite("Walkie transcript routing")
struct PilotWalkieInputTests {
    @Test("Dictated controls cannot submit or edit terminal input before hold-up")
    func transcriptControlsBecomeSpaces() {
        let transcript = "  Review  Café.swift\r\nrun\tunit\u{001B}tests\u{0000}now\u{0008}please\u{007F}✓\u{0085}done\u{2028}ok\u{2029}  "
        let text = PilotWalkieInputState.textForTerminal(transcript)

        #expect(text == "Review  Café.swift  run unit tests now please ✓ done ok")
        #expect(text.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil)
    }

    @Test("A transcript containing only whitespace and controls is empty")
    func controlsDoNotCreateTerminalInput() {
        #expect(PilotWalkieInputState.textForTerminal(" \r\n\t\u{0000}\u{0003}\u{001B}\u{2028} ").isEmpty)
    }

    @Test("Remote dictation and Enter stay with the original computer and session after focus changes")
    func remoteInputStaysWithCapturedSession() {
        var state = PilotWalkieInputState()
        let recordingID = UUID()
        let workspaceID = UUID()
        let target = PilotWalkieInputState.Target(
            workspaceID: workspaceID,
            destination: .remoteDesktop(connectionID: UUID(), sessionID: UUID())
        )
        state.begin(recordingID: recordingID, workspaceID: workspaceID, target: target)
        state.stop(recordingID: recordingID, workspaceID: workspaceID)

        let received = state.receiveTranscript(
            recordingID: recordingID,
            workspaceID: workspaceID,
            legacyFallback: .init(
                workspaceID: workspaceID,
                destination: .remoteDesktop(connectionID: UUID(), sessionID: UUID())
            )
        )
        #expect(received == target)
        #expect(received?.paneID == nil)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) == nil)
        state.didPasteTranscript(recordingID: recordingID)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) == target)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) == nil)
    }

    @Test("Duplicate recording starts cannot retarget a reconnected computer or a terminal")
    func remoteDuplicateStartKeepsOriginalSession() {
        var state = PilotWalkieInputState()
        let recordingID = UUID()
        let workspaceID = UUID()
        let connectionID = UUID()
        let target = PilotWalkieInputState.Target(
            workspaceID: workspaceID,
            destination: .remoteDesktop(connectionID: connectionID, sessionID: UUID())
        )
        state.begin(recordingID: recordingID, workspaceID: workspaceID, target: target)
        state.begin(
            recordingID: recordingID,
            workspaceID: workspaceID,
            target: .init(
                workspaceID: workspaceID,
                destination: .remoteDesktop(connectionID: connectionID, sessionID: UUID())
            )
        )

        // The delivery layer can now reject the disconnected original session;
        // retaining its ID prevents text from being typed into the new session.
        #expect(state.receiveTranscript(recordingID: recordingID, workspaceID: workspaceID) == target)
        state.didPasteTranscript(recordingID: recordingID)
        state.begin(recordingID: recordingID, workspaceID: workspaceID, paneID: UUID())
        #expect(!state.isRecording)
        #expect(state.receiveTranscript(recordingID: recordingID, workspaceID: workspaceID) == nil)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) == target)
    }

    @Test("Missing remote input cannot fall back to another connected computer")
    func missingRemoteTargetNeverFallsBack() {
        var state = PilotWalkieInputState()
        let recordingID = UUID()
        state.begin(recordingID: recordingID, workspaceID: nil, target: nil)

        #expect(state.receiveTranscript(
            recordingID: recordingID,
            workspaceID: nil,
            legacyFallback: .init(
                workspaceID: nil,
                destination: .remoteDesktop(connectionID: UUID(), sessionID: UUID())
            )
        ) == nil)
        #expect(!state.isRecording)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: nil) == nil)
    }

    @Test("Remote targets reject transcript and Enter commands for another workspace")
    func remoteWorkspaceMismatchIsRejected() {
        var state = PilotWalkieInputState()
        let recordingID = UUID()
        let workspaceID = UUID()
        let otherWorkspaceID = UUID()
        let target = PilotWalkieInputState.Target(
            workspaceID: workspaceID,
            destination: .remoteDesktop(connectionID: UUID(), sessionID: UUID())
        )
        state.begin(recordingID: recordingID, workspaceID: workspaceID, target: target)
        state.stop(recordingID: recordingID, workspaceID: otherWorkspaceID)
        #expect(state.isRecording)
        #expect(state.receiveTranscript(recordingID: recordingID, workspaceID: otherWorkspaceID) == nil)
        #expect(state.receiveTranscript(recordingID: recordingID, workspaceID: workspaceID) == target)
        state.didPasteTranscript(recordingID: recordingID)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: otherWorkspaceID) == nil)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) == target)
    }

    @Test("Enter uses the terminal that received the utterance and executes only once")
    func executionStaysWithPastedTranscript() {
        var state = PilotWalkieInputState()
        let recordingID = UUID()
        let workspaceID = UUID()
        let paneID = UUID()
        let target = PilotWalkieInputState.Target(workspaceID: workspaceID, paneID: paneID)
        state.begin(recordingID: recordingID, workspaceID: workspaceID, paneID: paneID)
        state.stop(recordingID: recordingID, workspaceID: workspaceID)

        // Current focus can now be a different window/pane. Its fallback must
        // never affect either the paste or its corresponding Enter.
        #expect(state.receiveTranscript(
            recordingID: recordingID,
            workspaceID: workspaceID,
            legacyFallback: .init(workspaceID: UUID(), paneID: UUID())
        ) == target)
        state.didPasteTranscript(recordingID: recordingID)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) == target)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) == nil)
    }

    @Test("Enter cannot execute before text has actually been pasted")
    func executionRequiresSuccessfulPaste() {
        var state = PilotWalkieInputState()
        let recordingID = UUID()
        let workspaceID = UUID()
        state.begin(recordingID: recordingID, workspaceID: workspaceID, paneID: UUID())
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) == nil)
        #expect(state.receiveTranscript(recordingID: recordingID, workspaceID: workspaceID) != nil)
        // A missing/closed terminal or empty transcript never confirms delivery.
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) == nil)
        state.didPasteTranscript(recordingID: recordingID)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) != nil)
    }

    @Test("Late recordings and stop messages cannot overwrite a newer recording's target")
    func interleavedRecordingsKeepTheirOwnTargets() {
        var state = PilotWalkieInputState()
        let firstID = UUID()
        let secondID = UUID()
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()
        let firstPane = UUID()
        let secondPane = UUID()
        state.begin(recordingID: firstID, workspaceID: firstWorkspace, paneID: firstPane)
        state.begin(recordingID: secondID, workspaceID: secondWorkspace, paneID: secondPane)
        state.stop(recordingID: firstID, workspaceID: firstWorkspace)
        #expect(state.isRecording)
        #expect(state.receiveTranscript(recordingID: firstID, workspaceID: firstWorkspace)?.paneID == firstPane)
        #expect(state.isRecording)
        #expect(state.receiveTranscript(recordingID: secondID, workspaceID: secondWorkspace)?.paneID == secondPane)
        #expect(!state.isRecording)
    }

    @Test("Duplicate starts and transcripts do not recapture focus or paste twice")
    func duplicateMessagesAreIgnored() {
        var state = PilotWalkieInputState()
        let recordingID = UUID()
        let workspaceID = UUID()
        let paneID = UUID()
        state.begin(recordingID: recordingID, workspaceID: workspaceID, paneID: paneID)
        state.begin(recordingID: recordingID, workspaceID: workspaceID, paneID: UUID())
        #expect(state.receiveTranscript(recordingID: recordingID, workspaceID: workspaceID)?.paneID == paneID)
        state.didPasteTranscript(recordingID: recordingID)
        #expect(state.receiveTranscript(recordingID: recordingID, workspaceID: workspaceID) == nil)
        state.begin(recordingID: recordingID, workspaceID: workspaceID, paneID: UUID())
        #expect(!state.isRecording)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID)?.paneID == paneID)
    }

    @Test("Unknown recordings and mismatched workspaces cannot redirect text or Enter")
    func unrelatedMessagesAreRejected() {
        var state = PilotWalkieInputState()
        let recordingID = UUID()
        let workspaceID = UUID()
        let otherWorkspace = UUID()
        state.begin(recordingID: recordingID, workspaceID: workspaceID, paneID: UUID())
        let fallback = PilotWalkieInputState.Target(workspaceID: otherWorkspace, paneID: UUID())
        #expect(state.receiveTranscript(recordingID: UUID(), workspaceID: workspaceID, legacyFallback: fallback) == nil)
        #expect(state.receiveTranscript(recordingID: recordingID, workspaceID: otherWorkspace, legacyFallback: fallback) == nil)
        state.stop(recordingID: recordingID, workspaceID: otherWorkspace)
        #expect(state.isRecording)
        #expect(state.receiveTranscript(recordingID: recordingID, workspaceID: workspaceID) != nil)
        state.didPasteTranscript(recordingID: recordingID)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: otherWorkspace) == nil)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) != nil)
    }

    @Test("Recording without a terminal cannot fall back to a newly focused window")
    func unavailableTargetNeverFallsBack() {
        var state = PilotWalkieInputState()
        let recordingID = UUID()
        let workspaceID = UUID()
        state.begin(recordingID: recordingID, workspaceID: workspaceID, paneID: nil)
        #expect(state.receiveTranscript(
            recordingID: recordingID,
            workspaceID: workspaceID,
            legacyFallback: .init(workspaceID: workspaceID, paneID: UUID())
        ) == nil)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) == nil)
        #expect(!state.isRecording)
    }

    @Test("Disconnect clears listening and prevents execution from the old peer session")
    func disconnectInvalidatesRecordings() {
        var state = PilotWalkieInputState()
        let recordingID = UUID()
        let workspaceID = UUID()
        state.begin(recordingID: recordingID, workspaceID: workspaceID, paneID: UUID())
        #expect(state.receiveTranscript(recordingID: recordingID, workspaceID: workspaceID) != nil)
        state.didPasteTranscript(recordingID: recordingID)
        state.begin(recordingID: UUID(), workspaceID: workspaceID, paneID: UUID())
        #expect(state.isRecording)
        state.reset()
        #expect(!state.isRecording)
        #expect(state.receiveTranscript(recordingID: recordingID, workspaceID: workspaceID) == nil)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: workspaceID) == nil)
    }

    @Test("A recording with implicit workspace still accepts its correlated transcript")
    func implicitWorkspaceUsesCapturedTarget() {
        var state = PilotWalkieInputState()
        let recordingID = UUID()
        let workspaceID = UUID()
        let paneID = UUID()
        state.begin(recordingID: recordingID, workspaceID: workspaceID, paneID: paneID)
        #expect(state.receiveTranscript(recordingID: recordingID, workspaceID: nil)?.paneID == paneID)
        state.didPasteTranscript(recordingID: recordingID)
        #expect(state.takeExecutionTarget(recordingID: recordingID, workspaceID: nil)?.paneID == paneID)
    }

    @Test("Legacy transcripts honor their captured workspace and preserve older peer support")
    func legacyRouting() {
        var state = PilotWalkieInputState()
        let workspaceID = UUID()
        let paneID = UUID()
        let fallback = PilotWalkieInputState.Target(workspaceID: workspaceID, paneID: UUID())
        state.begin(recordingID: nil, workspaceID: workspaceID, paneID: paneID)
        #expect(state.receiveTranscript(recordingID: nil, workspaceID: UUID(), legacyFallback: fallback) == nil)
        #expect(state.isRecording)
        #expect(state.receiveTranscript(recordingID: nil, workspaceID: workspaceID, legacyFallback: fallback)?.paneID == paneID)
        #expect(!state.isRecording)
        #expect(state.receiveTranscript(recordingID: nil, workspaceID: workspaceID, legacyFallback: fallback) == fallback)
    }
}
