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

// Volume-button PTT state machine:
//
//   IDLE ──(1st event)──▶ NAVIGATE ──(2nd event <300ms)──▶ HOLDING
//    ▲                       │                                 │
//    │                 (no 2nd event)                          │
//    │                       │                         (events flow)
//    │                       ▼                                 │
//    │                  reset to mid                           ▼
//    │                                              (2s silence) ──▶ TESTING
//    │                                                                 │
//    │                                              reset to mid ──────┤
//    │                                              events resume:     │
//    │                                              → HOLDING    no events:
//    │                                                           → RELEASED
//    └─────────────────────────────────────────────────────────────────┘
//
// True push-to-talk: hold same button to record, release to stop.
// Release is detected by resetting volume to midpoint and checking
// if auto-repeat resumes.  The hold NEVER ends during testing, it
// stays active.  Only a confirmed release (no events after reset)
// ends the hold.

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
    private var releaseTestTask: Task<Void, Never>?
    private weak var volumeView: MPVolumeView?
    private let session = AVAudioSession.sharedInstance()
    private let midpointVolume: Float = 0.5

    private let tapHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let holdHaptic = UINotificationFeedbackGenerator()
    private var eventCount = 0
    private var lastDirection: VolumeDirection = .none

    /// True while we've reset to midpoint to test if the user released.
    /// Events during this phase are "still holding" signals, not new holds.
    private var isTestingRelease = false

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
        // During a release test: events mean the user is still holding.
        // Cancel the release confirmation and go back to normal holding.
        if isVolumeHeld && isTestingRelease {
            isTestingRelease = false
            releaseTestTask?.cancel()
            // Reschedule the next release test (events will flow until
            // volume hits the limit again, then 2s silence triggers test).
            scheduleReleaseTest()
            return
        }

        // Hold active (not testing): absorb events, reset release timer.
        if isVolumeHeld {
            scheduleReleaseTest()
            return
        }

        // Not in a hold. Normal tap/hold detection.
        eventCount += 1

        if eventCount == 1 {
            onFirstEvent?()
            lastDirection = dir

            // Don't navigate yet. Wait 150ms to distinguish tap from hold.
            // If a 2nd event arrives (hold), skip navigation entirely.
            // If no 2nd event (tap), navigate then.
            holdDetectTask?.cancel()
            holdDetectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                // Single tap confirmed. Navigate now.
                self.direction = dir
                self.eventID += 1
                self.tapHaptic.impactOccurred()
                self.eventCount = 0
                self.scheduleMidpointReset()
            }
            return
        }

        // 2nd event within 150ms: this is a hold.
        holdDetectTask?.cancel()
        holdDetectTask = nil
        isVolumeHeld = true
        holdHaptic.notificationOccurred(.success)
        onHoldStart?()
        scheduleReleaseTest()
    }

    /// After 2 seconds of silence during a hold, test if the user released
    /// by resetting volume to midpoint and checking for resumed events.
    private func scheduleReleaseTest() {
        releaseTestTask?.cancel()
        releaseTestTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.isVolumeHeld else { return }

            // No events for 2 seconds. Reset to midpoint to test release.
            self.isTestingRelease = true
            self.setVolumeMidpointForTest()

            // Wait 1 second for events to resume.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            if self.isTestingRelease {
                // No events arrived after reset. User released.
                self.isTestingRelease = false
                self.isVolumeHeld = false
                self.eventCount = 0
                self.holdHaptic.notificationOccurred(.warning)
                self.onHoldEnd?()
                self.scheduleMidpointReset()
            }
            // If isTestingRelease was cleared by publish(), user is still
            // holding and scheduleReleaseTest was already called.
        }
    }

    /// Reset volume to midpoint during a release test. Unlike the normal
    /// setVolumeMidpoint(), this is allowed during a hold because we need
    /// to probe whether the user is still pressing the button.
    private func setVolumeMidpointForTest() {
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

    private func scheduleMidpointReset() {
        resetTask?.cancel()
        guard !isVolumeHeld else { return }
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
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
        releaseTestTask?.cancel()
        cancellable = nil
        resetTask = nil
        holdDetectTask = nil
        releaseTestTask = nil
        eventCount = 0
        isTestingRelease = false
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
