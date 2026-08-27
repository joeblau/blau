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
    var onVolumeHoldStart: ((VolumeDirection) -> Void)?
    var onVolumeHoldEnd: ((VolumeDirection) -> Void)?
    /// Incrementing this from the parent re-arms volume observation. Used
    /// after a recording cycle, whose `transcription.stop()` deactivates the
    /// shared audio session and would otherwise kill button detection.
    var rearmToken: Int = 0
    @ViewBuilder let rowContent: (Item, Bool) -> RowContent

    @State private var volumeObserver = VolumeObserver()

    init(
        items: [Item],
        selectedID: Binding<Item.ID?>,
        onHighlightChanged: ((Item) -> Void)? = nil,
        onVolumeHoldStart: ((VolumeDirection) -> Void)? = nil,
        onVolumeHoldEnd: ((VolumeDirection) -> Void)? = nil,
        rearmToken: Int = 0,
        @ViewBuilder rowContent: @escaping (Item, Bool) -> RowContent
    ) {
        self.sections = [
            VolumeScrollSection(id: "workspaces", title: "Workspaces", items: items)
        ]
        self._selectedID = selectedID
        self.onHighlightChanged = onHighlightChanged
        self.onVolumeHoldStart = onVolumeHoldStart
        self.onVolumeHoldEnd = onVolumeHoldEnd
        self.rearmToken = rearmToken
        self.rowContent = rowContent
    }

    init(
        sections: [VolumeScrollSection<Item>],
        selectedID: Binding<Item.ID?>,
        onHighlightChanged: ((Item) -> Void)? = nil,
        onVolumeHoldStart: ((VolumeDirection) -> Void)? = nil,
        onVolumeHoldEnd: ((VolumeDirection) -> Void)? = nil,
        rearmToken: Int = 0,
        @ViewBuilder rowContent: @escaping (Item, Bool) -> RowContent
    ) {
        self.sections = sections
        self._selectedID = selectedID
        self.onHighlightChanged = onHighlightChanged
        self.onVolumeHoldStart = onVolumeHoldStart
        self.onVolumeHoldEnd = onVolumeHoldEnd
        self.rearmToken = rearmToken
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
            .onChange(of: volumeObserver.tapEventID) {
                let directions = volumeObserver.consumeTapDirections()
                guard !items.isEmpty else { return }
                var currentIndex = highlightedIndex
                for direction in directions {
                    guard let newIndex = VolumeListNavigation.nextIndex(
                        from: currentIndex,
                        direction: direction,
                        itemCount: items.count
                    ) else { continue }
                    currentIndex = newIndex
                    selectedID = items[newIndex].id
                    onHighlightChanged?(items[newIndex])
                    withAnimation {
                        proxy.scrollTo(items[newIndex].id, anchor: .center)
                    }
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
            volumeObserver.onHoldStart = onVolumeHoldStart
            volumeObserver.onHoldEnd = onVolumeHoldEnd
            volumeObserver.start()
        }
        .onDisappear { volumeObserver.stop() }
        .onChange(of: rearmToken) {
            volumeObserver.rearm()
        }
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
}

enum VolumeListNavigation {
    static func nextIndex(
        from current: Int?,
        direction: VolumeDirection,
        itemCount: Int
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        guard let current else { return 0 }
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

enum VolumeDirection: Equatable, Sendable {
    case none, up, down
}

enum VolumeGestureEvent: Equatable, Sendable {
    case tap(VolumeDirection)
    case holdStarted(VolumeDirection)
    case holdRepeated(VolumeDirection)
    case holdEnded(VolumeDirection)
}

/// Separates taps from iOS hardware-key auto-repeat without treating an
/// ordinary double tap as a hold. A hold requires the observed three-event
/// cadence: initial press, delayed first repeat, then a faster repeat in the
/// same direction. Opposite-direction or too-fast events remain taps.
struct VolumeGestureClassifier: Sendable {
    private struct PendingPresses: Sendable {
        let token: Int
        let direction: VolumeDirection
        let firstEventAt: ContinuousClock.Instant
        let lastEventAt: ContinuousClock.Instant
        let count: Int
    }

    /// Confirmed on supported hardware: the first repeat arrives around
    /// 400 ms after key-down. The range leaves scheduling headroom while
    /// excluding the usual cadence of deliberate rapid taps.
    static let minimumInitialRepeatDelay: Duration = .milliseconds(250)
    static let maximumInitialRepeatDelay: Duration = .milliseconds(500)
    /// Once auto-repeat begins, subsequent events arrive much faster.
    static let minimumRepeatDelay: Duration = .milliseconds(40)
    static let maximumRepeatDelay: Duration = .milliseconds(250)

    private var pending: PendingPresses?
    private var nextToken = 0
    private(set) var heldDirection: VolumeDirection = .none

    var isHolding: Bool { heldDirection != .none }

    var pendingResolution: (token: Int, deadline: ContinuousClock.Instant)? {
        guard let pending else { return nil }
        let delay = pending.count == 1
            ? Self.maximumInitialRepeatDelay
            : Self.maximumRepeatDelay
        return (pending.token, pending.lastEventAt.advanced(by: delay))
    }

    mutating func receive(
        _ direction: VolumeDirection,
        at instant: ContinuousClock.Instant
    ) -> [VolumeGestureEvent] {
        guard direction != .none else { return [] }

        if isHolding {
            // Lock the action to the direction that established the hold.
            // Route/category changes can also move outputVolume; while held,
            // any event is only evidence that the physical repeat is alive.
            return [.holdRepeated(heldDirection)]
        }

        guard let pending else {
            beginPending(direction, at: instant)
            return []
        }

        if pending.count == 1 {
            let delay = pending.firstEventAt.duration(to: instant)
            if direction == pending.direction,
               delay >= Self.minimumInitialRepeatDelay,
               delay <= Self.maximumInitialRepeatDelay {
                replacePending(
                    direction: direction,
                    firstEventAt: pending.firstEventAt,
                    lastEventAt: instant,
                    count: 2
                )
                return []
            }
        } else {
            let delay = pending.lastEventAt.duration(to: instant)
            if direction == pending.direction,
               delay >= Self.minimumRepeatDelay,
               delay <= Self.maximumRepeatDelay {
                self.pending = nil
                heldDirection = direction
                return [.holdStarted(direction)]
            }
        }

        let taps = Array(
            repeating: VolumeGestureEvent.tap(pending.direction),
            count: pending.count
        )
        beginPending(direction, at: instant)
        return taps
    }

    mutating func expirePending(token: Int) -> [VolumeGestureEvent] {
        guard let pending, pending.token == token else { return [] }
        self.pending = nil
        return Array(
            repeating: VolumeGestureEvent.tap(pending.direction),
            count: pending.count
        )
    }

    mutating func endHold() -> VolumeGestureEvent? {
        guard isHolding else { return nil }
        let direction = heldDirection
        heldDirection = .none
        return .holdEnded(direction)
    }

    /// Clears unresolved taps and returns the direction of an interrupted
    /// hold, if one was active, so its owner can finish any held resource.
    mutating func reset() -> VolumeDirection {
        let interruptedDirection = heldDirection
        pending = nil
        heldDirection = .none
        return interruptedDirection
    }

    private mutating func beginPending(
        _ direction: VolumeDirection,
        at instant: ContinuousClock.Instant
    ) {
        replacePending(
            direction: direction,
            firstEventAt: instant,
            lastEventAt: instant,
            count: 1
        )
    }

    private mutating func replacePending(
        direction: VolumeDirection,
        firstEventAt: ContinuousClock.Instant,
        lastEventAt: ContinuousClock.Instant,
        count: Int
    ) {
        nextToken &+= 1
        pending = PendingPresses(
            token: nextToken,
            direction: direction,
            firstEventAt: firstEventAt,
            lastEventAt: lastEventAt,
            count: count
        )
    }
}

// True push-to-talk release detection uses the same public signal iOS exposes
// for presses: output-volume changes. After repeat events go quiet at a volume
// limit, the observer moves to a safe probe point. Resumed repeats mean "still
// held"; no repeats after the probe confirms release.

@MainActor
@Observable
final class VolumeObserver {
    private(set) var tapEventID = 0

    var onHoldStart: ((VolumeDirection) -> Void)?
    var onHoldEnd: ((VolumeDirection) -> Void)?

    private var cancellable: AnyCancellable?
    private var previousVolume: Float?
    private var pendingProgrammaticVolume: Float?
    private var resetTask: Task<Void, Never>?
    private var holdDetectTask: Task<Void, Never>?
    private var releaseTestTask: Task<Void, Never>?
    private var gestureClassifier = VolumeGestureClassifier()
    private var pendingTapDirections: [VolumeDirection] = []
    private weak var volumeView: MPVolumeView?
    private let session = AVAudioSession.sharedInstance()
    private let clock = ContinuousClock()
    private let midpointVolume: Float = 0.5

    private let tapHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let holdHaptic = UINotificationFeedbackGenerator()

    /// True while we've reset to midpoint to test if the user released.
    /// Events during this phase are "still holding" signals, not new holds.
    private var isTestingRelease = false

    private var isVolumeHeld: Bool { gestureClassifier.isHolding }

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
        activateVolumeObservationSession()
        previousVolume = session.outputVolume
        if !isVolumeHeld { setVolumeMidpoint() }

        cancellable = session.publisher(for: \.outputVolume)
            .sink { @Sendable [weak self] newVolume in
                Task { @MainActor [weak self] in
                    self?.handleVolumeChange(newVolume)
                }
            }
    }

    /// Re-activates the shared audio session for volume observation after
    /// another subsystem deactivated it. Transcription sets `.playAndRecord`
    /// then calls `setActive(false)` on stop; without re-arming here the
    /// hardware volume buttons stop driving `outputVolume` and the observer
    /// goes silent after the first recording (works-exactly-once bug). The
    /// KVO subscription itself stays alive — only the session needs re-arming.
    /// Call once transcription has fully stopped.
    func rearm() {
        let interruptedDirection = gestureClassifier.reset()
        isTestingRelease = false
        holdDetectTask?.cancel(); holdDetectTask = nil
        releaseTestTask?.cancel(); releaseTestTask = nil
        pendingProgrammaticVolume = nil
        pendingTapDirections.removeAll(keepingCapacity: true)
        activateVolumeObservationSession()
        previousVolume = session.outputVolume
        setVolumeMidpoint()
        if interruptedDirection != .none {
            onHoldEnd?(interruptedDirection)
        }
    }

    func consumeTapDirections() -> [VolumeDirection] {
        defer { pendingTapDirections.removeAll(keepingCapacity: true) }
        return pendingTapDirections
    }

    private func handleVolumeChange(_ newVolume: Float) {
        if let pendingVolume = pendingProgrammaticVolume {
            if abs(newVolume - pendingVolume) < 0.001 {
                // The echo from our own midpoint reset. Swallow it.
                pendingProgrammaticVolume = nil
                previousVolume = newVolume
                return
            }
            // A real button event arrived before our reset echo landed. Keep
            // `pending` set so the echo is still recognized when it arrives,
            // instead of clearing it now and later mis-reading the downward
            // 0.5 echo as a real "volume down" press — that race produced the
            // up/down/up jitter while holding a button.
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
        apply(gestureClassifier.receive(dir, at: clock.now))
        scheduleGestureResolution()
    }

    private func apply(_ events: [VolumeGestureEvent]) {
        for event in events {
            switch event {
            case .tap(let direction):
                pendingTapDirections.append(direction)
                tapEventID &+= 1
                tapHaptic.impactOccurred()
                scheduleMidpointReset()
            case .holdStarted(let direction):
                holdDetectTask?.cancel()
                holdDetectTask = nil
                resetTask?.cancel()
                resetTask = nil
                isTestingRelease = false
                holdHaptic.notificationOccurred(.success)
                onHoldStart?(direction)
                scheduleReleaseTest()
            case .holdRepeated:
                if isTestingRelease {
                    isTestingRelease = false
                    releaseTestTask?.cancel()
                    releaseTestTask = nil
                }
                scheduleReleaseTest()
            case .holdEnded(let direction):
                isTestingRelease = false
                releaseTestTask?.cancel()
                releaseTestTask = nil
                holdHaptic.notificationOccurred(.warning)
                onHoldEnd?(direction)
                scheduleMidpointReset()
            }
        }
    }

    private func scheduleGestureResolution() {
        holdDetectTask?.cancel()
        holdDetectTask = nil
        guard let pending = gestureClassifier.pendingResolution else { return }
        let remaining = clock.now.duration(to: pending.deadline)
        holdDetectTask = Task { @MainActor [weak self] in
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
            guard let self, !Task.isCancelled else { return }
            self.holdDetectTask = nil
            self.apply(self.gestureClassifier.expirePending(token: pending.token))
        }
    }

    /// After 2 seconds of silence during a hold, test if the user released
    /// by moving to a probe volume and checking for resumed events.
    private func scheduleReleaseTest() {
        releaseTestTask?.cancel()
        releaseTestTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.isVolumeHeld else { return }

            // No events for 2 seconds. Move to a probe volume to test release.
            self.isTestingRelease = true
            guard self.setReleaseProbeVolume() else {
                // Without moving the slider there is no valid release probe.
                // Keep the hold alive and retry instead of firing a false end.
                self.isTestingRelease = false
                self.releaseTestTask = nil
                self.scheduleReleaseTest()
                return
            }

            // Wait 1 second for events to resume.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            if self.isTestingRelease {
                // No events arrived after reset. User released.
                self.isTestingRelease = false
                if let event = self.gestureClassifier.endHold() {
                    self.apply([event])
                }
            }
            // If isTestingRelease was cleared by publish(), user is still
            // holding and scheduleReleaseTest was already called.
        }
    }

    /// Move the volume during a release test. Unlike the normal midpoint
    /// reset, this is allowed during a hold because resumed auto-repeat is
    /// what proves that the user is still pressing the button.
    private func setReleaseProbeVolume() -> Bool {
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else {
            return false
        }
        let currentVolume = session.outputVolume
        let targetVolume: Float
        if abs(currentVolume - midpointVolume) >= 0.001 {
            targetVolume = midpointVolume
        } else {
            // A route change can land exactly on midpoint while a hold is
            // active. Use headroom in the held direction so the probe still
            // produces both a programmatic change and a possible repeat.
            switch gestureClassifier.heldDirection {
            case .up:
                targetVolume = 0.25
            case .down:
                targetVolume = 0.75
            case .none:
                return false
            }
        }
        pendingProgrammaticVolume = targetVolume
        previousVolume = targetVolume
        slider.setValue(targetVolume, animated: false)
        slider.sendActions(for: .valueChanged)
        return true
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

    private func activateVolumeObservationSession() {
        // Transcription temporarily owns this process-wide session. Restore an
        // output-capable category before observing hardware volume again;
        // leaving the record-only category active makes outputVolume silent.
        try? session.setCategory(.ambient, mode: .default)
        try? session.setActive(true)
    }

    func stop() {
        let interruptedDirection = gestureClassifier.reset()
        cancellable?.cancel()
        resetTask?.cancel()
        holdDetectTask?.cancel()
        releaseTestTask?.cancel()
        cancellable = nil
        resetTask = nil
        holdDetectTask = nil
        releaseTestTask = nil
        isTestingRelease = false
        previousVolume = nil
        pendingProgrammaticVolume = nil
        pendingTapDirections.removeAll(keepingCapacity: true)
        if interruptedDirection != .none {
            onHoldEnd?(interruptedDirection)
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
