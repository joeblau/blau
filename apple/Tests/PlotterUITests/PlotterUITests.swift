import XCTest

/// fastlane snapshot UI tests for Plotter (iPad).
///
/// Runs against demo mode (`-demoMode YES`), which short-circuits the live
/// HEVC mirror / PencilKit capture and renders a representative fixture frame
/// so the screen isn't stuck on "Searching for Pilot…". See the Foundation
/// harness / DEMO-MODE convention.
@MainActor
final class PlotterUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSnapshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["-demoMode", "YES"]
        app.launch()

        // Primary screen: the live mirror with the annotation overlay.
        snapshot("01-Mirror")
    }

    func testMirrorRemainsUsableAcrossRotation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-demoMode", "YES"]
        app.launch()

        let canvas = app.descendants(matching: .any)["AnnotationCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 2))
        let expectedDrawingState = "2 annotation strokes"

        for orientation in [
            UIDeviceOrientation.portrait,
            .landscapeLeft,
            .portraitUpsideDown,
            .landscapeRight,
        ] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 2))
            let expectedPortraitLayout = orientation == .portrait || orientation == .portraitUpsideDown
            let layoutPredicate = NSPredicate { evaluatedObject, _ in
                guard let element = evaluatedObject as? XCUIElement else { return false }
                let frame = element.frame
                let hasExpectedLayout = expectedPortraitLayout
                    ? frame.height > frame.width
                    : frame.width > frame.height
                return hasExpectedLayout && element.value as? String == expectedDrawingState
            }
            expectation(for: layoutPredicate, evaluatedWith: canvas)
            waitForExpectations(timeout: 3)
        }
    }
}
