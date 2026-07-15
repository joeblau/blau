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

        for orientation in [
            UIDeviceOrientation.portrait,
            .landscapeLeft,
            .portraitUpsideDown,
            .landscapeRight,
        ] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 2))
        }
    }
}
