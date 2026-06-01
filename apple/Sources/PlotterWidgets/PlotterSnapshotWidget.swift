import WidgetKit
import SwiftUI

/// Home/lock-screen widget showing the most recent frame Plotter received from
/// the connected Mac, plus connection status. Static (refreshed on the system
/// budget); the app nudges reloads as new frames arrive.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let imageData: Data?
    let status: PlotterSnapshotStore.Status?
}

struct PlotterSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), imageData: nil, status: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // Fallback refresh; the app calls reloadAllTimelines() when a fresh
        // frame lands, so this is just a safety net.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [currentEntry()], policy: .after(next)))
    }

    private func currentEntry() -> SnapshotEntry {
        SnapshotEntry(
            date: Date(),
            imageData: PlotterSnapshotStore.readImageData(),
            status: PlotterSnapshotStore.readStatus()
        )
    }
}

struct PlotterSnapshotWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PlotterSnapshotWidget", provider: PlotterSnapshotProvider()) { entry in
            PlotterSnapshotView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Plotter Mirror")
        .description("The latest screen from the connected Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PlotterSnapshotView: View {
    let entry: SnapshotEntry

    private var connected: Bool { entry.status?.isConnected ?? false }

    var body: some View {
        ZStack {
            if let data = entry.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ContentUnavailablePlaceholder()
            }

            VStack {
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(connected ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.45))
            }
        }
    }

    private var statusLine: String {
        guard let status = entry.status else { return "Not connected" }
        if status.isConnected {
            return status.title.isEmpty ? "Connected" : status.title
        }
        return "Last seen \(status.updatedAt.formatted(.relative(presentation: .numeric)))"
    }
}

private struct ContentUnavailablePlaceholder: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No mirror yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
