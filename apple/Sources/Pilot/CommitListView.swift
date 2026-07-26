import AppKit
import SwiftUI

/// The inspector's tab selector — SwiftUI's rounded segmented control. It fills
/// the inspector width and compresses labels as the column narrows.
struct InspectorTabSelector: View {
    @Binding var selection: InspectorTab

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Label(tab.rawValue, systemImage: tab.systemImageName).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .font(.title3)
        .labelsHidden()
    }
}

/// One geometry for the metadata row directly beneath every inspector tab.
/// Keeping this shared prevents icon, title, and refresh controls from shifting
/// when the user switches between Actions, Tasks, Commits, Files, and Usage.
struct InspectorSectionHeader: View {
    let title: String
    let systemImage: String
    var titleDesign: Font.Design = .default
    var isLoading = false
    var refreshHelp: String?
    var isRefreshDisabled = false
    var refresh: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .scaledFont(size: 11, weight: .medium)
                .frame(width: 16)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(.callout, design: titleDesign, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer(minLength: 8)

            if let refresh {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .scaledFont(size: 13)
                        .frame(width: 17, height: 17)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRefreshDisabled)
                .help(refreshHelp ?? "Refresh")
            }
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: 17)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            .quaternary.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

extension View {
    func inspectorListCard() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .quaternary.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}

struct InspectorPanelView: View {
    let gitStore: GitCommitStore
    let tasksStore: GitHubTasksStore
    let usageStore: UsageStore
    @Binding var selectedTab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabSelector(selection: $selectedTab)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            // Expand the tab content to fill the inspector's height. Without
            // this, an intrinsically-sized tab (e.g. an empty-state
            // ContentUnavailableView) lets the whole VStack shrink and float
            // to the vertical center, dragging the picker mid-pane.
            Group {
                switch selectedTab {
                case .actions:
                    ActionsListView(store: gitStore)
                case .tasks:
                    GitHubTasksView(store: tasksStore)
                case .commits:
                    CommitListView(store: gitStore)
                case .filesystem:
                    FilesystemListView(store: gitStore)
                case .usage:
                    UsageListView(store: usageStore)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .uiZoomedDynamicType()
    }
}

// MARK: - Filesystem (workspace root project tree)

struct FilesystemListView: View {
    let store: GitCommitStore

    var body: some View {
        if store.filesystem.isEmpty && !store.isLoadingFilesystem {
            ContentUnavailableView("No Files",
                                   systemImage: "folder",
                                   description: Text("Select a workspace with a git repo root path."))
        } else {
            VStack(spacing: 0) {
                if !store.repoPath.isEmpty {
                    rootHeader
                }

                FileSystemOutlineView(entries: store.filesystem, rootPath: store.repoPath)
            }
        }
    }

    private var rootHeader: some View {
        InspectorSectionHeader(
            title: store.repoPath,
            systemImage: "folder",
            titleDesign: .monospaced
        )
    }
}

private struct FileSystemOutlineView: NSViewRepresentable {
    @Environment(\.uiZoom) private var uiZoom

    let entries: [FileSystemEntry]
    let rootPath: String

