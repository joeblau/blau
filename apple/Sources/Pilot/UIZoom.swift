import SwiftUI

// UIZoom — single source of truth for IDE-wide text scaling.
//
// Driven by ⌘+ / ⌘- / ⌘0 in the View menu. Stepped through a fixed
// ladder so zoom-in / zoom-out feel snappy instead of drifting on
// arbitrary 5%-ish increments. Propagated through the SwiftUI
// environment so chrome (.scaledFont), the WebKit `pageZoom`, and
// `GhosttyRuntime.userZoomFactor` all read from one number.

private struct UIZoomKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var uiZoom: Double {
        get { self[UIZoomKey.self] }
        set { self[UIZoomKey.self] = newValue }
    }
}

enum UIZoomLadder {
    static let steps: [Double] = [0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]
    static let `default`: Double = 1.0

    static func next(after current: Double) -> Double {
        guard let index = nearestIndex(to: current) else { return `default` }
        return steps[min(index + 1, steps.count - 1)]
    }

    static func previous(before current: Double) -> Double {
        guard let index = nearestIndex(to: current) else { return `default` }
        return steps[max(index - 1, 0)]
    }

    private static func nearestIndex(to value: Double) -> Int? {
        guard !steps.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = abs(steps[0] - value)
        for (i, step) in steps.enumerated().dropFirst() {
            let distance = abs(step - value)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = i
            }
        }
        return bestIndex
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.uiZoom) private var uiZoom

    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: baseSize * uiZoom, weight: weight, design: design))
    }
}

extension View {
    /// Apply a font that scales with the IDE's `uiZoom` environment.
    /// Use anywhere you'd otherwise write `.font(.system(size: N, …))`.
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(ScaledFontModifier(baseSize: size, weight: weight, design: design))
    }
}
