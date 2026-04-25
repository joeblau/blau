import Foundation
import SwiftData

enum PaneKind: String, Codable, CaseIterable {
    case terminal
    case browser
    case simulator
}

enum AppearanceMode: String, Codable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

enum InspectorTab: String, Codable, CaseIterable {
    case actions = "Actions"
    case commits = "Commits"
    case filesystem = "Files"
}

enum RootPathSource: String, Codable {
    case automatic
    case manual
}

enum PersistentTerminalSession {
    private static let tmuxCandidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    static func bootstrapCommand(for pane: Pane, workingDirectory: String?) -> String? {
        guard let tmuxPath = tmuxExecutablePath() else { return nil }

        let sessionName = shellEscape(pane.persistentSessionName)
        let tmux = shellEscape(tmuxPath)
        let createCommand: String
        let configureSessionCommand = """
        \(tmux) set-option -t \(sessionName) status off >/dev/null 2>&1
        \(tmux) set-option -t \(sessionName) mouse on >/dev/null 2>&1
        """

        if let workingDirectory = validWorkingDirectory(workingDirectory) {
            createCommand = "\(tmux) new-session -d -s \(sessionName) -c \(shellEscape(workingDirectory))"
        } else {
            createCommand = "\(tmux) new-session -d -s \(sessionName)"
        }

        return """
        if \(tmux) has-session -t \(sessionName) 2>/dev/null; then
          \(configureSessionCommand)
          exec \(tmux) attach-session -t \(sessionName)
        else
          \(createCommand)
          \(configureSessionCommand)
          exec \(tmux) attach-session -t \(sessionName)
        fi
        """ + "\n"
    }

