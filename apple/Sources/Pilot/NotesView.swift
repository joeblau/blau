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

    var body: some View {
        TextEditor(text: $note.body)
            .scaledFont(size: 13)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: note.body) {
                try? note.modelContext?.save()
            }
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
