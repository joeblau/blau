import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

struct VolumeScrollListView<Item: Identifiable, RowContent: View>: View {
    let items: [Item]
    @ViewBuilder let rowContent: (Item, Bool) -> RowContent

    @State private var highlightedIndex: Int = 0
    @State private var volumeObserver = VolumeObserver()

    var body: some View {
        ScrollViewReader { proxy in
            List(Array(items.enumerated()), id: \.element.id) { index, item in
                rowContent(item, index == highlightedIndex)
                    .listRowBackground(
                        index == highlightedIndex
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
                highlightedIndex = nextHighlightedIndex(
                    for: volumeObserver.direction,
                    itemCount: items.count
                )
                withAnimation {
                    proxy.scrollTo(highlightedIndex, anchor: .center)
                }
            }
        }
        .onAppear { volumeObserver.start() }
        .onDisappear { volumeObserver.stop() }
    }

    private func nextHighlightedIndex(
        for direction: VolumeDirection,
        itemCount: Int
    ) -> Int {
        switch direction {
        case .up:
            return max(highlightedIndex - 1, 0)
        case .down:
            return min(highlightedIndex + 1, itemCount - 1)
        case .none:
            return highlightedIndex
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
            .receive(on: RunLoop.main)
            .sink { [weak self] newVolume in
                MainActor.assumeIsolated {
                    guard let self else { return }

                    if let pendingVolume = self.pendingProgrammaticVolume {
                        self.pendingProgrammaticVolume = nil
                        if abs(newVolume - pendingVolume) < 0.001 {
                            self.previousVolume = newVolume
                            return
                        }
                    }

                    guard let prev = self.previousVolume else {
                        self.previousVolume = newVolume
                        return
                    }

                    if newVolume > prev {
                        self.publish(.up)
                    } else if newVolume < prev {
                        self.publish(.down)
                    } else {
                        self.previousVolume = newVolume
                        return
                    }

                    self.previousVolume = newVolume
                    self.scheduleMidpointReset()
                }
            }
    }

    private func publish(_ direction: VolumeDirection) {
        self.direction = direction
        eventID += 1
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
