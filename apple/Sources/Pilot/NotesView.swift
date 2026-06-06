import AppKit
import SwiftUI

/// Detail-area view for the global Notes mode (toggled with ⌘0). Renders a
/// horizontal tab bar of notes across the top with a text editor below for
/// the selected note — the same shape as the browser/terminal tab strip.
struct NotesView: View {
    @Bindable var store: WorkspaceStore
    @State private var showCopiedToast = false
    @State private var toastDismiss: DispatchWorkItem?
    /// Set when the user closes a note tab that still has content, so we can
    /// confirm before the (undoable-free) delete. Empty notes close immediately.
    @State private var noteToClose: Note?

    var body: some View {
        let notes = store.notes
        VStack(spacing: 0) {
            tabBar(notes: notes)
            Divider()
            editor
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                CopiedSecretToast()
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(
                get: { noteToClose != nil },
                set: { if !$0 { noteToClose = nil } }
            ),
            presenting: noteToClose
        ) { note in
            Button("Delete Note", role: .destructive) {
                store.deleteNote(note)
                noteToClose = nil
            }
            Button("Cancel", role: .cancel) { noteToClose = nil }
        } message: { note in
            Text("“\(note.displayTitle)” will be permanently deleted. This can’t be undone.")
        }
    }

    /// Closing a note tab deletes the note. Confirm first when there's content
    /// to lose; close empty notes immediately so creating + dismissing a blank
    /// note doesn't nag.
    private func requestClose(_ note: Note) {
        if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.deleteNote(note)
        } else {
            noteToClose = note
        }
    }

    private func flashCopiedToast() {
        toastDismiss?.cancel()
        withAnimation(.snappy(duration: 0.18)) { showCopiedToast = true }
        let work = DispatchWorkItem {
            withAnimation(.snappy(duration: 0.3)) { showCopiedToast = false }
        }
        toastDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func tabBar(notes: [Note]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(notes) { note in
                    NoteTab(
                        title: note.displayTitle,
                        isSelected: note.id == store.selectedNoteID,
                        onSelect: { store.selectedNoteID = note.id },
                        onClose: { requestClose(note) }
                    )
                    // Drag-to-reorder (issue #67). The note's id rides along as
                    // the dragged payload; dropping onto another tab inserts the
                    // dragged note just before it and persists the new order.
                    .draggable(note.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first,
                              let draggedID = UUID(uuidString: raw) else { return false }
                        store.moveNote(draggedID, before: note.id)
                        return true
                    }
                }

                Button {
                    store.addNote()
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 12, weight: .medium)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Note")
                // Dropping a tab on (or past) the + button sends it to the end.
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first,
                          let draggedID = UUID(uuidString: raw) else { return false }
                    store.moveNoteToEnd(draggedID)
                    return true
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let note = store.selectedNote {
            NoteEditor(note: note, onCopySecret: flashCopiedToast)
                // Re-create the editor when the selected note changes so the
                // text view rebinds cleanly instead of reusing stale state.
                .id(note.id)
        } else {
            ContentUnavailableView(
                "No Note",
                systemImage: "note.text",
                description: Text("Create a note with the + button.")
            )
        }
    }
}

private struct NoteEditor: View {
    @Bindable var note: Note
    let onCopySecret: () -> Void
    @Environment(\.uiZoom) private var uiZoom

    var body: some View {
        NoteTextView(text: $note.body, fontSize: 13 * uiZoom, onCopySecret: onCopySecret)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: note.body) {
                try? note.modelContext?.save()
            }
    }
}

