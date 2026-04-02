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

enum InspectorTab: String, CaseIterable {
    case commits = "Commits"
    case runs = "Runs"
}

struct InspectorPanelView: View {
    let gitStore: GitCommitStore
    @State private var selectedTab: InspectorTab = .commits

    var body: some View {
        VStack(spacing: 0) {
            switch selectedTab {
            case .commits:
                CommitListView(store: gitStore)
            case .runs:
                RunsListView(store: gitStore)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                RoundedSegmentedPicker(selection: $selectedTab)
            }
        }
    }
}

// MARK: - Commits (local git log)

struct CommitListView: View {
    let store: GitCommitStore

    var body: some View {
        if store.commits.isEmpty && !store.isLoading {
            ContentUnavailableView("No Commits",
                                   systemImage: "clock.arrow.circlepath",
                                   description: Text("Select an active terminal in a git repo."))
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
            ciIcon(commit.ciStatus)
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

    @ViewBuilder
    private func ciIcon(_ status: GitCommit.CIStatus) -> some View {
        switch status {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        case .pending:
            Image(systemName: "clock.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        case .unknown:
            Image(systemName: "circle")
                .font(.system(size: 12))
                .foregroundStyle(.quaternary)
        }
    }
}

// MARK: - Runs (remote CI from gh)

struct RunsListView: View {
    let store: GitCommitStore

    var body: some View {
        if store.runs.isEmpty && !store.isLoading {
            ContentUnavailableView("No Runs",
                                   systemImage: "server.rack",
                                   description: Text("No CI runs found."))
        } else {
            List(store.runs) { run in
                runRow(run)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
            .listStyle(.plain)
        }
    }

    private func runRow(_ run: GitRun) -> some View {
        HStack(alignment: .top, spacing: 8) {
            runStatusIcon(run.status)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(run.name)
                    .font(.system(size: 11))
                    .lineLimit(1)

                Text(run.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text(run.branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(run.elapsed)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func runStatusIcon(_ status: GitRun.Status) -> some View {
        switch status {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        case .inProgress:
            Image(systemName: "circle.dotted")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        case .queued:
            Image(systemName: "clock.circle")
                .font(.system(size: 12))
                .foregroundStyle(.yellow)
        case .unknown:
            Image(systemName: "circle")
                .font(.system(size: 12))
                .foregroundStyle(.quaternary)
        }
    }
}
