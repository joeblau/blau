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
    /// True after a midpoint reset during a hold. If the next timer fires
    /// and this is still true (no events arrived), the user released.
    private var awaitingResumeAfterReset = false

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

    private func publish(_ direction: VolumeDirection) {
        awaitingResumeAfterReset = false

        holdEventCount += 1
        pendingDirection = direction

        if holdEventCount == 1 {
            onFirstEvent?()
        }

        if holdEventCount >= 2 && !isVolumeHeld {
            // Auto-repeat detected — this is a hold.
            isVolumeHeld = true
            haptic.impactOccurred()
            onHoldStart?()
        }

        // Reset the release timer on every event.
        holdReleaseTask?.cancel()
        scheduleHoldRelease()
    }

    /// During a hold, when no volume events arrive for 800ms, we cannot
    /// tell if the user released the button or if iOS just stopped
    /// generating events (e.g. volume hit a limit).  The only reliable
    /// release signal: reset volume to midpoint and check whether
    /// auto-repeat events resume.  If they do, still holding.  If not,
    /// the user released.
    private func scheduleHoldRelease() {
        holdReleaseTask?.cancel()
        holdReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            if self.isVolumeHeld {
                if self.awaitingResumeAfterReset {
                    // We already reset to midpoint and waited 800ms.
                    // No events arrived.  The user released.
                    self.awaitingResumeAfterReset = false
                    self.isVolumeHeld = false
                    self.holdEventCount = 0
                    self.haptic.impactOccurred()
                    self.onHoldEnd?()
                    self.scheduleMidpointReset()
                    return
                }
                // First timeout during hold.  Reset to midpoint and
                // wait for auto-repeat to resume.  publish() clears
                // awaitingResumeAfterReset when an event arrives.
                self.setVolumeMidpoint()
                self.awaitingResumeAfterReset = true
                self.scheduleHoldRelease()
            } else {
                // No hold detected. Single tap — navigate.
                self.direction = self.pendingDirection
                self.eventID += 1
                self.holdEventCount = 0
                self.haptic.impactOccurred()
                self.scheduleMidpointReset()
            }
        }
    }

    private func scheduleMidpointReset() {
        resetTask?.cancel()
        // Don't reset volume while detecting or in a hold — the programmatic
        // change can prevent iOS from generating auto-repeat events.
        guard holdEventCount == 0 else { return }
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
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
        slider.sendActions(for: .touchUpInside)
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
        previousVolume = nil
        pendingProgrammaticVolume = nil
        awaitingResumeAfterReset = false
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
