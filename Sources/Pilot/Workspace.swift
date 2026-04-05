import Foundation
import SwiftData

enum PaneKind: String, Codable, CaseIterable {
    case terminal
    case browser
}

enum AppearanceMode: String, Codable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

enum InspectorTab: String, Codable, CaseIterable {
    case actions = "Actions"
    case commits = "Commits"
}

@Model
final class BrowserState {
    var urlText: String = "https://apple.com"
    var appearanceModeRaw: String = AppearanceMode.system.rawValue
    var navigationRequestID: Int = 0
    var inspectorToggleRequestID: Int = 0

    @Transient var pendingURL: URL? = nil
    @Transient var canGoBack: Bool = false
    @Transient var canGoForward: Bool = false
    @Transient var isLoading: Bool = false
    @Transient var showDevTools: Bool = false
    @Transient var needsInspectorToggle: Bool = false

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        set { appearanceModeRaw = newValue.rawValue }
    }

    init() {
        self.pendingURL = URL(string: urlText)
    }

    func navigate() {
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            text = "https://\(text)"
            urlText = text
        }
        issueNavigationRequest(URL(string: text))
    }

    func requestNavigationCommand(_ command: String) {
        issueNavigationRequest(URL(string: command))
    }

    func toggleDeveloperTools() {
        showDevTools.toggle()
        needsInspectorToggle = true
        inspectorToggleRequestID += 1
    }

    private func issueNavigationRequest(_ request: URL?) {
        pendingURL = request
        navigationRequestID += 1
    }
}

@Model
final class Pane {
    #Unique([\Pane.id])

    var id: UUID = UUID()
    var kindRaw: String = PaneKind.terminal.rawValue
    var sortOrder: Int = 0
    var currentDirectory: String = ""
    var bellCount: Int = 0
    var sizeFraction: Double = 0

    @Relationship(deleteRule: .cascade)
    var browserState: BrowserState?

    var workspace: Workspace?

    var kind: PaneKind {
        get { PaneKind(rawValue: kindRaw) ?? .terminal }
        set { kindRaw = newValue.rawValue }
    }

    init(kind: PaneKind = .terminal, sortOrder: Int = 0, currentDirectory: String = "") {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.sortOrder = sortOrder
        self.currentDirectory = currentDirectory
        if kind == .browser {
            self.browserState = BrowserState()
        }
    }

    func incrementBellCount() {
        bellCount += 1
    }

    func resetBellCount() {
        guard bellCount != 0 else { return }
        bellCount = 0
    }

    func setCurrentDirectory(_ directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Don't persist uninteresting directories
        guard trimmed != "/" && trimmed != NSHomeDirectory() else { return }
        guard currentDirectory != trimmed else { return }
        currentDirectory = trimmed
        workspace?.syncDefaultRootPathIfNeeded(using: self)
        try? modelContext?.save()
    }
}

enum PaneAxis: String, Codable {
    case vertical
    case horizontal
}

@Model
final class Workspace {
    #Unique([\Workspace.id])

    var id: UUID = UUID()
    var name: String = ""
    var selectedPaneID: UUID?
    var frontmostTerminalPaneID: UUID?
    var axisRaw: String = PaneAxis.vertical.rawValue
    var isInspectorPresented: Bool = false
    var inspectorTabRaw: String = InspectorTab.actions.rawValue
    var isPinned: Bool = false
    var workspaceSortOrder: Int = 0
    var rootPath: String = ""

    @Relationship(deleteRule: .cascade, inverse: \Pane.workspace)
    var panes: [Pane] = []

    var selectedPane: Pane? {
        sortedPanes.first { $0.id == selectedPaneID }
    }

    var frontmostTerminalPane: Pane? {
        if let frontmostTerminalPaneID,
           let pane = sortedPanes.first(where: { $0.id == frontmostTerminalPaneID && $0.kind == .terminal }) {
            return pane
        }

        if let selectedPane, selectedPane.kind == .terminal {
            return selectedPane
        }

        return sortedPanes.first { $0.kind == .terminal }
    }

    var leftmostTerminalPane: Pane? {
        sortedPanes.first { $0.kind == .terminal }
    }

