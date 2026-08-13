import SwiftUI

/// Liquid Glass shipped in macOS 26, and Pilot deploys back to macOS 15.
/// These wrappers keep the glass look where it exists and fall back to a
/// material fill in the same shape (plus a tint wash) on older systems.
extension View {
    @ViewBuilder
    func compatGlassEffect(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: some Shape
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint {
                        shape.fill(tint)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func compatGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// `GlassEffectContainer` only coordinates blending between neighboring glass
/// shapes, so the macOS 15 fallback is simply the content itself.
struct CompatGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
