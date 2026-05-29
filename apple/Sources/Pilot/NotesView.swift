import AppKit
import SwiftUI

/// Detail-area view for the global Notes mode (toggled with ⌘0). Renders a
/// horizontal tab bar of notes across the top with a text editor below for
/// the selected note — the same shape as the browser/terminal tab strip.
struct NotesView: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        let notes = store.notes
        VStack(spacing: 0) {
            tabBar(notes: notes)
            Divider()
            editor
        }
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
            NoteEditor(note: note)
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
    @Environment(\.uiZoom) private var uiZoom

    var body: some View {
        NoteTextView(text: $note.body, fontSize: 13 * uiZoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: note.body) {
                try? note.modelContext?.save()
            }
    }
}

/// `NSTextView`-backed plain-text editor. We drop out of SwiftUI's
/// `TextEditor` here so we can drive `selectedRanges` directly — that's what
/// makes ⇧⌘L multi-cursor (split selection into lines) possible, since
/// `NSTextView` renders and edits multiple insertion points natively.
private struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MultiCursorTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? MultiCursorTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.string = text
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MultiCursorTextView else { return }

        // Only overwrite when the model diverges from the view (e.g. an
        // external edit) — never on the user's own keystrokes, which would
        // stomp the cursor(s).
        if textView.string != text {
            textView.string = text
        }
        let targetFont = NSFont.systemFont(ofSize: fontSize)
        if textView.font != targetFont {
            textView.font = targetFont
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: NoteTextView

        init(_ parent: NoteTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// `NSTextView` subclass that adds ⇧⌘L "split selection into lines" — the
/// Sublime/VS Code multi-cursor gesture. Each line touched by the selection
/// gets a collapsed insertion point at the end of its selected content;
/// `NSTextView` then types into all of them simultaneously.
private final class MultiCursorTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            splitSelectionIntoLines()
            return true
        }
        return super.performKeyEquivalent(with: event)
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
