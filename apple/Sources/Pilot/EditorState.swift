import Foundation
import SwiftData

/// Persisted state for an editor pane. We only remember which file is open —
/// the buffer itself lives on disk, so reopening a workspace re-reads the file
/// rather than restoring a stale in-memory copy. An empty `filePath` means the
/// pane has no file yet and should present the fuzzy finder.
@Model
final class EditorState {
    var filePath: String = ""        // absolute path of the open file; empty => finder showing

    init() {}

    /// File URL for the open path, or `nil` while the finder is showing.
    var fileURL: URL? { filePath.isEmpty ? nil : URL(fileURLWithPath: filePath) }
}
