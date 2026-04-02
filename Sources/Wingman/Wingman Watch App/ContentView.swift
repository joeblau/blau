import SwiftUI

struct GestureEvent: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let timestamp: Date
}

struct ContentView: View {
    @State private var currentGesture: String = "Waiting..."
    @State private var currentIcon: String = "hand.raised"
    @State private var gestureHistory: [GestureEvent] = []
    @State private var crownValue: Double = 0.0
    @State private var isCrownFocused: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                gestureDisplay
                    .frame(height: 80)

                Divider()

                if gestureHistory.isEmpty {
                    ContentUnavailableView("No Gestures",
                                           systemImage: "hand.raised",
                                           description: Text("Tap, swipe, long press, or turn the crown."))
                } else {
                    historyList
                }
            }
            .navigationTitle("Wingman")
        }
    }

    // MARK: - Current Gesture Display

    private var gestureDisplay: some View {
        VStack(spacing: 4) {
            Image(systemName: currentIcon)
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .contentTransition(.symbolEffect(.replace))

            Text(currentGesture)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    record("Long Press", icon: "hand.tap")
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let direction = swipeDirection(value)
                    record("Swipe \(direction)", icon: iconForSwipe(direction))
                }
        )
        .onTapGesture(count: 2) {
            record("Double Tap", icon: "hand.tap")
        }
        .onTapGesture {
            record("Tap", icon: "hand.point.up")
        }
        .focusable()
        .digitalCrownRotation($crownValue, from: -100, through: 100, sensitivity: .medium)
        .onChange(of: crownValue) { oldValue, newValue in
            let delta = newValue - oldValue
            if abs(delta) > 2 {
                let direction = delta > 0 ? "Down" : "Up"
                record("Crown \(direction)", icon: "digitalcrown.horizontal.arrow.counterclockwise")
            }
        }
        .handGestureShortcut(.primaryAction)
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

    private func swipeDirection(_ value: DragGesture.Value) -> String {
        let horizontal = value.translation.width
        let vertical = value.translation.height

        if abs(horizontal) > abs(vertical) {
            return horizontal > 0 ? "Right" : "Left"
        } else {
            return vertical > 0 ? "Down" : "Up"
        }
    }

    private func iconForSwipe(_ direction: String) -> String {
        switch direction {
        case "Up": return "arrow.up"
        case "Down": return "arrow.down"
        case "Left": return "arrow.left"
        case "Right": return "arrow.right"
        default: return "arrow.up.and.down"
        }
    }
}

#Preview {
    ContentView()
}
