import AppKit
import SwiftUI

struct RoundedSegmentedPicker: NSViewRepresentable {
    @Binding var selection: InspectorTab

    func makeNSView(context: Context) -> NSSegmentedControl {
        let segmentedControl = NSSegmentedControl(
            labels: InspectorTab.allCases.map(\.rawValue),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        segmentedControl.segmentStyle = .rounded
        segmentedControl.selectedSegment = InspectorTab.allCases.firstIndex(of: selection) ?? 0
        return segmentedControl
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        nsView.selectedSegment = InspectorTab.allCases.firstIndex(of: selection) ?? 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    class Coordinator: NSObject {
        var selection: Binding<InspectorTab>

        init(selection: Binding<InspectorTab>) {
            self.selection = selection
        }

        @MainActor @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            if index >= 0, index < InspectorTab.allCases.count {
                selection.wrappedValue = InspectorTab.allCases[index]
            }
        }
    }
}

struct InspectorPanelView: View {
    let gitStore: GitCommitStore
    @Binding var selectedTab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            switch selectedTab {
            case .actions:
                ActionsListView(store: gitStore)
            case .commits:
                CommitListView(store: gitStore)
            case .filesystem:
                FilesystemListView(store: gitStore)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                RoundedSegmentedPicker(selection: $selectedTab)
            }
        }
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
        VStack(alignment: .leading, spacing: 2) {
            Label(rootName, systemImage: "folder.fill")
                .font(.system(size: 11, weight: .semibold))

            Text(store.repoPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .padding(.bottom, 4)
    }

    private var rootName: String {
        let name = URL(fileURLWithPath: store.repoPath).lastPathComponent
        return name.isEmpty ? store.repoPath : name
    }
}

private struct FileSystemOutlineView: NSViewRepresentable {
    let entries: [FileSystemEntry]
    let rootPath: String

    func makeCoordinator() -> Coordinator {
        Coordinator(entries: entries, rootPath: rootPath)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let outlineView = NSOutlineView()
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
        context.coordinator.reload(outlineView: outlineView, entries: entries, rootPath: rootPath)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let outlineView = nsView.documentView as? NSOutlineView else { return }
        context.coordinator.reload(outlineView: outlineView, entries: entries, rootPath: rootPath)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        private var nodes: [FileSystemNode]
        private var expandedIDs: Set<String> = []
        private var rootURL: URL

        init(entries: [FileSystemEntry], rootPath: String) {
            self.nodes = entries.map(FileSystemNode.init(entry:))
            self.rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        }

        func reload(outlineView: NSOutlineView, entries: [FileSystemEntry], rootPath: String) {
            let newRootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            if rootURL.path == newRootURL.path {
                captureExpandedIDs(from: outlineView)
            } else {
                expandedIDs.removeAll()
            }
            rootURL = newRootURL
            nodes = entries.map(FileSystemNode.init(entry:))
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
            view.configure(with: node.entry)
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

        titleField.font = .systemFont(ofSize: 11)
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

    func configure(with entry: FileSystemEntry) {
        titleField.stringValue = entry.name
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
        if store.commits.isEmpty && !store.isLoading {
            ContentUnavailableView("No Commits",
                                   systemImage: "clock.arrow.circlepath",
                                   description: Text("Select a workspace with a git repo root path."))
        } else {
            List(store.commits) { commit in
                commitRow(commit)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
            .listStyle(.plain)
        }
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        HStack(alignment: .top, spacing: 8) {
            commitIcon
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(commit.message)
                    .font(.system(size: 11))
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text(commit.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(commit.author)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(commit.date)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var commitIcon: some View {
        Image(systemName: "circle")
            .font(.system(size: 12))
            .foregroundStyle(.blue)
    }
}

// MARK: - Actions (GitHub Actions workflow runs)

struct ActionsListView: View {
    let store: GitCommitStore

    var body: some View {
        if store.actions.isEmpty && !store.isLoading {
            ContentUnavailableView("No Actions",
                                   systemImage: "gearshape.2",
                                   description: Text("Select a workspace with a GitHub repo root path."))
        } else {
            List(store.actions) { action in
                actionRow(action)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
            .listStyle(.plain)
        }
    }

    private func actionRow(_ action: GitAction) -> some View {
        HStack(alignment: .top, spacing: 8) {
            actionStatusIcon(action.conclusion, status: action.status)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayTitle)
                    .font(.system(size: 11))
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text(action.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(action.headBranch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text(String(action.headSha.prefix(7)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func actionStatusIcon(_ conclusion: String, status: String) -> some View {
        switch conclusion {
        case "success":
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case "failure":
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        case "cancelled":
            Image(systemName: "slash.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        default:
            switch status {
            case "in_progress":
                Image(systemName: "circle.dotted")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            case "queued", "waiting", "pending":
                Image(systemName: "clock.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
            default:
                Image(systemName: "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.quaternary)
            }
        }
    }
}