    var effectiveRootPath: String? {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var sortedPanes: [Pane] {
        panes.sorted { $0.sortOrder < $1.sortOrder }
    }

    var badgeCount: Int {
        panes.filter { $0.kind == .terminal }.reduce(0) { $0 + $1.bellCount }
    }

    var axis: PaneAxis {
        get { PaneAxis(rawValue: axisRaw) ?? .vertical }
        set { axisRaw = newValue.rawValue }
    }

    var inspectorTab: InspectorTab {
        get { InspectorTab(rawValue: inspectorTabRaw) ?? .actions }
        set { inspectorTabRaw = newValue.rawValue }
    }

    init(name: String) {
        self.id = UUID()
        self.name = name
        let initialPane = Pane(kind: .terminal)
        self.panes = [initialPane]
        self.selectedPaneID = initialPane.id
        self.frontmostTerminalPaneID = initialPane.id
    }

    func addPane(kind: PaneKind, side: Side) {
        let maxOrder = panes.map(\.sortOrder).max() ?? -1
        let pane = Pane(
            kind: kind,
            sortOrder: maxOrder + 1,
            currentDirectory: kind == .terminal ? inheritedDirectoryForNewTerminal() : ""
        )

        if let selectedID = selectedPaneID,
           let selectedPane = sortedPanes.first(where: { $0.id == selectedID }),
           let index = sortedPanes.firstIndex(where: { $0.id == selectedID }) {
            let insertOrder: Int
            if side == .left {
                insertOrder = selectedPane.sortOrder
                for p in panes where p.sortOrder >= insertOrder {
                    p.sortOrder += 1
                }
            } else {
                let nextIndex = index + 1
                if nextIndex < sortedPanes.count {
                    insertOrder = sortedPanes[nextIndex].sortOrder
                    for p in panes where p.sortOrder >= insertOrder {
                        p.sortOrder += 1
                    }
                } else {
                    insertOrder = selectedPane.sortOrder + 1
                }
            }
            pane.sortOrder = insertOrder
        }

        panes.append(pane)
        selectedPaneID = pane.id
        if kind == .terminal {
            frontmostTerminalPaneID = pane.id
        }
        syncDefaultRootPathIfNeeded()
    }

    func removePane(_ pane: Pane) {
        panes.removeAll { $0.id == pane.id }
        if selectedPaneID == pane.id {
            selectedPaneID = sortedPanes.first?.id
        }
        if frontmostTerminalPaneID == pane.id {
            frontmostTerminalPaneID = sortedPanes.first(where: { $0.kind == .terminal })?.id
        }
        syncDefaultRootPathIfNeeded()
    }

    func setFrontmostTerminalPaneID(_ paneID: UUID?) {
        guard frontmostTerminalPaneID != paneID else { return }
        frontmostTerminalPaneID = paneID
        try? modelContext?.save()
    }

    func setInspectorPresented(_ isPresented: Bool) {
        guard isInspectorPresented != isPresented else { return }
        isInspectorPresented = isPresented
        try? modelContext?.save()
    }

    func setInspectorTab(_ tab: InspectorTab) {
        guard inspectorTab != tab else { return }
        inspectorTab = tab
        try? modelContext?.save()
    }

    /// Returns normalized size fractions for sorted panes, ensuring they sum to 1.0.
    /// Unset panes borrow the average assigned weight so new panes stay visible.
    var normalizedSizeFractions: [UUID: Double] {
        let sorted = sortedPanes
        guard !sorted.isEmpty else { return [:] }

        let assigned = sorted.filter { $0.sizeFraction > 0 }
        if assigned.isEmpty {
            let equal = 1.0 / Double(sorted.count)
            return Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, equal) })
        }

        let assignedTotal = assigned.reduce(0.0) { $0 + $1.sizeFraction }
        let defaultWeight = assignedTotal / Double(assigned.count)
        let weights = sorted.map { pane in
            (pane.id, pane.sizeFraction > 0 ? pane.sizeFraction : defaultWeight)
        }
        let totalWeight = weights.reduce(0.0) { $0 + $1.1 }

        guard totalWeight > 0 else {
            let equal = 1.0 / Double(sorted.count)
            return Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, equal) })
        }

        return Dictionary(uniqueKeysWithValues: weights.map { ($0.0, $0.1 / totalWeight) })
    }

    /// Resize two adjacent panes by a delta (in fraction of total).
    /// Clamps so neither pane goes below a minimum fraction.
    func resizePanes(leadingID: UUID, trailingID: UUID, delta: Double) {
        let fractions = normalizedSizeFractions
        guard let leadFrac = fractions[leadingID],
              let trailFrac = fractions[trailingID] else { return }

        let minFraction = 0.1
        let newLead = max(minFraction, min(leadFrac + delta, leadFrac + trailFrac - minFraction))
        let newTrail = leadFrac + trailFrac - newLead

        // Apply to all panes (initialize any that were 0)
        for pane in sortedPanes {
            if pane.id == leadingID {
                pane.sizeFraction = newLead
            } else if pane.id == trailingID {
                pane.sizeFraction = newTrail
            } else if pane.sizeFraction <= 0 {
                pane.sizeFraction = fractions[pane.id] ?? (1.0 / Double(panes.count))
            }
        }
    }

    /// Reset all panes to equal size.
    func resetPaneSizes() {
        let equal = 1.0 / Double(max(panes.count, 1))
        for pane in panes {
            pane.sizeFraction = equal
        }
    }

    func syncDefaultRootPathIfNeeded(using pane: Pane? = nil) {
        guard effectiveRootPath == nil else { return }
        guard let leftmostTerminalPane else { return }
        if let pane, pane.id != leftmostTerminalPane.id {
            return
        }

        let directory = leftmostTerminalPane.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty,
              let repoRoot = GitCommitStore.findGitRoot(from: directory) else { return }

        rootPath = repoRoot
        try? modelContext?.save()
    }

    enum Side {
        case left, right
    }

    private func inheritedDirectoryForNewTerminal() -> String {
        if let selectedPaneID,
           let selectedPane = sortedPanes.first(where: { $0.id == selectedPaneID }),
           selectedPane.kind == .terminal {
            let directory = selectedPane.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !directory.isEmpty {
                return directory
            }
        }

        if let existingTerminal = sortedPanes.first(where: {
            $0.kind == .terminal && !$0.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return existingTerminal.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ""
    }
}
