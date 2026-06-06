import AppKit
import Testing
@testable import Pilot

@Suite("Color chip parsing")
struct ColorChipTests {

    /// Rounded 0–255 sRGB components + alpha, for stable comparisons.
    private func rgba(_ color: NSColor) -> (r: Int, g: Int, b: Int, a: Double) {
        let s = color.usingColorSpace(.sRGB)!
        return (Int((s.redComponent * 255).rounded()),
                Int((s.greenComponent * 255).rounded()),
                Int((s.blueComponent * 255).rounded()),
                (s.alphaComponent * 100).rounded() / 100)
    }

    @Test("The four documented formats all resolve to the same green")
    func documentedFormatsAgree() throws {
        // #00FF3F == rgb(0,255,63) == oklch(86.8% 0.279 144.3) == cmyk(100% 0% 75% 0%)
        for input in ["#00FF3F", "rgb(0, 255, 63)", "oklch(86.8% 0.279 144.3)", "cmyk(100%, 0%, 75%, 0%)"] {
            let c = try #require(ColorChip.parse(input), "should parse \(input)")
            let (r, g, b, a) = rgba(c)
            // OKLCH/CMYK round-trips land within 1/255 of the target green.
            #expect(abs(r - 0) <= 1, "\(input) red")
            #expect(abs(g - 255) <= 1, "\(input) green")
            #expect(abs(b - 63) <= 2, "\(input) blue")
            #expect(a == 1, "\(input) alpha")
        }
    }

    @Test("Hex shorthand and alpha")
    func hexVariants() throws {
        #expect(rgba(try #require(ColorChip.parse("#0F3"))) == (0, 255, 51, 1))      // #0F3 -> #00FF33
        #expect(rgba(try #require(ColorChip.parse("#00FF3F80"))).a == 0.5)            // 8-digit alpha
        #expect(rgba(try #require(ColorChip.parse("#FFFFFF"))) == (255, 255, 255, 1))
    }

    @Test("rgb percentages and rgba alpha")
    func rgbVariants() throws {
        #expect(rgba(try #require(ColorChip.parse("rgb(100%, 0%, 0%)"))) == (255, 0, 0, 1))
        #expect(rgba(try #require(ColorChip.parse("rgba(0,255,63,0.5)"))).a == 0.5)
    }

    @Test("oklch accepts L as 0–1 or a percentage")
    func oklchLightnessForms() throws {
        let pct = rgba(try #require(ColorChip.parse("oklch(86.8% 0.279 144.3)")))
        let unit = rgba(try #require(ColorChip.parse("oklch(0.868 0.279 144.3)")))
        #expect(pct == unit)
    }

    @Test("Out-of-range channels clamp into gamut")
    func clamping() throws {
        #expect(rgba(try #require(ColorChip.parse("rgb(300, -5, 999)"))) == (255, 0, 255, 1))
    }

    @Test("Non-colors and partial-content spans are rejected")
    func rejectsNonColors() {
        for input in ["not a color", "color: #00FF3F", "#zzz", "#12", "rgb(1,2)", "", "   ", "hello world"] {
            #expect(ColorChip.parse(input) == nil, "should reject \(input)")
        }
    }

    @Test("matches() finds only inline-code spans whose whole content is a color")
    func matchesScansInlineCode() {
        let body = """
        brand: `#00FF3F`
        plain text, no code
        accent `rgb(0, 255, 63)` here
        not a color: `let x = 1`
        bad hex: `#zzz`
        bare #00FF3F is not in code
        """
        let found = ColorChip.matches(in: body)
        #expect(found.count == 2)
        #expect(found.map(\.value) == ["#00FF3F", "rgb(0, 255, 63)"])
    }
}
