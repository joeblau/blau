import Foundation

/// Number formatting for the Agentic Use dashboard. Every figure the section
/// renders goes through one of these helpers so the hero total, chart axes,
/// stat row, and breakdown table always agree with each other.
enum AgenticUseFormat {
    /// Full-precision money: "$1,616.86".
    static func cost(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// Compact axis money: "$50", "$1.2K".
    static func axisCost(_ value: Double) -> String {
        value.formatted(
            .currency(code: "USD")
                .notation(.compactName)
                .precision(.fractionLength(0...1))
        )
    }

    /// Abbreviated token counts: "2.58B", "106M", "8.10M"; small values
    /// render plain ("512"). Three significant digits produce the trailing
    /// zero in "8.10M" — do not switch to fraction-length precision.
    static func tokens(_ value: Int) -> String {
        tokens(Double(value))
    }

    static func tokens(_ value: Double) -> String {
        guard abs(value) >= 1000 else {
            return value.formatted(.number.precision(.fractionLength(0)))
        }
        return value.formatted(
            .number.notation(.compactName).precision(.significantDigits(3))
        )
    }

    /// "94.1%" from a 0...1 fraction.
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    /// "6.2x" from a ratio.
    static func multiple(_ ratio: Double) -> String {
        ratio.formatted(.number.precision(.fractionLength(1))) + "x"
    }
}
