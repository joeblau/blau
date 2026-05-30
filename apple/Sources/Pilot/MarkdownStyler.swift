import AppKit

/// Live GitHub-Flavored-Markdown styling for an `NSTextView`. The raw
/// markdown stays in the text storage (and is what we persist) — this only
/// layers visual attributes on top, in place, so `# Hello` renders at H1
/// size, `**bold**` goes bold, etc., all in a single editable view.
///
/// Hooked in as the text storage's delegate: every character edit triggers a
/// full re-style of the (note-sized) document. Because we only ever change
/// *attributes*, the follow-up edit pass carries `.editedAttributes` rather
/// than `.editedCharacters`, so re-styling never recurses.
final class MarkdownStyler: NSObject, NSTextStorageDelegate {
    var baseSize: CGFloat
    private var isStyling = false

    init(baseSize: CGFloat) {
        self.baseSize = baseSize
    }

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isStyling else { return }
        isStyling = true
        style(textStorage)
        isStyling = false
    }

    func style(_ storage: NSTextStorage) {
        let string = storage.string
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return }

        // Clean slate: body font + label color across the whole document,
        // dropping any background/underline/strikethrough from the last pass.
        storage.setAttributes(
            [.font: NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular),
             .foregroundColor: NSColor.labelColor],
            range: full
        )

        // Code regions are recorded so inline/heading rules don't fire inside
        // them (e.g. a `#` in a fenced block is not a heading).
        var protectedRanges: [NSRange] = []
        func isProtected(_ range: NSRange) -> Bool {
            protectedRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        func eachMatch(_ regex: NSRegularExpression, _ handle: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: string, range: full) { match, _, _ in
                if let match { handle(match) }
            }
        }

        let codeFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)

        // --- Code (claim ranges first) ---------------------------------------
        eachMatch(Self.fencedCode) { match in
            storage.addAttributes([.font: codeFont, .backgroundColor: Self.codeBackground], range: match.range)
            protectedRanges.append(match.range)
        }
        eachMatch(Self.inlineCode) { match in
            guard !isProtected(match.range) else { return }
            storage.addAttributes([.font: codeFont, .backgroundColor: Self.codeBackground], range: match.range)
            dim(storage, NSRange(location: match.range.location, length: 1))
            dim(storage, NSRange(location: NSMaxRange(match.range) - 1, length: 1))
            protectedRanges.append(match.range)
        }

        // --- Env-style secrets (KEY="value") ---------------------------------
        // Tint the key and give the value a pill background; protect the value
        // so inline markdown (e.g. `*` in a secret) doesn't restyle it. The
        // bullet masking itself is handled by EnvMaskController at layout time.
        for secret in EnvSecret.matches(in: string) {
            guard !isProtected(secret.valueRange), !isProtected(secret.keyRange) else { continue }
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: secret.keyRange)
            storage.addAttribute(.backgroundColor, value: Self.secretBackground, range: secret.valueRange)
            protectedRanges.append(secret.valueRange)
        }

        // --- Block level ------------------------------------------------------
        eachMatch(Self.heading) { match in
            guard !isProtected(match.range) else { return }
            let level = match.range(at: 1).length
            addAttribute(.font, value: headingFont(level: level), over: match.range, in: storage)
            // Dim the leading "#"s and the space(s) before the content.
            let contentStart = match.range(at: 2).location
            dim(storage, NSRange(location: match.range.location, length: contentStart - match.range.location))
        }
        eachMatch(Self.blockquote) { match in
            guard !isProtected(match.range) else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
        }
        eachMatch(Self.listMarker) { match in
            guard !isProtected(match.range) else { return }
            let marker = match.range(at: 2)
            if marker.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: marker)
            }
        }
        eachMatch(Self.taskMarker) { match in
            guard !isProtected(match.range) else { return }
            let box = match.range(at: 1)
            if box.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: box)
            }
        }
        // Completed tasks ([x]) get a subtle strikethrough + dimmed text.
        eachMatch(Self.completedTask) { match in
            guard !isProtected(match.range) else { return }
            let content = match.range(at: 1)
            guard content.location != NSNotFound, content.length > 0 else { return }
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: NSColor.tertiaryLabelColor,
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: content)
        }
        eachMatch(Self.horizontalRule) { match in
            guard !isProtected(match.range) else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: match.range)
        }

        // --- Inline spans -----------------------------------------------------
        eachMatch(Self.bold) { match in
            guard !isProtected(match.range) else { return }
            addTrait(.bold, over: match.range, in: storage)
            dimDelimiters(storage, span: match.range, markerLength: match.range(at: 1).length)
        }
        for regex in [Self.italicStar, Self.italicUnderscore] {
            eachMatch(regex) { match in
                guard !isProtected(match.range) else { return }
                addTrait(.italic, over: match.range, in: storage)
                dimDelimiters(storage, span: match.range, markerLength: 1)
            }
        }
        eachMatch(Self.strikethrough) { match in
            guard !isProtected(match.range) else { return }
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            dimDelimiters(storage, span: match.range, markerLength: 2)
        }
        eachMatch(Self.link) { match in
            guard !isProtected(match.range) else { return }
            let label = match.range(at: 1)
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            let target = ns.substring(with: match.range(at: 2))
            if let url = URL(string: target.hasPrefix("www.") ? "https://\(target)" : target) {
                attrs[.link] = url
            }
            storage.addAttributes(attrs, range: label)
            // Dim the brackets and the (url) tail surrounding the label.
            dim(storage, NSRange(location: match.range.location, length: label.location - match.range.location))
            dim(storage, NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)))
        }

        // Bare URLs (https://…, www.…) become clickable links.
        eachMatch(Self.bareURL) { match in
            var range = match.range(at: 1)
            guard !isProtected(range) else { return }
            // Trim trailing sentence punctuation that isn't part of the URL.
            while range.length > 0 {
                let last = ns.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1))
                guard ".,;:!?".contains(last) else { break }
                range.length -= 1
            }
            guard range.length > 0 else { return }
            var urlString = ns.substring(with: range)
            if urlString.hasPrefix("www.") { urlString = "https://\(urlString)" }
            guard let url = URL(string: urlString) else { return }
            storage.addAttributes([
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .link: url,
            ], range: range)
            protectedRanges.append(range)
        }
    }

    // MARK: - Attribute helpers

    private func headingFont(level: Int) -> NSFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.8
        case 2: scale = 1.5
        case 3: scale = 1.3
        case 4: scale = 1.15
        case 5: scale = 1.05
        default: scale = 1.0
        }
        return NSFont.monospacedSystemFont(ofSize: baseSize * scale, weight: .bold)
    }

    /// Sets `.font` over the range, replacing whatever is there.
    private func addAttribute(_ key: NSAttributedString.Key, value: Any, over range: NSRange, in storage: NSTextStorage) {
        storage.addAttribute(key, value: value, range: range)
    }

    /// Adds a symbolic trait (bold/italic) to the *existing* font at each run,
    /// so e.g. bold inside an H1 keeps the H1 size and just gains weight.
    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, over range: NSRange, in storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, subRange, _ in
            let current = (value as? NSFont) ?? NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            var traits = current.fontDescriptor.symbolicTraits
            traits.insert(trait)
            let descriptor = current.fontDescriptor.withSymbolicTraits(traits)
            if let font = NSFont(descriptor: descriptor, size: current.pointSize) {
                storage.addAttribute(.font, value: font, range: subRange)
            }
        }
    }

    private func dim(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
    }

    private func dimDelimiters(_ storage: NSTextStorage, span: NSRange, markerLength: Int) {
        guard span.length >= markerLength * 2 else { return }
        dim(storage, NSRange(location: span.location, length: markerLength))
        dim(storage, NSRange(location: NSMaxRange(span) - markerLength, length: markerLength))
    }

    private static let codeBackground = NSColor.systemGray.withAlphaComponent(0.28)
    private static let secretBackground = NSColor.systemGray.withAlphaComponent(0.22)

    // MARK: - GFM patterns

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let heading = regex(#"^(#{1,6})[ \t]+(.+)$"#, .anchorsMatchLines)
    private static let blockquote = regex(#"^[ \t]*>[ \t]?.*$"#, .anchorsMatchLines)
    private static let listMarker = regex(#"^([ \t]*)([-*+]|\d+[.)])[ \t]+"#, .anchorsMatchLines)
    private static let taskMarker = regex(#"^[ \t]*[-*+][ \t]+(\[[ xX]\])"#, .anchorsMatchLines)
    private static let completedTask = regex(#"^[ \t]*[-*+][ \t]+\[[xX]\][ \t]*(.*)$"#, .anchorsMatchLines)
    private static let horizontalRule = regex(#"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#, .anchorsMatchLines)
    private static let fencedCode = regex(#"```[\s\S]*?```"#)
    private static let inlineCode = regex(#"`[^`\n]+`"#)
    private static let bold = regex(#"(\*\*|__)([^\n]+?)\1"#)
    private static let italicStar = regex(#"(?<![*\w])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![*\w])"#)
    private static let italicUnderscore = regex(#"(?<![_\w])_(?!\s)([^_\n]+?)(?<!\s)_(?![_\w])"#)
    private static let strikethrough = regex(#"~~([^\n]+?)~~"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    private static let bareURL = regex(#"(?<![\w@./])((?:https?://|www\.)[^\s<>"')\]]+)"#)
}
