import SwiftUI

/// Fixed model-to-color mapping shared by the chart color scale, legend,
/// hero list, and breakdown table.
///
/// Each provider owns one hue family — Claude orange, Codex blue, Grok
/// purple, Kimi green — and every model inside a family gets its own shade
/// of that hue, iPhone-storage-bar style: the flagship model takes the
/// deepest, most saturated step and successive models step lighter. Color
/// follows the canonical model id — never chart order — so a model keeps its
/// shade when the range filter changes which series are visible. Gray is
/// reserved for unknown models and always travels with the "unpriced" badge,
/// never color alone.
enum AgenticUseModelPalette {
    static func color(for canonicalModel: String) -> Color {
        guard let provider = provider(for: canonicalModel) else { return .gray }
        let family = familyOrder(for: provider)
        guard let index = family.firstIndex(of: canonicalModel) else { return .gray }
        return shade(hue: hue(for: provider), step: index, of: family.count)
    }

    /// Which provider's hue family a canonical model id belongs to.
    static func provider(for canonicalModel: String) -> AgenticProvider? {
        if canonicalModel.hasPrefix("claude-") { return .claude }
        if canonicalModel.hasPrefix("gpt-") { return .codex }
        if canonicalModel.hasPrefix("grok") { return .grok }
        if kimiModels.contains(canonicalModel) || canonicalModel.contains("kimi") { return .kimi }
        return nil
    }

    // MARK: - Families

    private static let kimiModels: Set<String> = [
        "k3", "k3-256k", "k3-max", "moonshot-ai/kimi-k3", "kimi-for-coding",
    ]

    /// The provider's models in `AgenticModel.presentationOrder` — flagship
    /// first, so shade steps track prominence.
    private static func familyOrder(for provider: AgenticProvider) -> [String] {
        AgenticModel.presentationOrder.filter { Self.provider(for: $0) == provider }
    }

    /// Base hue (degrees) per provider.
    private static func hue(for provider: AgenticProvider) -> Double {
        switch provider {
        case .claude: 27
        case .codex: 214
        case .grok: 275
        case .kimi: 138
        }
    }

    /// One step of a family's shade ramp: the first model is deep and
    /// saturated, later models get progressively lighter and softer. The
    /// ramp spans the same perceptual distance regardless of family size so
    /// two-model families still contrast.
    private static func shade(hue degrees: Double, step: Int, of count: Int) -> Color {
        let fraction = count > 1 ? Double(step) / Double(count - 1) : 0
        let saturation = 0.92 - 0.50 * fraction
        let brightness = 0.82 + 0.16 * fraction
        return Color(hue: degrees / 360, saturation: saturation, brightness: brightness)
    }
}