/// `NSTextView`-backed editor with live GitHub-Flavored-Markdown styling. We
/// drop out of SwiftUI's `TextEditor` for two reasons: driving `selectedRanges`
/// directly (⇧⌘L multi-cursor), and attaching a `MarkdownStyler` as the text
/// storage delegate so markdown renders in place as you type. The raw markdown
/// source stays editable and is what we persist — only attributes change.
private struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let onCopySecret: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MultiCursorTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? MultiCursorTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.allowsUndo = true
        // Rich so our programmatic attributes render reliably; the user can't
        // introduce their own formatting (no Format menu) and we store plain
        // `.string`, so the document stays markdown source either way.
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Wider horizontal inset carves out a left gutter for the secret lock.
        textView.textContainerInset = NSSize(width: 28, height: 10)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        let styler = context.coordinator.styler
        styler.baseSize = fontSize
        textView.textStorage?.delegate = styler

        // Touching `layoutManager` forces TextKit 1, which the secret-masking
        // glyph substitution (and checkbox hit-testing) depend on.
        let maskController = context.coordinator.maskController
        maskController.textView = textView
        textView.maskController = maskController
        textView.onCopySecret = onCopySecret
        textView.layoutManager?.delegate = maskController

        textView.string = text
        if let storage = textView.textStorage {
            styler.style(storage)
        }
        maskController.refresh()
        // Sort any already-completed tasks to the bottom of their group on load.
        DispatchQueue.main.async { textView.reorderCompletedTasks() }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MultiCursorTextView else { return }
        let styler = context.coordinator.styler

        if styler.baseSize != fontSize {
            styler.baseSize = fontSize
            textView.typingAttributes[.font] = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            if let storage = textView.textStorage {
                styler.style(storage)
            }
        }

        // Only overwrite when the model diverges from the view (e.g. an
        // external edit) — never on the user's own keystrokes, which would
        // stomp the cursor(s). Setting `.string` re-triggers styling via the
        // storage delegate.
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: NoteTextView
        let styler: MarkdownStyler
        let maskController = EnvMaskController()

        init(_ parent: NoteTextView) {
            self.parent = parent
            self.styler = MarkdownStyler(baseSize: parent.fontSize)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MultiCursorTextView else { return }
            parent.text = textView.string
            maskController.refresh()
            textView.reorderCompletedTasks()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Reveal the secret on the line being edited, re-mask the rest.
            maskController.refresh()
        }
    }
}

/// Borderless SF Symbol button used for the editor's gutter affordances.
private final class GutterButton: NSButton {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A small color swatch placed just after an inline-code color (e.g. `#00FF3F`).
/// Clicking it copies the color string to the pasteboard.
private final class ColorChipButton: NSButton {
    var onClick: (() -> Void)?
    var swatch: NSColor = .clear { didSet { needsDisplay = true } }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        swatch.setFill()
        path.fill()
        // A hairline border keeps light/white swatches visible against the page.
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// `NSTextView` subclass that adds ⇧⌘L "split selection into lines" — the
/// Sublime/VS Code multi-cursor gesture. Each line touched by the selection
/// gets a collapsed insertion point at the end of its selected content;
/// `NSTextView` then types into all of them simultaneously.
final class MultiCursorTextView: NSTextView, NSViewToolTipOwner {
    weak var maskController: EnvMaskController?
    var onCopySecret: (() -> Void)?
    private let lockSize: CGFloat = 16
    private var isReordering = false
    private var gutterButtons: [NSButton] = []
    /// Signature of the gutter buttons currently installed. `layout()` runs on
    /// every display pass; rebuilding the gutter subviews each time
    /// (removeFromSuperview + addSubview) re-dirties Auto Layout and makes the
    /// window perpetually "need another Update Constraints pass", which AppKit
    /// eventually aborts with an NSGenericException. We only touch the subview
    /// tree when this signature actually changes.
    private var gutterSignature = ""
    /// Color swatches placed after inline-code colors, with their own
    /// churn-guard signature (same rationale as `gutterSignature`).
    private var colorChips: [NSButton] = []
    private var colorChipSignature = ""

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            splitSelectionIntoLines()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Clicking the hover lock toggles a secret's visibility; clicking a masked
    /// `.env` value copies it; clicking a `[ ]` / `[x]` toggles it. Any other
    /// click behaves normally.
    override func mouseDown(with event: NSEvent) {
        if openLink(at: event) { return }
        if copySecret(at: event) { return }
        if toggleTaskCheckbox(at: event) { return }
        super.mouseDown(with: event)
    }

    /// Single-click on a link (bare URL or markdown link) opens it in the
    /// user's default browser via NSWorkspace.
    private func openLink(at event: NSEvent) -> Bool {
        guard event.clickCount == 1, let layoutManager, let textContainer, let textStorage else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)

        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction
        )
        // Ignore clicks past the end of the line's text (in the trailing margin).
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard containerPoint.x <= used.maxX else { return false }

        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < ns.length,
              let value = textStorage.attribute(.link, at: charIndex, effectiveRange: nil) else { return false }
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: - Per-line secret lock toggle (always shown in the left gutter)