    func makeCoordinator() -> Coordinator {
        Coordinator(entries: entries, rootPath: rootPath, uiZoom: uiZoom)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let outlineView = ClickableFileSystemOutlineView()
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .none
        outlineView.rowSizeStyle = .small
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 14
        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileSystemColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        context.coordinator.reload(
            outlineView: outlineView,
            entries: entries,
            rootPath: rootPath,
            uiZoom: uiZoom
        )
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let outlineView = nsView.documentView as? NSOutlineView else { return }
        context.coordinator.reload(
            outlineView: outlineView,
            entries: entries,
            rootPath: rootPath,
            uiZoom: uiZoom
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        private var nodes: [FileSystemNode]
        private var expandedIDs: Set<String> = []
        private var rootURL: URL
        private var rowFont: NSFont

        init(entries: [FileSystemEntry], rootPath: String, uiZoom: Double) {
            self.nodes = entries.map(FileSystemNode.init(entry:))
            self.rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            self.rowFont = Self.fileTreeFont(uiZoom: uiZoom)
        }

        func reload(
            outlineView: NSOutlineView,
            entries: [FileSystemEntry],
            rootPath: String,
            uiZoom: Double
        ) {
            let newRootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            if rootURL.path == newRootURL.path {
                captureExpandedIDs(from: outlineView)
            } else {
                expandedIDs.removeAll()
            }
            rootURL = newRootURL
            nodes = entries.map(FileSystemNode.init(entry:))
            rowFont = Self.fileTreeFont(uiZoom: uiZoom)
            outlineView.rowHeight = max(
                20,
                ceil(rowFont.ascender - rowFont.descender + rowFont.leading) + 4
            )
            outlineView.reloadData()
            restoreExpandedNodes(in: outlineView, nodes: nodes)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(for: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(for: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileSystemNode else { return false }
            return node.isExpandable
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? FileSystemNode else { return false }
            loadChildrenIfNeeded(for: node)
            outlineView.reloadItem(node, reloadChildren: true)
            return node.isExpandable
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileSystemNode else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("FileSystemCell")
            let view = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileSystemOutlineCellView)
                ?? FileSystemOutlineCellView()
            view.identifier = identifier
            view.configure(with: node.entry, font: rowFont)
            return view
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileSystemNode else { return }
            expandedIDs.insert(node.entry.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileSystemNode else { return }
            expandedIDs.remove(node.entry.id)
        }

        private func children(for item: Any?) -> [FileSystemNode] {
            guard let node = item as? FileSystemNode else { return nodes }
            return node.children
        }

        private func captureExpandedIDs(from outlineView: NSOutlineView) {
            expandedIDs.removeAll(keepingCapacity: true)

            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileSystemNode,
                      outlineView.isItemExpanded(node) else { continue }
                expandedIDs.insert(node.entry.id)
            }
        }

        private func restoreExpandedNodes(in outlineView: NSOutlineView, nodes: [FileSystemNode]) {
            for node in nodes {
                restoreExpandedNode(node, in: outlineView)
            }
        }

        private func restoreExpandedNode(_ node: FileSystemNode, in outlineView: NSOutlineView) {
            guard node.entry.isDirectory else { return }

            if expandedIDs.contains(node.entry.id) {
                loadChildrenIfNeeded(for: node)
                outlineView.expandItem(node)
            }

            for child in node.children {
                restoreExpandedNode(child, in: outlineView)
            }
        }

        private func loadChildrenIfNeeded(for node: FileSystemNode) {
            guard node.entry.isDirectory, !node.hasLoadedChildren else { return }
            let directoryURL = URL(fileURLWithPath: node.entry.path, isDirectory: true)
            let entries = GitCommitStore.listFilesystemEntries(at: directoryURL, rootURL: rootURL)
            node.children = entries.map(FileSystemNode.init(entry:))
            node.hasLoadedChildren = true
        }

        private static func fileTreeFont(uiZoom: Double) -> NSFont {
            let preferredFont = NSFont.preferredFont(forTextStyle: .callout)
            return NSFontManager.shared.convert(
                preferredFont,
                toSize: preferredFont.pointSize * CGFloat(uiZoom)
            )
        }
    }
}

/// `NSOutlineView` only expands a row when its small disclosure control is
/// clicked. The filesystem deliberately disables selection, so make the rest
/// of a folder row behave like that disclosure control as well.
private final class ClickableFileSystemOutlineView: NSOutlineView {
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: location)
        let clickedDisclosure = clickedRow >= 0
            && frameOfOutlineCell(atRow: clickedRow).contains(location)

        // Preserve AppKit's native disclosure-button behavior and normal
        // handling for files, blank space, and multi-click gestures.
        super.mouseDown(with: event)

        guard event.clickCount == 1,
              clickedRow >= 0,
              !clickedDisclosure,
              let node = item(atRow: clickedRow) as? FileSystemNode,
              node.entry.isDirectory else { return }

        if isItemExpanded(node) {
            collapseItem(node)
        } else {
            expandItem(node)
        }
    }
}

private final class FileSystemNode: NSObject {
    let entry: FileSystemEntry
    var children: [FileSystemNode]
    var hasLoadedChildren: Bool

    var isExpandable: Bool {
        entry.isDirectory && (!hasLoadedChildren || !children.isEmpty)
    }

    init(entry: FileSystemEntry) {
        self.entry = entry
        self.children = (entry.children ?? []).map(FileSystemNode.init(entry:))
        self.hasLoadedChildren = entry.children != nil
    }
}

private final class FileSystemOutlineCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

