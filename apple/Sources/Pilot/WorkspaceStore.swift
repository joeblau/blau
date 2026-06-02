import SwiftData
import SwiftUI

@Observable
@MainActor
final class WorkspaceStore {
    let modelContext: ModelContext
    var changeCount: Int = 0
    var selectedWorkspaceID: UUID? {
        didSet {
            if let id = selectedWorkspaceID {
                UserDefaults.standard.set(id.uuidString, forKey: "selectedWorkspaceID")
                // Looking at a workspace clears its "Action completed" badge,
                // mirroring how selecting clears terminal bells.
                if let workspace = workspaces.first(where: { $0.id == id }),
                   workspace.actionBadgeCount != 0 {
                    workspace.resetActionBadge()
                    try? modelContext.save()
                    changeCount += 1
                }
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedWorkspaceID")
            }
        }
    }

    /// True while the global Notes mode is showing in the detail area
    /// (toggled with ⌘0). Independent of `selectedWorkspaceID` so toggling
    /// out of Notes returns to whatever workspace was selected.
    var isNotesMode: Bool = false {
        didSet { UserDefaults.standard.set(isNotesMode, forKey: "notesMode") }
    }

    var selectedNoteID: UUID? {
        didSet {
            if let id = selectedNoteID {
                UserDefaults.standard.set(id.uuidString, forKey: "selectedNoteID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedNoteID")
            }
        }
    }

    var workspaces: [Workspace] {
        _ = changeCount // access to establish observation dependency
        let descriptor = FetchDescriptor<Workspace>()
        let items = (try? modelContext.fetch(descriptor)) ?? []

        return items.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }

