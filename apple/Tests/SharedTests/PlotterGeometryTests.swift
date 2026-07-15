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

    func testDrawingTransformMapsPointsAcrossPortraitLandscapeAndSplitView() throws {
        let bounds = [
            CGRect(x: 0, y: 0, width: 834, height: 1_194),
            CGRect(x: 0, y: 0, width: 1_194, height: 834),
            CGRect(x: 0, y: 0, width: 507, height: 834),
        ]
        let contentRects = bounds.map {
            PlotterGeometry.aspectFitRect(contentSize: videoSize, in: $0)
        }
        let normalizedDrawing = [
            CGPoint(x: 0.05, y: 0.10),
            CGPoint(x: 0.50, y: 0.50),
            CGPoint(x: 0.92, y: 0.78),
        ]

        for index in contentRects.indices {
            let sourceRect = contentRects[index]
            let destinationRect = contentRects[(index + 1) % contentRects.count]
            let transform = try XCTUnwrap(PlotterGeometry.drawingTransform(
                from: sourceRect,
                to: destinationRect
            ))

            for normalizedPoint in normalizedDrawing {
                let sourcePoint = PlotterGeometry.point(
                    fromNormalized: normalizedPoint,
                    in: sourceRect
                )
                let expectedPoint = PlotterGeometry.point(
                    fromNormalized: normalizedPoint,
                    in: destinationRect
                )
                let mappedPoint = sourcePoint.applying(transform)
                XCTAssertEqual(mappedPoint.x, expectedPoint.x, accuracy: 0.000_001)
                XCTAssertEqual(mappedPoint.y, expectedPoint.y, accuracy: 0.000_001)
            }
        }
    }

    func testDrawingTransformRoundTripsBetweenEveryLayout() throws {
        let layouts = [
            CGRect(x: 0, y: 0, width: 834, height: 1_194),
            CGRect(x: 0, y: 0, width: 1_194, height: 834),
            CGRect(x: 0, y: 0, width: 507, height: 834),
        ].map {
            PlotterGeometry.aspectFitRect(contentSize: videoSize, in: $0)
        }
        let originalPoints = [
            CGPoint(x: layouts[0].minX, y: layouts[0].minY),
            CGPoint(x: layouts[0].midX, y: layouts[0].midY),
            CGPoint(x: layouts[0].maxX, y: layouts[0].maxY),
        ]

        for destinationRect in layouts.dropFirst() {
            let outward = try XCTUnwrap(PlotterGeometry.drawingTransform(
                from: layouts[0],
                to: destinationRect
            ))
            let inward = try XCTUnwrap(PlotterGeometry.drawingTransform(
                from: destinationRect,
                to: layouts[0]
            ))

            for originalPoint in originalPoints {
                let roundTrippedPoint = originalPoint.applying(outward).applying(inward)
                XCTAssertEqual(roundTrippedPoint.x, originalPoint.x, accuracy: 0.000_001)
                XCTAssertEqual(roundTrippedPoint.y, originalPoint.y, accuracy: 0.000_001)
            }
        }
    }

    func testDrawingTransformRejectsEmptyRects() {
        XCTAssertNil(PlotterGeometry.drawingTransform(
            from: .zero,
            to: CGRect(x: 0, y: 0, width: 100, height: 100)
        ))
        XCTAssertNil(PlotterGeometry.drawingTransform(
            from: CGRect(x: 0, y: 0, width: 100, height: 100),
            to: .zero
        ))
    }
}