        titleField.font = .preferredFont(forTextStyle: .callout)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleField)

        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])

        imageView = iconView
        textField = titleField
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(with entry: FileSystemEntry, font: NSFont) {
        titleField.stringValue = entry.name
        titleField.font = font
        toolTip = entry.relativePath
        iconView.image = fileIcon(for: entry.path)
    }

    private func fileIcon(for path: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

// MARK: - Commits (local git log)

struct CommitListView: View {
    let store: GitCommitStore

    var body: some View {
        VStack(spacing: 0) {
            RepositoryTableHeader(
                title: store.activeBranchDisplayName,
                systemImage: "arrow.triangle.branch",
                refreshHelp: "Refresh commits",
                isRefreshDisabled: store.repoPath.isEmpty
            ) {
                store.fetchCommits(policy: .manual)
            }

            if store.commits.isEmpty && !store.isLoading {
                ContentUnavailableView("No Commits",
                                       systemImage: "clock.arrow.circlepath",
                                       description: Text("Select a workspace with a git repo root path."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.commits) { commit in
                            commitRow(commit)
                                .inspectorListCard()
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        HStack(alignment: .top, spacing: 8) {
            commitIcon
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(commit.message)
                    .font(.callout)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text(commit.id)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.subheadline)
                        .foregroundStyle(.quaternary)
                    Text(commit.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.subheadline)
                        .foregroundStyle(.quaternary)
                    Text(commit.date)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var commitIcon: some View {
        Image(systemName: "circle")
            .scaledFont(size: 12)
            .foregroundStyle(.blue)
    }
}

// MARK: - Actions (GitHub Actions workflow runs)

struct ActionsListView: View {
    let store: GitCommitStore

    var body: some View {
        VStack(spacing: 0) {
            RepositoryTableHeader(
                title: store.repositoryName,
                systemImage: "folder",
                refreshHelp: "Refresh actions",
                isRefreshDisabled: store.repoPath.isEmpty
            ) {
                store.fetchWorkflowRuns(policy: .manual)
            }

            if store.actions.isEmpty && !store.isLoading {
                ContentUnavailableView("No Actions",
                                       systemImage: "gearshape.2",
                                       description: Text("Select a workspace with a GitHub repo root path."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.actions) { action in
                            actionRow(action)
                                .inspectorListCard()
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func actionRow(_ action: GitAction) -> some View {
        Button {
            openActionInBrowser(action)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                actionStatusIcon(action.conclusion, status: action.status)
                    .frame(width: 14)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.displayTitle)
                        .font(.callout)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        Text(action.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.subheadline)
                            .foregroundStyle(.quaternary)
                        Text(action.headBranch)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Text(String(action.headSha.prefix(7)))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        if !action.elapsed.isEmpty {
                            Text("·")
                                .font(.subheadline)
                                .foregroundStyle(.quaternary)
                            Text(action.elapsed)
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action.url.isEmpty)
        .help(action.url.isEmpty ? "" : "Open on GitHub")
    }

    private func openActionInBrowser(_ action: GitAction) {
        guard let url = URL(string: action.url) else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func actionStatusIcon(_ conclusion: String, status: String) -> some View {
        switch conclusion {
        case "success":
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(.green)
        case "failure":
            Image(systemName: "xmark.circle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(.red)
        case "cancelled":
            Image(systemName: "slash.circle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
        default:
            switch status {
            case "in_progress":
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.orange)
                    .colorMultiply(.orange)
            case "queued", "waiting", "pending":
                Image(systemName: "clock.circle")
                    .scaledFont(size: 12)
                    .foregroundStyle(.yellow)
            default:
                Image(systemName: "circle")
                    .scaledFont(size: 12)
                    .foregroundStyle(.quaternary)
            }
        }
    }
}

private struct RepositoryTableHeader: View {
    let title: String
    let systemImage: String
    let refreshHelp: String
    let isRefreshDisabled: Bool
    let refresh: () -> Void

    var body: some View {
        InspectorSectionHeader(
            title: title,
            systemImage: systemImage,
            refreshHelp: refreshHelp,
            isRefreshDisabled: isRefreshDisabled,
            refresh: refresh
        )
    }
}
