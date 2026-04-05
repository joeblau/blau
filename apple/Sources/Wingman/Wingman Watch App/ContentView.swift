import SwiftUI

struct ContentView: View {
    let sessionDelegate: WatchSessionDelegate
    @State private var currentGesture: String = "Waiting..."
    @State private var currentIcon: String = "hand.raised"

    var body: some View {
        NavigationStack {
            VStack {
                gestureDisplay
                    .frame(maxHeight: .infinity)
            }
            .navigationTitle("Wingman")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(sessionDelegate.isReachable ? .green : .red)
                        .frame(width: 10, height: 10)
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

    // MARK: - Helpers

    private func record(_ name: String, icon: String) {
        currentGesture = name
        currentIcon = icon
    }

    private func triggerDoublePinch(source: String) {
        record("Double Pinch", icon: "hand.pinch")
        sessionDelegate.sendDoublePinch(source: source)
    }
}

#Preview {
    ContentView(sessionDelegate: WatchSessionDelegate())
}
