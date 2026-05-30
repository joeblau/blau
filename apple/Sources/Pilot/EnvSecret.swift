import AppKit

/// Recognizes `.env`-style assignments in a note — `KEY="value"`,
/// `export KEY=value`, etc. — so their values can be masked in the editor and
/// copied on click. Keys are required to be uppercase (the env convention) so
/// ordinary prose like `a = b` isn't mistaken for a secret.
enum EnvSecret {
    private static let line = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:export[ \t]+)?([A-Z_][A-Z0-9_]*)[ \t]*=[ \t]*(\S.*?)[ \t]*$"#,
        options: .anchorsMatchLines
    )

    struct Match {
        let keyRange: NSRange
        /// The secret content range — inside the quotes when the value is quoted.
        let valueRange: NSRange
        /// The string to place on the pasteboard.
        let value: String
    }

    static func matches(in string: String) -> [Match] {
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result: [Match] = []

        line.enumerateMatches(in: string, range: full) { match, _, _ in
            guard let match else { return }
            let keyRange = match.range(at: 1)
            var valueRange = match.range(at: 2)
            guard valueRange.location != NSNotFound, valueRange.length > 0 else { return }

            // Strip a matching pair of surrounding quotes from what we mask/copy.
            let raw = ns.substring(with: valueRange)
            if raw.count >= 2, let first = raw.first, let last = raw.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                valueRange = NSRange(location: valueRange.location + 1, length: valueRange.length - 2)
            }
            guard valueRange.length > 0 else { return }

            result.append(Match(keyRange: keyRange,
                                valueRange: valueRange,
                                value: ns.substring(with: valueRange)))
        }
        return result
    }
}

/// Masks `.env` secret values in an `NSTextView` by substituting bullet glyphs
/// at the layout-manager level — the real characters stay in the text storage
/// (so the note still persists as plain text), only the rendered glyphs change.
/// The value on the line currently holding the caret is left unmasked so it can
/// be edited.
final class EnvMaskController: NSObject, NSLayoutManagerDelegate {
    weak var textView: MultiCursorTextView?
    private(set) var maskedRanges: [NSRange] = []

    /// Recompute which secret values should be masked and re-lay-out if that
    /// set changed. Cheap no-op when nothing moved.
    func refresh() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let string = textView.string

        let activeLine: NSRange? = {
            guard textView.selectedRanges.count == 1 else { return nil }
            return (string as NSString).lineRange(for: textView.selectedRange())
        }()

        let newMasked = EnvSecret.matches(in: string)
            .map(\.valueRange)
            .filter { range in
                guard let activeLine else { return true }
                return NSIntersectionRange(activeLine, range).length == 0
            }

        guard newMasked != maskedRanges else { return }
        maskedRanges = newMasked

        let full = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        textView.needsDisplay = true
        textView.updateSecretAffordances()
    }

    private func isMasked(_ charIndex: Int) -> Bool {
        maskedRanges.contains { NSLocationInRange(charIndex, $0) }
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !maskedRanges.isEmpty else { return 0 }

        let count = glyphRange.length
        var anyMasked = false
        for i in 0..<count where isMasked(charIndexes[i]) { anyMasked = true; break }
        guard anyMasked else { return 0 }

        let bullet = Self.glyph(for: "•", font: font)
        let substituted = UnsafeMutablePointer<CGGlyph>.allocate(capacity: count)
        defer { substituted.deallocate() }
        for i in 0..<count {
            substituted[i] = isMasked(charIndexes[i]) ? bullet : glyphs[i]
        }
        layoutManager.setGlyphs(substituted, properties: props, characterIndexes: charIndexes,
                                font: font, forGlyphRange: glyphRange)
        return count
    }

    private static func glyph(for character: Character, font: NSFont) -> CGGlyph {
        var chars = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyphs, chars.count)
        return glyphs.first ?? 0
    }
}
