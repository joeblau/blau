import CoreGraphics
import XCTest

final class PlotterGeometryTests: XCTestCase {
    private let videoSize = CGSize(width: 1_600, height: 1_000)

    func testAspectFitRespondsToPortraitLandscapeAndSplitView() {
        let portrait = PlotterGeometry.aspectFitRect(
            contentSize: videoSize,
            in: CGRect(x: 0, y: 0, width: 834, height: 1_194)
        )
        XCTAssertEqual(portrait.width, 834, accuracy: 0.001)
        XCTAssertEqual(portrait.height, 521.25, accuracy: 0.001)
        XCTAssertEqual(portrait.midY, 597, accuracy: 0.001)

        let landscape = PlotterGeometry.aspectFitRect(
            contentSize: videoSize,
            in: CGRect(x: 0, y: 0, width: 1_194, height: 834)
        )
        XCTAssertEqual(landscape.width, 1_194, accuracy: 0.001)
        XCTAssertEqual(landscape.height, 746.25, accuracy: 0.001)

        let splitView = PlotterGeometry.aspectFitRect(
            contentSize: videoSize,
            in: CGRect(x: 0, y: 0, width: 507, height: 834)
        )
        XCTAssertEqual(splitView.width, 507, accuracy: 0.001)
        XCTAssertEqual(splitView.height, 316.875, accuracy: 0.001)
    }

    func testNormalizedAnnotationPositionSurvivesEveryLayout() throws {
        let normalized = CGPoint(x: 0.72, y: 0.31)
        let bounds = [
            CGRect(x: 0, y: 0, width: 834, height: 1_194),
            CGRect(x: 0, y: 0, width: 1_194, height: 834),
            CGRect(x: 0, y: 0, width: 507, height: 834),
        ]

        for bounds in bounds {
            let contentRect = PlotterGeometry.aspectFitRect(contentSize: videoSize, in: bounds)
            let canvasPoint = PlotterGeometry.point(fromNormalized: normalized, in: contentRect)
            let roundtrip = try XCTUnwrap(PlotterGeometry.normalizedPoint(canvasPoint, in: contentRect))
            XCTAssertEqual(roundtrip.x, normalized.x, accuracy: 0.000_001)
            XCTAssertEqual(roundtrip.y, normalized.y, accuracy: 0.000_001)
        }
    }

    func testLetterboxPointsDoNotBecomeAnnotations() {
        let bounds = CGRect(x: 0, y: 0, width: 834, height: 1_194)
        let contentRect = PlotterGeometry.aspectFitRect(contentSize: videoSize, in: bounds)
        XCTAssertNil(PlotterGeometry.normalizedPoint(CGPoint(x: bounds.midX, y: 20), in: contentRect))
    }
}
