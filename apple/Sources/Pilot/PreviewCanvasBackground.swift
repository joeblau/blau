import SwiftUI

/// A quiet, Photoshop-style canvas that distinguishes the preview workspace
/// from true black pixels in a device or simulator screen.
struct PreviewCanvasBackground: View {
    private static let tileSize: CGFloat = 12
    private static let base = Color(
        .sRGB,
        red: 0.045,
        green: 0.045,
        blue: 0.050,
        opacity: 1
    )
    private static let alternate = Color(
        .sRGB,
        red: 0.064,
        green: 0.064,
        blue: 0.072,
        opacity: 1
    )

    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .color(Self.base))

            let columns = Int(ceil(size.width / Self.tileSize))
            let rows = Int(ceil(size.height / Self.tileSize))
            var alternateTiles = Path()

            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    alternateTiles.addRect(
                        CGRect(
                            x: CGFloat(column) * Self.tileSize,
                            y: CGFloat(row) * Self.tileSize,
                            width: Self.tileSize,
                            height: Self.tileSize
                        )
                    )
                }
            }

            context.fill(alternateTiles, with: .color(Self.alternate))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