            if lhs.workspaceSortOrder != rhs.workspaceSortOrder {
                return lhs.workspaceSortOrder < rhs.workspaceSortOrder
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Called by `WorkspaceActionWatcher` when a GitHub Action run completes
    /// for a background workspace. Bumps its badge and refreshes observers +
    /// the Copilot summaries.
    func badgeActionCompletion(workspaceID: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        workspace.incrementActionBadge()
        try? modelContext.save()
        changeCount += 1
    }

    func togglePin(_ workspace: Workspace) {
        let remaining = workspaces.filter { $0.id != workspace.id }

        workspace.isPinned.toggle()

        var pinned = remaining.filter(\.isPinned)
        var unpinned = remaining.filter { !$0.isPinned }

        if workspace.isPinned {
            pinned.insert(workspace, at: 0)
        } else {
            unpinned.insert(workspace, at: 0)
        }

        normalizeWorkspaceSortOrder(pinned + unpinned)
        try? modelContext.save()
        changeCount += 1
    }

    func movePinnedWorkspaces(fromOffsets: IndexSet, toOffset: Int) {
        moveWorkspaces(inPinnedSection: true, fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func moveUnpinnedWorkspaces(fromOffsets: IndexSet, toOffset: Int) {
        moveWorkspaces(inPinnedSection: false, fromOffsets: fromOffsets, toOffset: toOffset)
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var notes: [Note] {
        _ = changeCount // access to establish observation dependency
        let descriptor = FetchDescriptor<Note>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    var selectedNote: Note? {
        notes.first { $0.id == selectedNoteID }
    }

    /// ⌘0: flip into Notes mode (ensuring there's a note to show) or back
    /// out to the previously selected workspace.
    func toggleNotesMode() {
        if isNotesMode {
            isNotesMode = false
        } else {
            enterNotesMode()
        }
    }

    func enterNotesMode() {
        ensureAtLeastOneNote()
        isNotesMode = true
    }

    @discardableResult
    func addNote() -> Note {
        let maxOrder = notes.map(\.sortOrder).max() ?? -1
        let note = Note(sortOrder: maxOrder + 1)
        modelContext.insert(note)
        try? modelContext.save()
        changeCount += 1
        selectedNoteID = note.id
        return note
    }

    func deleteNote(_ note: Note) {
        let wasSelected = selectedNoteID == note.id
        let remaining = notes.filter { $0.id != note.id }
        modelContext.delete(note)
        for (index, remainingNote) in remaining.enumerated() {
            remainingNote.sortOrder = index
        }
        try? modelContext.save()
        changeCount += 1
        if wasSelected {
            selectedNoteID = remaining.first?.id
        }
    }

    /// Drag-to-reorder a note tab (issue #67): place the dragged note just
    /// before the drop-target note and renumber every note's `sortOrder` so the
    /// new order persists across launches.
    func moveNote(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID else { return }
        var ordered = notes
        guard let from = ordered.firstIndex(where: { $0.id == draggedID }),
              let to = ordered.firstIndex(where: { $0.id == targetID }) else { return }
        ordered.move(fromOffsets: IndexSet(integer: from), toOffset: to)
        normalizeNoteSortOrder(ordered)
    }

    /// Drop a dragged note past the last tab to send it to the end.
    func moveNoteToEnd(_ draggedID: UUID) {
        var ordered = notes
        guard let from = ordered.firstIndex(where: { $0.id == draggedID }),
              from != ordered.count - 1 else { return }
        ordered.move(fromOffsets: IndexSet(integer: from), toOffset: ordered.count)
        normalizeNoteSortOrder(ordered)
    }

    private func normalizeNoteSortOrder(_ ordered: [Note]) {
        for (index, note) in ordered.enumerated() {
            note.sortOrder = index
        }
        try? modelContext.save()
        changeCount += 1
    }

    private func ensureAtLeastOneNote() {
        if notes.isEmpty {
            addNote()
        } else if selectedNote == nil {
            selectedNoteID = notes.first?.id
        }
    }

    var summaries: [WorkspaceSummary] {
        workspaces.map { workspace in
            WorkspaceSummary(
                id: workspace.id,
                name: workspace.name,
                isPinned: workspace.isPinned,
                badgeCount: workspace.badgeCount,
                tabs: Self.tabSummaries(for: workspace),
                selectedTabID: workspace.selectedPaneID
            )
        }
    }

    /// Map a workspace's panes to Copilot tab summaries, numbering panes of
    /// the same kind ("Terminal 1", "Terminal 2") so duplicates are tellable
    /// apart on the phone.
    private static func tabSummaries(for workspace: Workspace) -> [TabSummary] {
        let panes = workspace.sortedPanes
        let totals = Dictionary(grouping: panes, by: \.kind).mapValues(\.count)
        var seen: [PaneKind: Int] = [:]
        return panes.map { pane in
            seen[pane.kind, default: 0] += 1
            let title = (totals[pane.kind] ?? 1) > 1
                ? "\(pane.kind.displayName) \(seen[pane.kind]!)"
                : pane.kind.displayName
            return TabSummary(id: pane.id, title: title, systemImageName: pane.kind.systemImageName)
        }
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        if let stored = UserDefaults.standard.string(forKey: "selectedWorkspaceID") {
            self.selectedWorkspaceID = UUID(uuidString: stored)
        }
        if let storedNote = UserDefaults.standard.string(forKey: "selectedNoteID") {
            self.selectedNoteID = UUID(uuidString: storedNote)
        }
        self.isNotesMode = UserDefaults.standard.bool(forKey: "notesMode")
        cleanupBadDirectories()
    }

    private func cleanupBadDirectories() {
        let home = NSHomeDirectory()
        let descriptor = FetchDescriptor<Pane>()
        guard let allPanes = try? modelContext.fetch(descriptor) else { return }
        for pane in allPanes {
            let dir = pane.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if dir == "/" || dir == home {
                pane.currentDirectory = ""
            }
        }
    }

    /// Demo-mode only: seed a couple of representative workspaces so the
    /// sidebar/layout looks intentional for a screenshot when there is no live
    /// peer and no real data. Guarded by the caller on the `demoMode`
    /// UserDefaults bool; additionally a no-op if any workspaces already exist
    /// so a normal launch (with real saved workspaces) is never touched.
    func seedDemoWorkspacesIfNeeded() {
        guard workspaces.isEmpty else { return }

        let names = ["blau", "web", "infra"]
        for (index, name) in names.enumerated() {
            let workspace = Workspace(name: name)
            workspace.workspaceSortOrder = index
            if index == 0 {
                workspace.isPinned = true
            }
            modelContext.insert(workspace)
        }
        try? modelContext.save()
        changeCount += 1
        selectedWorkspaceID = workspaces.first?.id
    }

    func addWorkspace() {
        let workspace = Workspace(name: "Workspace \(workspaces.count + 1)")
        workspace.workspaceSortOrder = workspaces.count
        modelContext.insert(workspace)
        try? modelContext.save()
        changeCount += 1
        selectedWorkspaceID = workspace.id
    }

    func deleteWorkspace(_ workspace: Workspace) {
        let wasSelected = selectedWorkspaceID == workspace.id
        for pane in workspace.panes {
            PersistentTerminalSession.killSession(for: pane)
        }
        modelContext.delete(workspace)
        normalizeWorkspaceSortOrder(workspaces.filter { $0.id != workspace.id })
        try? modelContext.save()
        changeCount += 1
        if wasSelected {
            selectedWorkspaceID = workspaces.first?.id
        }
    }

    private func normalizeWorkspaceSortOrder(_ orderedWorkspaces: [Workspace]) {
        for (index, workspace) in orderedWorkspaces.enumerated() {
            workspace.workspaceSortOrder = index
        }
    }

    private func moveWorkspaces(inPinnedSection isPinned: Bool, fromOffsets: IndexSet, toOffset: Int) {
        var pinned = workspaces.filter(\.isPinned)
        var unpinned = workspaces.filter { !$0.isPinned }

        if isPinned {
            pinned.move(fromOffsets: fromOffsets, toOffset: toOffset)
        } else {
            unpinned.move(fromOffsets: fromOffsets, toOffset: toOffset)
        }

        normalizeWorkspaceSortOrder(pinned + unpinned)
        try? modelContext.save()
        changeCount += 1
    }
}
