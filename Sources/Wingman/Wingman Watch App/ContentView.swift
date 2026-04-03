import SwiftUI
import WatchConnectivity

struct GestureEvent: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let timestamp: Date
}

struct ContentView: View {
    let sessionDelegate: WatchSessionDelegate
    @State private var currentGesture: String = "Waiting..."
    @State private var currentIcon: String = "hand.raised"
    @State private var gestureHistory: [GestureEvent] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                gestureDisplay
                    .frame(minHeight: 128)

                Divider()

                if gestureHistory.isEmpty {
                    ContentUnavailableView("No Gestures",
                                           systemImage: "hand.raised",
                                           description: Text("Use double pinch or tap Send to Copilot."))
                } else {
                    historyList
                }
            }
            .navigationTitle("Wingman")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(sessionDelegate.isReachable ? .green : .red)
                        .frame(width: 6, height: 6)
                    Text(sessionDelegate.isReachable ? "Copilot Connected" : "Copilot Disconnected")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Current Gesture Display

    private var gestureDisplay: some View {
        VStack(spacing: 4) {
            VStack(spacing: 4) {
                Image(systemName: currentIcon)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))

                Text(currentGesture)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                triggerDoublePinch(source: "button")
            } label: {
                Label("Send to Copilot", systemImage: "hand.pinch.fill")
                    .font(.caption2.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .handGestureShortcut(.primaryAction)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - History

    private var historyList: some View {
        List(gestureHistory) { event in
            HStack(spacing: 8) {
                Image(systemName: event.icon)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(event.name)
                        .font(.caption2)
                    Text(event.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Helpers

    private func record(_ name: String, icon: String) {
        currentGesture = name
        currentIcon = icon
        let event = GestureEvent(name: name, icon: icon, timestamp: Date())
        withAnimation {
            gestureHistory.insert(event, at: 0)
            if gestureHistory.count > 30 {
                gestureHistory.removeLast()
            }
        }
    }

    private func triggerDoublePinch(source: String) {
        record("Double Pinch", icon: "hand.pinch")
        sessionDelegate.sendDoublePinch(source: source)
    }
}

#Preview {
    ContentView(sessionDelegate: WatchSessionDelegate())
}
