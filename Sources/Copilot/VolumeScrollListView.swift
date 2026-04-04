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

    func attach(volumeView: MPVolumeView) {
        guard self.volumeView !== volumeView else { return }
        self.volumeView = volumeView

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
        setVolumeMidpoint()

        cancellable = session.publisher(for: \.outputVolume)
            .sink { @Sendable [weak self] newVolume in
                Task { @MainActor [weak self] in
                    self?.handleVolumeChange(newVolume)
                }
            }
    }

    private func handleVolumeChange(_ newVolume: Float) {
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

    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private var holdEventCount = 0
    private var pendingDirection: VolumeDirection = .none
    private var tapConfirmTask: Task<Void, Never>?

    /// Called on first volume event to capture state before hold detection.
    var onFirstEvent: (() -> Void)?

    // Hold detection:
    //
    // iOS volume buttons produce "volume changed" KVO events but NO
    // "button released" event.  When the user holds a button:
    //   1. Auto-repeat fires (~150ms) moving volume toward 0 or 1.
    //   2. At the limit, events stop.  User may still be holding.
    //
    // We CANNOT detect release.  Any approach that resets volume to
    // midpoint (during or after a hold) will restart auto-repeat if
    // the user is still holding, creating a start-stop cycle.
    //
    // Solution: the hold is PERMANENT once started.  It ends only when
    // the user presses the OPPOSITE volume button, which produces an
    // unambiguous direction-change event.  Hold volume-down to start
    // recording, press volume-up to stop (or vice versa).
    //
    // After the hold ends, volume resets to midpoint for future taps.

    /// Direction that started the current hold.
    private var holdDirection: VolumeDirection = .none

    private func publish(_ direction: VolumeDirection) {
        // If a hold is active and the user presses the OPPOSITE direction,
        // that's the stop signal.  End the hold immediately.
        if isVolumeHeld && direction != holdDirection {
            endHold()
            return
        }

        holdEventCount += 1
        pendingDirection = direction

        if holdEventCount == 1 {
            onFirstEvent?()
        }

        if holdEventCount >= 2 && !isVolumeHeld {
            // Auto-repeat detected — this is a hold.
            isVolumeHeld = true
            holdDirection = direction
            haptic.impactOccurred()
            onHoldStart?()
        }

        if !isVolumeHeld {
            // Not yet a hold. Use the tap/hold detection timer.
            holdReleaseTask?.cancel()
            holdReleaseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, !Task.isCancelled else { return }
                // No hold detected. Single tap — navigate.
                self.direction = self.pendingDirection
                self.eventID += 1
                self.holdEventCount = 0
                self.haptic.impactOccurred()
                self.scheduleMidpointReset()
            }
        }
    }

    private func endHold() {
        guard isVolumeHeld else { return }
        isVolumeHeld = false
        holdEventCount = 0
        holdDirection = .none
        haptic.impactOccurred()
        onHoldEnd?()
        scheduleMidpointReset()
    }

    private func scheduleMidpointReset() {
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.setVolumeMidpoint()
        }
    }

    private func setVolumeMidpoint() {
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
        tapConfirmTask?.cancel()
        cancellable = nil
        resetTask = nil
        holdReleaseTask = nil
        tapConfirmTask = nil
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
        DispatchQueue.main.async {
            onReady(uiView)
        }
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
