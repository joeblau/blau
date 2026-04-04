import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

struct VolumeScrollListView<Item: Identifiable, RowContent: View>: View {
    let items: [Item]
    @Binding var selectedID: Item.ID?
    var onHighlightChanged: ((Item) -> Void)?
    var onFirstEvent: (() -> Void)?
    var onVolumeHoldStart: (() -> Void)?
    var onVolumeHoldEnd: (() -> Void)?
    @ViewBuilder let rowContent: (Item, Bool) -> RowContent

    @State private var volumeObserver = VolumeObserver()

    private var highlightedIndex: Int? {
        guard let selectedID else { return nil }
        return items.firstIndex(where: { $0.id == selectedID })
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section("Workspaces") {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        rowContent(item, item.id == selectedID)
                            .listRowBackground(
                                item.id == selectedID
                                    ? Color.accentColor.opacity(0.2)
                                    : nil
                            )
                            .id(index)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                VolumeHiderView { volumeView in
                    volumeObserver.attach(volumeView: volumeView)
                }
            }
            .onChange(of: volumeObserver.eventID) {
                guard !items.isEmpty else { return }
                let currentIndex = highlightedIndex ?? 0
                let newIndex = nextIndex(
                    from: currentIndex,
                    direction: volumeObserver.direction,
                    itemCount: items.count
                )
                selectedID = items[newIndex].id
                onHighlightChanged?(items[newIndex])
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onChange(of: selectedID) {
                guard let highlightedIndex else { return }
                withAnimation {
                    proxy.scrollTo(highlightedIndex, anchor: .center)
                }
            }
        }
        .onAppear {
            volumeObserver.onFirstEvent = onFirstEvent
            volumeObserver.onHoldStart = onVolumeHoldStart
            volumeObserver.onHoldEnd = onVolumeHoldEnd
            volumeObserver.start()
        }
        .onDisappear { volumeObserver.stop() }
    }

    private func nextIndex(
        from current: Int,
        direction: VolumeDirection,
        itemCount: Int
    ) -> Int {
        switch direction {
        case .up:
            return max(current - 1, 0)
        case .down:
            return min(current + 1, itemCount - 1)
        case .none:
            return current
        }
    }
}

// MARK: - Volume Observer

enum VolumeDirection {
    case none, up, down
}

// Volume-button PTT (push-to-talk) state machine:
//
//   IDLE ──(2+ rapid events)──▶ HOLDING ──(opposite button)──▶ IDLE
//    │                              │
//    │ (single event + 800ms)       │ (stop() from view lifecycle)
//    ▼                              ▼
//   TAP (navigate)             END HOLD (fire onHoldEnd)
//
// iOS volume buttons produce "volume changed" KVO events.  There is
// NO "button released" event.  When the user holds a button, auto-repeat
// fires until volume hits 0 or 1, then stops.
//
// The hold is PERMANENT once detected.  It ends ONLY when:
//   - The user presses the OPPOSITE volume button, OR
//   - The view disappears (stop() called by onDisappear)
//
// Volume is NEVER reset to midpoint during or immediately after a hold.
// Any programmatic volume change while the user is holding a hardware
// button restarts iOS auto-repeat, creating a start/stop cycle.
// The midpoint reset happens only after a single-tap navigation.

@MainActor
@Observable
final class VolumeObserver {
    var direction: VolumeDirection = .none
    var eventID: Int = 0
    private(set) var isVolumeHeld = false

    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?

    private var cancellable: AnyCancellable?
    private var previousVolume: Float?
    private var pendingProgrammaticVolume: Float?
    private var resetTask: Task<Void, Never>?
    private var holdReleaseTask: Task<Void, Never>?
    private weak var volumeView: MPVolumeView?
    private let session = AVAudioSession.sharedInstance()
    private let midpointVolume: Float = 0.5

    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private var holdEventCount = 0
    private var pendingDirection: VolumeDirection = .none
    private var holdDirection: VolumeDirection = .none

    /// Called on first volume event to capture state before hold detection.
    var onFirstEvent: (() -> Void)?

    func attach(volumeView: MPVolumeView) {
        guard self.volumeView !== volumeView else { return }
        self.volumeView = volumeView

        // NEVER reset volume if a hold is active.  The programmatic change
        // would restart iOS auto-repeat and cause the hold to cycle.
        guard !isVolumeHeld else { return }

        guard cancellable != nil else {
            previousVolume = session.outputVolume
            return
        }

        setVolumeMidpoint()
    }

