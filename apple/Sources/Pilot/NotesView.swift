import AppKit
import SwiftUI

/// Detail-area view for the global Notes mode (toggled with ⌘0). Renders a
/// horizontal tab bar of notes across the top with a text editor below for
/// the selected note — the same shape as the browser/terminal tab strip.
struct NotesView: View {
    @Bindable var store: WorkspaceStore
    @State private var showCopiedToast = false
    @State private var toastDismiss: DispatchWorkItem?

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
                        onClose: { store.deleteNote(note) }
                    )
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
        textView.textContainerInset = NSSize(width: 8, height: 10)
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
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            maskController.refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Reveal the secret on the line being edited, re-mask the rest.
            maskController.refresh()
        }
    }
}

/// `NSTextView` subclass that adds ⇧⌘L "split selection into lines" — the
/// Sublime/VS Code multi-cursor gesture. Each line touched by the selection
/// gets a collapsed insertion point at the end of its selected content;
/// `NSTextView` then types into all of them simultaneously.
final class MultiCursorTextView: NSTextView, NSViewToolTipOwner {
    weak var maskController: EnvMaskController?
    var onCopySecret: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            splitSelectionIntoLines()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Clicking a masked `.env` secret copies it; clicking a `[ ]` / `[x]`
    /// checkbox toggles it. Any other click behaves normally.
    override func mouseDown(with event: NSEvent) {
        if copySecret(at: event) { return }
        if toggleTaskCheckbox(at: event) { return }
        super.mouseDown(with: event)
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
        Label("Secret Copied", systemImage: "checkmark.circle.fill")
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
