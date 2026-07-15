import Foundation
import SwiftData

/// A global, app-level scratchpad note. Notes are not tied to a workspace —
/// they live above the Pinned section in the sidebar and surface as a tab
/// bar of text editors in the detail area, toggled with ⌘0.
@Model
final class Note {
    #Unique([\Note.id])

    var id: UUID = UUID()
    var body: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    init(body: String = "", sortOrder: Int = 0) {
        self.id = UUID()
        self.body = body
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    /// Tab label derived from the first non-empty line of the note body,
    /// truncated so tabs stay compact. Falls back to "New Note" while empty.
    var displayTitle: String {
        for line in EnvSecret.redacted(body).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed.count > 24 ? String(trimmed.prefix(24)) + "…" : trimmed
            }
        }
        return "New Note"
    }
}