    func start() {
        guard cancellable == nil else { return }

        try? session.setActive(true)
        previousVolume = session.outputVolume

        // Only reset to midpoint if no hold is active.
        if !isVolumeHeld {
            setVolumeMidpoint()
        }

        cancellable = session.publisher(for: \.outputVolume)
            .sink { @Sendable [weak self] newVolume in
                Task { @MainActor [weak self] in
                    self?.handleVolumeChange(newVolume)
                }
            }
    }

    private func handleVolumeChange(_ newVolume: Float) {
        // Skip programmatic volume changes (from setVolumeMidpoint).
        if let pendingVolume = pendingProgrammaticVolume {
            pendingProgrammaticVolume = nil
            if abs(newVolume - pendingVolume) < 0.001 {
                previousVolume = newVolume
                return
            }
        }

        guard let prev = previousVolume else {
            previousVolume = newVolume
            return
        }

        if newVolume > prev {
            publish(.up)
        } else if newVolume < prev {
            publish(.down)
        } else {
            previousVolume = newVolume
            return
        }

        previousVolume = newVolume
    }

    private func publish(_ direction: VolumeDirection) {
        // If a hold is active and the user presses the OPPOSITE direction,
        // that is the explicit stop signal.
        if isVolumeHeld && direction != holdDirection {
            isVolumeHeld = false
            holdEventCount = 0
            holdDirection = .none
            haptic.impactOccurred()
            onHoldEnd?()
            // Do NOT reset volume here.  The user just pressed a button,
            // which means volume is changing.  Let it settle, then the
            // next single-tap will trigger a midpoint reset.
            return
        }

        // If a hold is active and same direction, absorb the event.
        // No action needed — the hold persists.
        if isVolumeHeld {
            return
        }

        holdEventCount += 1
        pendingDirection = direction

        if holdEventCount == 1 {
            onFirstEvent?()
        }

        if holdEventCount >= 2 {
            // Auto-repeat detected — this is a hold.
            isVolumeHeld = true
            holdDirection = direction
            holdReleaseTask?.cancel()
            holdReleaseTask = nil
            haptic.impactOccurred()
            onHoldStart?()
            return
        }

        // Single event so far.  Start tap timer.
        holdReleaseTask?.cancel()
        holdReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            // No hold detected.  Single tap — navigate.
            self.direction = self.pendingDirection
            self.eventID += 1
            self.holdEventCount = 0
            self.haptic.impactOccurred()
            self.scheduleMidpointReset()
        }
    }

    private func scheduleMidpointReset() {
        resetTask?.cancel()
        // NEVER reset volume during a hold.
        guard !isVolumeHeld else { return }
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            guard !self.isVolumeHeld else { return }
            self.setVolumeMidpoint()
        }
    }

    private func setVolumeMidpoint() {
        // Triple-check: never during a hold.
        guard !isVolumeHeld else { return }

        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else {
            return
        }

        guard abs(session.outputVolume - midpointVolume) >= 0.001 else {
            previousVolume = session.outputVolume
            pendingProgrammaticVolume = nil
            return
        }

        pendingProgrammaticVolume = midpointVolume
        previousVolume = midpointVolume
        slider.setValue(midpointVolume, animated: false)
        slider.sendActions(for: .valueChanged)
    }

    func stop() {
        cancellable?.cancel()
        resetTask?.cancel()
        holdReleaseTask?.cancel()
        cancellable = nil
        resetTask = nil
        holdReleaseTask = nil
        holdEventCount = 0
        holdDirection = .none
        previousVolume = nil
        pendingProgrammaticVolume = nil
        if isVolumeHeld {
            isVolumeHeld = false
            onHoldEnd?()
        }
    }
}

// MARK: - Hidden volume HUD

/// Places an invisible MPVolumeView to suppress the system volume HUD.
struct VolumeHiderView: UIViewRepresentable {
    let onReady: (MPVolumeView) -> Void

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.alpha = 0.001
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            onReady(view)
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        // Only attach once.  Do NOT call onReady on every SwiftUI
        // re-render — it can trigger setVolumeMidpoint via attach()
        // if the weak reference was temporarily nil'd.
    }
}

private struct PreviewItem: Identifiable {
    let id = UUID()
    let name: String
    var badgeCount: Int = 0
}

#Preview {
    @Previewable @State var selectedID: UUID?
    let items = [
        PreviewItem(name: "Bloxwap", badgeCount: 2),
        PreviewItem(name: "Blau"),
        PreviewItem(name: "Submap"),
        PreviewItem(name: "VeblenHype"),
    ]

    VolumeScrollListView(
        items: items,
        selectedID: $selectedID
    ) { item, isHighlighted in
        HStack {
            Text(item.name)
                .fontWeight(isHighlighted ? .semibold : .regular)
            Spacer()
            if item.badgeCount > 0 {
                Text("\(item.badgeCount)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.red, in: Capsule())
            }
        }
    }
}