    static func killSession(for pane: Pane) {
        guard pane.kind == .terminal,
              let tmuxPath = tmuxExecutablePath() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["kill-session", "-t", pane.persistentSessionName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private static func tmuxExecutablePath() -> String? {
        tmuxCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func validWorkingDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shellEscape(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
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
        if let request {
            if request.absoluteString == "blau://stop" {
                isLoading = false
            } else {
                isLoading = true
            }
        }
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
    var isCollapsed: Bool = false
    var restoredSizeFraction: Double = 0
    var wasCollapsedBeforeFocus: Bool = false

    @Relationship(deleteRule: .cascade)
    var browserState: BrowserState?

    @Relationship(deleteRule: .cascade)
    var simulatorState: SimulatorState?

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
        switch kind {
        case .terminal:
            break
        case .browser:
            self.browserState = BrowserState()
        case .simulator:
            self.simulatorState = SimulatorState()
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

    var persistentSessionName: String {
        "pilot-\(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    /// Reads the live cwd of the pane's shell process from the kernel.
    /// Unlike `currentDirectory` (updated only when the shell emits OSC 7 on
    /// each prompt), this works even while a foreground process like Claude
    /// Code owns the pty — the shell is paused but its cwd is still current.
    func liveShellCurrentDirectory() -> String? {
        let dir = "\(NSTemporaryDirectory())pilot-panes-\(ProcessInfo.processInfo.processIdentifier)"
        let pidFile = "\(dir)/\(id.uuidString.lowercased()).pid"
        guard let raw = try? String(contentsOfFile: pidFile, encoding: .utf8) else { return nil }
        guard let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }

        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else { return nil }

        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
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
    var focusedPaneID: UUID?
    var isPinned: Bool = false
    var workspaceSortOrder: Int = 0
    var rootPath: String = ""
    var rootPathSourceRaw: String? = RootPathSource.automatic.rawValue

    @Relationship(deleteRule: .cascade, inverse: \Pane.workspace)
    var panes: [Pane] = []

    var selectedPane: Pane? {
        sortedPanes.first { $0.id == selectedPaneID }
    }

    var frontmostTerminalPane: Pane? {
        if let frontmostTerminalPaneID,
           let pane = sortedPanes.first(where: {
               $0.id == frontmostTerminalPaneID && $0.kind == .terminal && !$0.isCollapsed
           }) {
            return pane
        }

        if let selectedPane, selectedPane.kind == .terminal, !selectedPane.isCollapsed {
            return selectedPane
        }

        return sortedPanes.first { $0.kind == .terminal && !$0.isCollapsed }
            ?? sortedPanes.first { $0.kind == .terminal }
    }

    var leftmostTerminalPane: Pane? {
        sortedPanes.first { $0.kind == .terminal && !$0.isCollapsed }
            ?? sortedPanes.first { $0.kind == .terminal }
    }

    var rootTrackingTerminalPane: Pane? {
        if let selectedPane, selectedPane.kind == .terminal, !selectedPane.isCollapsed {
            return selectedPane
        }

        return frontmostTerminalPane ?? leftmostTerminalPane
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

    var rootPathSource: RootPathSource {
        get { RootPathSource(rawValue: rootPathSourceRaw ?? "") ?? .automatic }
        set { rootPathSourceRaw = newValue.rawValue }
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
        PersistentTerminalSession.killSession(for: pane)
        panes.removeAll { $0.id == pane.id }
        if selectedPaneID == pane.id {
            selectedPaneID = sortedPanes.first(where: { !$0.isCollapsed })?.id ?? sortedPanes.first?.id
        }
        if frontmostTerminalPaneID == pane.id {
            frontmostTerminalPaneID = sortedPanes.first(where: { $0.kind == .terminal && !$0.isCollapsed })?.id
                ?? sortedPanes.first(where: { $0.kind == .terminal })?.id
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

    var normalizedExpandedSizeFractions: [UUID: Double] {
        normalizedSizeFractions(for: sortedPanes.filter { !$0.isCollapsed })
    }

    func canResizePanes(leadingID: UUID, trailingID: UUID) -> Bool {
        resizePanePair(leadingID: leadingID, trailingID: trailingID) != nil
    }

    /// Resize the nearest expanded panes on either side of the divider by a delta
    /// (in fraction of total expanded size). Collapsed panes keep their slit width.
    func resizePanes(leadingID: UUID, trailingID: UUID, delta: Double) {
        guard let (leadingPane, trailingPane) = resizePanePair(
            leadingID: leadingID,
            trailingID: trailingID
        ) else { return }

        let fractions = normalizedExpandedSizeFractions
        guard let leadFrac = fractions[leadingPane.id],
              let trailFrac = fractions[trailingPane.id] else { return }

        let minFraction = 0.1
        let newLead = max(minFraction, min(leadFrac + delta, leadFrac + trailFrac - minFraction))
        let newTrail = leadFrac + trailFrac - newLead

        // Apply to all panes (initialize any that were 0)
        for pane in sortedPanes where !pane.isCollapsed {
            if pane.id == leadingPane.id {
                pane.sizeFraction = newLead
            } else if pane.id == trailingPane.id {
                pane.sizeFraction = newTrail
            } else if pane.sizeFraction <= 0 {
                pane.sizeFraction = fractions[pane.id] ?? (1.0 / Double(panes.count))
            }
        }
    }

    func persistPaneSizes() {
        let fractions = normalizedExpandedSizeFractions
        for pane in sortedPanes where !pane.isCollapsed {
            pane.sizeFraction = fractions[pane.id] ?? (1.0 / Double(max(panes.count, 1)))
        }
        try? modelContext?.save()
    }

    /// Reset all panes to equal size.
    func resetPaneSizes() {
        let equal = 1.0 / Double(max(panes.count, 1))
        for pane in panes {
            if pane.isCollapsed {
                pane.restoredSizeFraction = equal
            } else {
                pane.sizeFraction = equal
            }
        }
        try? modelContext?.save()
    }

    func collapsePane(_ pane: Pane) {
        guard !pane.isCollapsed else { return }

        let currentFraction = normalizedExpandedSizeFractions[pane.id] ?? pane.sizeFraction
        pane.restoredSizeFraction = currentFraction > 0 ? currentFraction : 1.0 / Double(max(panes.count, 1))
        pane.isCollapsed = true

        if selectedPaneID == pane.id {
            selectedPaneID = sortedPanes.first(where: { !$0.isCollapsed && $0.id != pane.id })?.id ?? pane.id
        }
        if frontmostTerminalPaneID == pane.id {
            frontmostTerminalPaneID = sortedPanes.first(where: { $0.kind == .terminal && !$0.isCollapsed })?.id
                ?? (pane.kind == .terminal ? pane.id : nil)
        }

        try? modelContext?.save()
    }

    func expandPane(_ pane: Pane) {
        guard pane.isCollapsed else { return }

        let expandedPanes = sortedPanes.filter { !$0.isCollapsed && $0.id != pane.id }
        let currentFractions = normalizedSizeFractions(for: expandedPanes)
        let restoredFraction = clampedRestoredFraction(for: pane, expandedSiblingCount: expandedPanes.count)
        let remainingFraction = max(0, 1.0 - restoredFraction)

        pane.isCollapsed = false
        pane.sizeFraction = restoredFraction
        for sibling in expandedPanes {
            sibling.sizeFraction = (currentFractions[sibling.id] ?? 0) * remainingFraction
        }

        selectedPaneID = pane.id
        if pane.kind == .terminal {
            frontmostTerminalPaneID = pane.id
        }

        try? modelContext?.save()
    }

    func focusPane(_ pane: Pane) {
        if focusedPaneID == pane.id {
            restoreFocusedPane()
            return
        }

        if focusedPaneID != nil {
            restoreFocusedPane()
        }

        let expandedFractions = normalizedExpandedSizeFractions
        for existingPane in sortedPanes {
            existingPane.wasCollapsedBeforeFocus = existingPane.isCollapsed
            if !existingPane.isCollapsed {
                let currentFraction = expandedFractions[existingPane.id] ?? existingPane.sizeFraction
                existingPane.restoredSizeFraction = currentFraction > 0
                    ? currentFraction
                    : 1.0 / Double(max(panes.count, 1))
            }
        }

        if pane.isCollapsed {
            expandPane(pane)
        }

        for otherPane in sortedPanes where otherPane.id != pane.id && !otherPane.isCollapsed {
            otherPane.isCollapsed = true
        }

        pane.isCollapsed = false
        pane.sizeFraction = 1.0
        selectedPaneID = pane.id
        focusedPaneID = pane.id
        if pane.kind == .terminal {
            frontmostTerminalPaneID = pane.id
        }

        try? modelContext?.save()
    }

    func syncDefaultRootPathIfNeeded(using pane: Pane? = nil) {
        guard rootPathSource == .automatic else { return }

        guard let rootTrackingTerminalPane else {
            if !rootPath.isEmpty {
                rootPath = ""
                try? modelContext?.save()
            }
            return
        }

        if let pane, pane.id != rootTrackingTerminalPane.id {
            return
        }

        let liveDirectory = rootTrackingTerminalPane.liveShellCurrentDirectory()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cachedDirectory = rootTrackingTerminalPane.currentDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = (liveDirectory?.isEmpty == false ? liveDirectory! : cachedDirectory)
        let repoRoot = directory.isEmpty ? nil : GitCommitStore.findGitRoot(from: directory)
        let nextRootPath = repoRoot ?? ""

        guard rootPath != nextRootPath else { return }
        rootPath = nextRootPath
        try? modelContext?.save()
    }

    func setRootPath(_ path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextRootPath = trimmedPath.isEmpty
            ? ""
            : (trimmedPath as NSString).expandingTildeInPath

        let nextSource: RootPathSource = nextRootPath.isEmpty ? .automatic : .manual
        guard rootPath != nextRootPath || rootPathSource != nextSource else { return }
        rootPath = nextRootPath
        rootPathSource = nextSource
        try? modelContext?.save()
    }

    enum Side {
        case left, right
    }

    private func inheritedDirectoryForNewTerminal() -> String {
        if let effectiveRootPath {
            return effectiveRootPath
        }

        if let selectedPaneID,
           let selectedPane = sortedPanes.first(where: { $0.id == selectedPaneID }),
           selectedPane.kind == .terminal,
           !selectedPane.isCollapsed {
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

    private func normalizedSizeFractions(for panes: [Pane]) -> [UUID: Double] {
        guard !panes.isEmpty else { return [:] }

        let assigned = panes.filter { $0.sizeFraction > 0 }
        if assigned.isEmpty {
            let equal = 1.0 / Double(panes.count)
            return Dictionary(uniqueKeysWithValues: panes.map { ($0.id, equal) })
        }

        let assignedTotal = assigned.reduce(0.0) { $0 + $1.sizeFraction }
        let defaultWeight = assignedTotal / Double(assigned.count)
        let weights = panes.map { pane in
            (pane.id, pane.sizeFraction > 0 ? pane.sizeFraction : defaultWeight)
        }
        let totalWeight = weights.reduce(0.0) { $0 + $1.1 }

        guard totalWeight > 0 else {
            let equal = 1.0 / Double(panes.count)
            return Dictionary(uniqueKeysWithValues: panes.map { ($0.id, equal) })
        }

        return Dictionary(uniqueKeysWithValues: weights.map { ($0.0, $0.1 / totalWeight) })
    }

    private func restoreFocusedPane() {
        guard focusedPaneID != nil else { return }

        let fallbackFraction = 1.0 / Double(max(panes.count, 1))
        for pane in sortedPanes {
            pane.isCollapsed = pane.wasCollapsedBeforeFocus
            pane.wasCollapsedBeforeFocus = false

            if !pane.isCollapsed {
                pane.sizeFraction = pane.restoredSizeFraction > 0
                    ? pane.restoredSizeFraction
                    : fallbackFraction
            }
        }

        focusedPaneID = nil
        selectedPaneID = sortedPanes.first(where: { $0.id == selectedPaneID && !$0.isCollapsed })?.id
            ?? sortedPanes.first(where: { !$0.isCollapsed })?.id
            ?? sortedPanes.first?.id

        if let frontmostTerminalPaneID,
           sortedPanes.contains(where: {
               $0.id == frontmostTerminalPaneID && $0.kind == .terminal && !$0.isCollapsed
           }) {
            self.frontmostTerminalPaneID = frontmostTerminalPaneID
        } else {
            self.frontmostTerminalPaneID = sortedPanes.first(where: { $0.kind == .terminal && !$0.isCollapsed })?.id
                ?? sortedPanes.first(where: { $0.kind == .terminal })?.id
        }

        try? modelContext?.save()
    }

    private func resizePanePair(leadingID: UUID, trailingID: UUID) -> (Pane, Pane)? {
        let sorted = sortedPanes
        guard let leadingIndex = sorted.firstIndex(where: { $0.id == leadingID }),
              let trailingIndex = sorted.firstIndex(where: { $0.id == trailingID }),
              trailingIndex == leadingIndex + 1 else { return nil }

        let leadingPane = sorted[...leadingIndex].last(where: { !$0.isCollapsed })
        let trailingPane = sorted[trailingIndex...].first(where: { !$0.isCollapsed })

        guard let leadingPane,
              let trailingPane,
              leadingPane.id != trailingPane.id else { return nil }

        return (leadingPane, trailingPane)
    }

    private func clampedRestoredFraction(for pane: Pane, expandedSiblingCount: Int) -> Double {
        let fallback = 1.0 / Double(max(panes.count, 1))
        let restored = pane.restoredSizeFraction > 0 ? pane.restoredSizeFraction : fallback
        guard expandedSiblingCount > 0 else { return 1.0 }
        return min(max(0.1, restored), 0.85)
    }
}
