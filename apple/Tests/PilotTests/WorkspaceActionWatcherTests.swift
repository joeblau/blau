import Foundation
import Testing
@testable import Pilot

@Suite("GitHub Actions completion tracking")
struct WorkspaceActionWatcherTests {
    @Test("A failed first fetch does not create an empty baseline")
    func firstFailureThenRecovery() {
        var tracker = ActionCompletionTracker()
        #expect(tracker.ingest(.failure(.invalidJSON), isSelected: false) == 0)
        #expect(!tracker.hasBaseline)
        #expect(tracker.ingest(.success([10, 11]), isSelected: false) == 0)
        #expect(tracker.hasBaseline)
        #expect(tracker.seenCompleted == [10, 11])
    }

    @Test("Transient failures preserve the last successful snapshot")
    func transientFailureAfterBaseline() {
        var tracker = ActionCompletionTracker()
        #expect(tracker.ingest(.success([10]), isSelected: false) == 0)
        #expect(tracker.ingest(.failure(.invalidJSON), isSelected: false) == 0)
        #expect(tracker.seenCompleted == [10])
        #expect(tracker.ingest(.success([10, 11]), isSelected: false) == 1)
    }

    @Test("Selected-workspace completions are recorded but never badge later")
    func selectedWorkspaceDoesNotDeferBadge() {
        var tracker = ActionCompletionTracker()
        #expect(tracker.ingest(.success([1]), isSelected: false) == 0)
        #expect(tracker.ingest(.success([1, 2]), isSelected: true) == 0)
        #expect(tracker.ingest(.success([1, 2]), isSelected: false) == 0)
    }
}
