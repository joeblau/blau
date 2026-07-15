import CoreGraphics

/// Pure geometry shared by Plotter's mirror and its rotation/size-class tests.
/// Annotation messages use normalized coordinates so they remain stable when
/// the iPad rotates or enters Stage Manager and the aspect-fit rect changes.
enum PlotterGeometry {
    static func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0,
              contentSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let width = contentSize.width * scale
        let height = contentSize.height * scale
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func normalizedPoint(_ point: CGPoint, in contentRect: CGRect) -> CGPoint? {
        guard contentRect.width > 0,
              contentRect.height > 0,
              contentRect.contains(point) else {
            return nil
        }
        return CGPoint(
            x: min(1, max(0, (point.x - contentRect.minX) / contentRect.width)),
            y: min(1, max(0, (point.y - contentRect.minY) / contentRect.height))
        )
    }

    static func point(fromNormalized normalized: CGPoint, in contentRect: CGRect) -> CGPoint {
        CGPoint(
            x: contentRect.minX + normalized.x * contentRect.width,
            y: contentRect.minY + normalized.y * contentRect.height
        )
    }
}
