import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

struct VolumeScrollSection<Item: Identifiable>: Identifiable {
    let id: String
    let title: String?
    let items: [Item]
}

struct VolumeScrollListView<Item: Identifiable, RowContent: View>: View {
    let sections: [VolumeScrollSection<Item>]
    @Binding var selectedID: Item.ID?
    var onHighlightChanged: ((Item) -> Void)?
    var onFirstEvent: (() -> Void)?
    var onVolumeHoldStart: (() -> Void)?
    var onVolumeHoldEnd: (() -> Void)?
    @ViewBuilder let rowContent: (Item, Bool) -> RowContent

    @State private var volumeObserver = VolumeObserver()

    init(
        items: [Item],
        selectedID: Binding<Item.ID?>,
        onHighlightChanged: ((Item) -> Void)? = nil,
        onFirstEvent: (() -> Void)? = nil,
        onVolumeHoldStart: (() -> Void)? = nil,
        onVolumeHoldEnd: (() -> Void)? = nil,
        @ViewBuilder rowContent: @escaping (Item, Bool) -> RowContent
    ) {
        self.sections = [
            VolumeScrollSection(id: "workspaces", title: "Workspaces", items: items)
        ]
        self._selectedID = selectedID
        self.onHighlightChanged = onHighlightChanged
        self.onFirstEvent = onFirstEvent
        self.onVolumeHoldStart = onVolumeHoldStart
        self.onVolumeHoldEnd = onVolumeHoldEnd
        self.rowContent = rowContent
    }

    init(
        sections: [VolumeScrollSection<Item>],
        selectedID: Binding<Item.ID?>,
        onHighlightChanged: ((Item) -> Void)? = nil,
        onFirstEvent: (() -> Void)? = nil,
        onVolumeHoldStart: (() -> Void)? = nil,
        onVolumeHoldEnd: (() -> Void)? = nil,
        @ViewBuilder rowContent: @escaping (Item, Bool) -> RowContent
    ) {
        self.sections = sections
        self._selectedID = selectedID
        self.onHighlightChanged = onHighlightChanged
        self.onFirstEvent = onFirstEvent
        self.onVolumeHoldStart = onVolumeHoldStart
        self.onVolumeHoldEnd = onVolumeHoldEnd
        self.rowContent = rowContent
    }

    private var items: [Item] {
        sections.flatMap(\.items)
    }

    private var highlightedIndex: Int? {
        guard let selectedID else { return nil }
        return items.firstIndex(where: { $0.id == selectedID })
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(sections) { section in
                    sectionContent(section)
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
                    proxy.scrollTo(items[newIndex].id, anchor: .center)
                }
            }
            .onChange(of: selectedID) {
                guard let selectedID else { return }
                withAnimation {
                    proxy.scrollTo(selectedID, anchor: .center)
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

    @ViewBuilder
    private func sectionContent(_ section: VolumeScrollSection<Item>) -> some View {
        if let title = section.title {
            Section(title) {
                rows(for: section.items)
            }
        } else {
            rows(for: section.items)
        }
    }

    @ViewBuilder
    private func rows(for sectionItems: [Item]) -> some View {
        ForEach(sectionItems) { item in
            rowContent(item, item.id == selectedID)
                .listRowBackground(
                    item.id == selectedID
                        ? Color.accentColor.opacity(0.2)
                        : nil
                )
                .id(item.id)
        }
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

// Volume-button state machine:
//
//   IDLE ──(event)──▶ NAVIGATE ──(rapid 2nd event)──▶ HOLDING
//    ▲                    │                               │
//    │                    │ (no 2nd event within 300ms)   │
//    │                    ▼                               │
//    │               RESET TO MID                        │
//    │                                                    │
//    └──────────(opposite button or stop())───────────────┘
//
// Single tap: navigates immediately, resets volume to midpoint after.
// Hold (2+ rapid events): starts recording. Ends on opposite button.
// Volume is NEVER reset during a hold (causes cycling).

@MainActor
@Observable
final class VolumeObserver {
    var direction: VolumeDirection = .none
    var eventID: Int = 0
    private(set) var isVolumeHeld = false

    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var onFirstEvent: (() -> Void)?

    private var cancellable: AnyCancellable?
    private var previousVolume: Float?
    private var pendingProgrammaticVolume: Float?
    private var resetTask: Task<Void, Never>?
    private var holdDetectTask: Task<Void, Never>?
    private weak var volumeView: MPVolumeView?
    private let session = AVAudioSession.sharedInstance()
    private let midpointVolume: Float = 0.5

    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private var eventCount = 0
    private var lastDirection: VolumeDirection = .none
    private var holdDirection: VolumeDirection = .none

    func attach(volumeView: MPVolumeView) {
        guard self.volumeView !== volumeView else { return }
        self.volumeView = volumeView
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
        if !isVolumeHeld { setVolumeMidpoint() }

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

    private func publish(_ dir: VolumeDirection) {
        // Hold active: opposite direction ends it.
        if isVolumeHeld {
            if dir != holdDirection {
                isVolumeHeld = false
                eventCount = 0
                holdDirection = .none
                haptic.impactOccurred()
                onHoldEnd?()
                // Schedule midpoint reset after hold ends.  Delay long enough
                // for the user to lift their finger so iOS won't auto-repeat
                // from the new midpoint.
                scheduleMidpointReset(delay: 2.0)
            }
            // Same direction during hold: absorb silently.
            return
        }

        eventCount += 1

        if eventCount == 1 {
            onFirstEvent?()
            lastDirection = dir

            // Navigate immediately on first event — no 800ms delay.
            direction = dir
            eventID += 1
            haptic.impactOccurred()

            // Start hold detection window: if a second event arrives
            // within 300ms, this is a hold, not a tap.
            holdDetectTask?.cancel()
            holdDetectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                // No second event arrived — this was a single tap.
                self.eventCount = 0
                self.scheduleMidpointReset(delay: 0.3)
            }
            return
        }

        // Second+ event within 300ms — this is a hold.
        holdDetectTask?.cancel()
        holdDetectTask = nil
        isVolumeHeld = true
        holdDirection = lastDirection
        haptic.impactOccurred()
        onHoldStart?()
    }

    private func scheduleMidpointReset(delay: TimeInterval) {
        resetTask?.cancel()
        guard !isVolumeHeld else { return }
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard !self.isVolumeHeld else { return }
            self.setVolumeMidpoint()
        }
    }

    private func setVolumeMidpoint() {
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
        holdDetectTask?.cancel()
        cancellable = nil
        resetTask = nil
        holdDetectTask = nil
        eventCount = 0
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