    private func lockRect(for match: EnvSecret.Match) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: match.keyRange, actualCharacterRange: nil)
        let keyRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let origin = textContainerOrigin
        // Centered in the left gutter (the area left of the text), on the
        // secret's line.
        let x = max(4, (origin.x - lockSize) / 2)
        let y = keyRect.midY + origin.y - lockSize / 2
        return NSRect(x: x, y: y, width: lockSize, height: lockSize)
    }

    override func layout() {
        super.layout()
        layoutGutterIcons()
        layoutColorChips()
    }

    /// Places a clickable color swatch just after each inline-code span whose
    /// content is a color (e.g. `#00FF3F`, `rgb(...)`, `oklch(...)`, `cmyk(...)`).
    /// Clicking the swatch copies the color string. Same signature-guard
    /// discipline as the gutter icons so repeated layout passes don't churn the
    /// subview tree.
    private func layoutColorChips() {
        guard let layoutManager, let textContainer else { return }
        let ns = string as NSString
        let chipSize: CGFloat = 12
        let origin = textContainerOrigin

        struct Spec { let value: String; let color: NSColor; let frame: NSRect }
        var specs: [Spec] = []
        for match in ColorChip.matches(in: ns as String) {
            guard NSMaxRange(match.range) <= ns.length else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: match.range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            // Sit the swatch just past the end of the code span, vertically centered.
            let frame = NSRect(x: rect.maxX + origin.x + 6,
                               y: rect.midY + origin.y - chipSize / 2,
                               width: chipSize, height: chipSize)
            specs.append(Spec(value: match.value, color: match.color, frame: frame))
        }

        let signature = specs.map { "\($0.value)@\(NSStringFromRect($0.frame))" }
            .joined(separator: ";")
        guard signature != colorChipSignature else { return }
        colorChipSignature = signature

        colorChips.forEach { $0.removeFromSuperview() }
        colorChips.removeAll()
        for spec in specs {
            let chip = ColorChipButton(frame: spec.frame)
            chip.swatch = spec.color
            chip.toolTip = "Copy \(spec.value)"
            let value = spec.value
            chip.onClick = { [weak self] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(value, forType: .string)
                self?.onCopySecret?()
            }
            addSubview(chip)
            colorChips.append(chip)
        }
    }

    /// Gutter affordances are real buttons (custom drawing in `NSTextView.draw`
    /// doesn't composite reliably): a lock per secret line and a copy button per
    /// fenced code block, positioned in the left gutter. They live in the text
    /// view's flipped coordinate space, so they scroll with the content.
    private func layoutGutterIcons() {
        // Build the desired button specs first, derive a signature, and bail
        // before touching the subview tree if nothing changed since the last
        // pass. Mutating subviews inside `layout()` on every pass is what trips
        // the window's Update-Constraints budget (see `gutterSignature`).
        struct Spec {
            let symbol: String
            let tint: NSColor
            let frame: NSRect
            let help: String
            let key: String
            let action: () -> Void
        }
        var specs: [Spec] = []

        if let maskController {
            for secret in maskController.secrets {
                guard let rect = lockRect(for: secret) else { continue }
                let revealed = maskController.isRevealed(secret.key)
                let key = secret.key
                specs.append(Spec(
                    symbol: revealed ? "lock.open.fill" : "lock.fill",
                    tint: revealed ? .controlAccentColor : .secondaryLabelColor,
                    frame: rect,
                    help: revealed ? "Hide value" : "Reveal value",
                    key: "S|\(key)|\(revealed)"
                ) { [weak self] in
                    self?.maskController?.toggleReveal(key)
                })
            }
        }

        for block in fencedBlocks() {
            guard let rect = copyIconRect(for: block.range) else { continue }
            let content = block.content
            specs.append(Spec(
                symbol: "doc.on.doc",
                tint: .secondaryLabelColor,
                frame: rect,
                help: "Copy code block",
                key: "C|\(content.hashValue)"
            ) { [weak self] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(content, forType: .string)
                self?.onCopySecret?()
            })
        }

        let signature = specs.map { "\($0.key)@\(NSStringFromRect($0.frame))" }
            .joined(separator: ";")
        guard signature != gutterSignature else { return }
        gutterSignature = signature

        gutterButtons.forEach { $0.removeFromSuperview() }
        gutterButtons.removeAll()
        for spec in specs {
            addGutterButton(symbol: spec.symbol, tint: spec.tint, frame: spec.frame,
                            help: spec.help, action: spec.action)
        }
    }

    private func addGutterButton(symbol: String, tint: NSColor, frame: NSRect,
                                 help: String, action: @escaping () -> Void) {
        let button = GutterButton(frame: frame)
        button.onClick = action
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = help
        button.contentTintColor = tint
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
        }
        addSubview(button)
        gutterButtons.append(button)
    }

    // MARK: - Fenced code block copy

    private static let fencedCodeBlock = try! NSRegularExpression(pattern: #"```[\s\S]*?```"#)

    /// Each fenced code block's full range plus its inner code (fences stripped).
    private func fencedBlocks() -> [(range: NSRange, content: String)] {
        let ns = string as NSString
        guard ns.length > 0 else { return [] }
        var result: [(NSRange, String)] = []
        Self.fencedCodeBlock.enumerateMatches(in: ns as String,
                                              range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let range = match?.range else { return }
            var content = ns.substring(with: range)
            // Drop the opening ```lang line.
            if let firstNewline = content.firstIndex(of: "\n") {
                content = String(content[content.index(after: firstNewline)...])
            } else {
                content = ""
            }
            // Drop the closing fence (and the newline before it).
            if let close = content.range(of: "```", options: .backwards) {
                content = String(content[..<close.lowerBound])
            }
            if content.hasSuffix("\n") { content.removeLast() }
            result.append((range, content))
        }
        return result
    }

    private func copyIconRect(for blockRange: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let firstLine = (string as NSString).lineRange(for: NSRange(location: blockRange.location, length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: firstLine, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let origin = textContainerOrigin
        let x = max(4, (origin.x - lockSize) / 2)
        return NSRect(x: x, y: rect.midY + origin.y - lockSize / 2, width: lockSize, height: lockSize)
    }

    // MARK: - Env secret copy + hover affordances

    /// View-space rects of the currently masked secret values.
    private func secretRects() -> [NSRect] {
        guard let maskController, let layoutManager, let textContainer else { return [] }
        let origin = textContainerOrigin
        return maskController.maskedRanges.compactMap { range in
            guard NSMaxRange(range) <= (string as NSString).length else { return nil }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            return rect
        }
    }

    /// Refresh the pointing-hand cursor rects and "Click to copy" tooltips over
    /// the masked secrets. Called by `EnvMaskController` when the set changes.
    func updateSecretAffordances() {
        removeAllToolTips()
        for rect in secretRects() {
            addToolTip(rect, owner: self, userData: nil)
        }
        window?.invalidateCursorRects(for: self)
        layoutGutterIcons()
        layoutColorChips()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in secretRects() {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        "Click to copy"
    }

    private func copySecret(at event: NSEvent) -> Bool {
        guard let maskController, !maskController.maskedRanges.isEmpty,
              let layoutManager, let textContainer else { return false }
        let ns = string as NSString
        let viewPoint = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)

        for range in maskController.maskedRanges {
            guard NSMaxRange(range) <= ns.length else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .insetBy(dx: -3, dy: -2)
            guard rect.contains(containerPoint) else { continue }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(ns.substring(with: range), forType: .string)
            onCopySecret?()
            return true
        }
        return false
    }

    private static let taskCheckbox = try! NSRegularExpression(
        pattern: #"^[ \t]*[-*+][ \t]+(\[[ xX]\])"#
    )

    private func toggleTaskCheckbox(at event: NSEvent) -> Bool {
        guard let layoutManager, let textContainer, let textStorage else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)

        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction
        )
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < ns.length else { return false }

        // Find a checkbox on the clicked line.
        let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
        let line = ns.substring(with: lineRange)
        let lineNSRange = NSRange(location: 0, length: (line as NSString).length)
        guard let match = Self.taskCheckbox.firstMatch(in: line, range: lineNSRange) else {
            return false
        }
        let boxInLine = match.range(at: 1)
        guard boxInLine.location != NSNotFound else { return false }
        let boxRange = NSRange(location: lineRange.location + boxInLine.location, length: boxInLine.length)

        // Only toggle if the click actually landed on the checkbox glyphs.
        let boxGlyphs = layoutManager.glyphRange(forCharacterRange: boxRange, actualCharacterRange: nil)
        let boxRect = layoutManager.boundingRect(forGlyphRange: boxGlyphs, in: textContainer)
            .insetBy(dx: -4, dy: -2)
        guard boxRect.contains(containerPoint) else { return false }

        // Flip the mark character ([ ] <-> [x]) through the normal edit path
        // so undo, re-styling, and the binding/save all fire.
        let markRange = NSRange(location: boxRange.location + 1, length: 1)
        let current = ns.substring(with: markRange)
        let replacement = current.lowercased() == "x" ? " " : "x"
        guard shouldChangeText(in: markRange, replacementString: replacement) else { return false }
        textStorage.replaceCharacters(in: markRange, with: replacement)
        didChangeText()
        return true
    }

    private static let anyTaskLine = try! NSRegularExpression(pattern: #"^[ \t]*[-*+][ \t]+\[[ xX]\]"#)
    private static let doneTaskLine = try! NSRegularExpression(pattern: #"^[ \t]*[-*+][ \t]+\[[xX]\]"#)

    private func isTaskLine(_ line: String) -> Bool {
        Self.anyTaskLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private func isDoneTaskLine(_ line: String) -> Bool {
        Self.doneTaskLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// Auto-sort every contiguous task group so incomplete tasks stay on top and
    /// completed ones sink to the bottom. A no-op unless some group is actually
    /// out of order, so it never disturbs normal typing; the caret follows its
    /// line to the new position.
    func reorderCompletedTasks() {
        guard !isReordering, let textStorage else { return }
        let ns = string as NSString
        guard ns.length > 0 else { return }

        var lines = (ns as String).components(separatedBy: "\n")
        var changed = false
        var i = 0
        while i < lines.count {
            guard isTaskLine(lines[i]) else { i += 1; continue }
            var j = i
            while j < lines.count, isTaskLine(lines[j]) { j += 1 }
            let group = Array(lines[i..<j])
            let sorted = group.filter { !isDoneTaskLine($0) } + group.filter { isDoneTaskLine($0) }
            if sorted != group {
                lines.replaceSubrange(i..<j, with: sorted)
                changed = true
            }
            i = j
        }
        guard changed else { return }

        // Remember the caret's line + column so it can follow the moved line.
        let sel = selectedRange()
        let caretLineRange = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let caretLine = ns.substring(with: caretLineRange).trimmingCharacters(in: .newlines)
        let caretColumn = sel.location - caretLineRange.location

        let newText = lines.joined(separator: "\n")
        let full = NSRange(location: 0, length: ns.length)
        isReordering = true
        if shouldChangeText(in: full, replacementString: newText) {
            textStorage.replaceCharacters(in: full, with: newText)
            didChangeText()
        }
        isReordering = false

        // Restore the caret onto the same line in the reordered text.
        let newNS = string as NSString
        var restored = min(sel.location, newNS.length)
        var offset = 0
        for line in newText.components(separatedBy: "\n") {
            if line == caretLine {
                restored = min(offset + caretColumn, offset + (line as NSString).length)
                break
            }
            offset += (line as NSString).length + 1
        }
        setSelectedRange(NSRange(location: min(restored, newNS.length), length: 0))
    }

    private func splitSelectionIntoLines() {
        let ns = string as NSString
        var cursors: [NSRange] = []

        for value in selectedRanges {
            let selection = value.rangeValue

            // A bare caret (no selected text) stays as-is — there's nothing
            // to split, but we preserve any pre-existing multi-cursor state.
            guard selection.length > 0 else {
                cursors.append(selection)
                continue
            }

            let selectionEnd = selection.location + selection.length
            var lineStart = selection.location
            while lineStart < selectionEnd {
                let searchRange = NSRange(location: lineStart, length: selectionEnd - lineStart)
                let newline = ns.rangeOfCharacter(from: .newlines, options: [], range: searchRange)
                let lineEnd = newline.location == NSNotFound ? selectionEnd : newline.location
                cursors.append(NSRange(location: lineEnd, length: 0))
                if newline.location == NSNotFound { break }
                lineStart = newline.location + newline.length
            }
        }

        // `NSTextView` requires sorted, de-duplicated ranges.
        let sorted = cursors
            .sorted { $0.location < $1.location }
            .reduce(into: [NSRange]()) { result, range in
                if result.last?.location != range.location { result.append(range) }
            }

        guard !sorted.isEmpty else { return }
        selectedRanges = sorted.map { NSValue(range: $0) }
    }
}

private struct CopiedSecretToast: View {
    var body: some View {
        Label("Copied", systemImage: "checkmark.circle.fill")
            .scaledFont(size: 13, weight: .semibold)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }
}

private struct NoteTab: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .scaledFont(size: 12, weight: isSelected ? .semibold : .regular)
                .lineLimit(1)

            if isHovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 9, weight: .bold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Note")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 170, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}
