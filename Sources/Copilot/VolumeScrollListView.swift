import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

struct VolumeScrollListView<Item: Identifiable, RowContent: View>: View {
    let items: [Item]
    @Binding var selectedID: Item.ID?
    var onHighlightChanged: ((Item) -> Void)?
    @ViewBuilder let rowContent: (Item, Bool) -> RowContent

    @State private var volumeObserver = VolumeObserver()

    private var highlightedIndex: Int? {
        guard let selectedID else { return nil }
        return items.firstIndex(where: { $0.id == selectedID })
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(Array(items.enumerated()), id: \.element.id) { index, item in
                rowContent(item, item.id == selectedID)
                    .listRowBackground(
                        item.id == selectedID
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear
                    )
                    .id(index)
            }
            .listStyle(.plain)
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
        .onAppear { volumeObserver.start() }
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

    private var cancellable: AnyCancellable?
    private var previousVolume: Float?
    private var pendingProgrammaticVolume: Float?
    private var resetTask: Task<Void, Never>?
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
        scheduleMidpointReset()
    }

    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    private func publish(_ direction: VolumeDirection) {
        self.direction = direction
        eventID += 1
        haptic.impactOccurred()
    }

    private func scheduleMidpointReset() {
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
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
        cancellable = nil
        resetTask = nil
        previousVolume = nil
        pendingProgrammaticVolume = nil
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
