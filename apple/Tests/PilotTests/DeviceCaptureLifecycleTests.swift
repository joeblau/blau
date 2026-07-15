import CoreGraphics
import Foundation
import XCTest
@testable import Pilot

final class DeviceCaptureLifecycleTests: XCTestCase {
    func testScreenshotTimesOutWithRecoverableError() async {
        let coordinator = CaptureCoordinator()
        do {
            _ = try await coordinator.nextFrame(timeout: 0.02)
            XCTFail("expected timeout")
        } catch let error as CaptureFrameError {
            XCTAssertEqual(error, .timedOut)
            XCTAssertTrue(error.localizedDescription.contains("retry"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTaskCancellationResolvesPendingScreenshot() async {
        let coordinator = CaptureCoordinator()
        let request = Task { try await coordinator.nextFrame(timeout: 5) }
        try? await Task.sleep(for: .milliseconds(20))
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("expected cancellation")
        } catch let error as CaptureFrameError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDetachResolvesEveryConcurrentScreenshotWithoutOverlapLoss() async {
        let coordinator = CaptureCoordinator()
        let first = Task { try await coordinator.nextFrame(timeout: 5) }
        let second = Task { try await coordinator.nextFrame(timeout: 5) }
        try? await Task.sleep(for: .milliseconds(20))
        coordinator.cancelPendingFrames(reason: .detached)

        for request in [first, second] {
            do {
                _ = try await request.value
                XCTFail("expected detach failure")
            } catch let error as CaptureFrameError {
                XCTAssertEqual(error, .detached)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSessionStopAndCoordinatorShutdownResolvePendingScreenshots() async {
        let stoppedCoordinator = CaptureCoordinator()
        let stopped = Task { try await stoppedCoordinator.nextFrame(timeout: 5) }
        try? await Task.sleep(for: .milliseconds(20))
        stoppedCoordinator.cancelPendingFrames(reason: .sessionStopped)
        await assertFrameError(.sessionStopped, from: stopped)

        let closedCoordinator = CaptureCoordinator()
        let closed = Task { try await closedCoordinator.nextFrame(timeout: 5) }
        try? await Task.sleep(for: .milliseconds(20))
        closedCoordinator.shutdown()
        await assertFrameError(.coordinatorReleased, from: closed)
    }

    func testStoppingBeforeFirstFrameAlwaysFinishesRecordingState() async {
        let coordinator = CaptureCoordinator()
        let callback = expectation(description: "recording finish callback")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blau-no-frame-\(UUID().uuidString).mov")
        coordinator.onFinish = { finishedURL, error in
            XCTAssertEqual(finishedURL, url)
            XCTAssertTrue(error?.contains("before the first video frame") == true)
            callback.fulfill()
        }
        XCTAssertTrue(coordinator.startRecording(to: url))
        XCTAssertFalse(coordinator.startRecording(to: url), "overlapping recording starts must be explicit")
        coordinator.stopRecording()
        await fulfillment(of: [callback], timeout: 1)
    }

    @MainActor
    func testScreenshotNamesDoNotCollideAndWritesAreCreateOnly() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let identifiers = [
            UUID(uuidString: "01234567-0000-0000-0000-000000000000")!,
            UUID(uuidString: "01234567-1111-1111-1111-111111111111")!
        ]
        let urls = identifiers.map { uniqueID in
            DeviceCaptureSession.timestampedURL(
                folder: "Desktop",
                name: "iPhone Screenshot",
                ext: "png",
                date: date,
                uniqueID: uniqueID
            )
        }
        XCTAssertEqual(Set(urls).count, urls.count)
        XCTAssertTrue(urls[0].lastPathComponent.contains(identifiers[0].uuidString.lowercased()))
        XCTAssertTrue(urls[1].lastPathComponent.contains(identifiers[1].uuidString.lowercased()))

        let atomic = FileManager.default.temporaryDirectory
            .appendingPathComponent("blau-atomic-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: atomic) }
        try Data([1]).write(to: atomic, options: .withoutOverwriting)
        XCTAssertThrowsError(try Data([2]).write(to: atomic, options: .withoutOverwriting))
    }

    private func assertFrameError(
        _ expected: CaptureFrameError,
        from request: Task<CGImage, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await request.value
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CaptureFrameError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}
