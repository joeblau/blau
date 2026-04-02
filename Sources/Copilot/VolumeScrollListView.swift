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
            .overlay { VolumeHiderView() }
            .onChange(of: volumeObserver.direction) {
                guard !items.isEmpty else { return }
                switch volumeObserver.direction {
                case .up:
                    highlightedIndex = max(highlightedIndex - 1, 0)
                case .down:
                    highlightedIndex = min(highlightedIndex + 1, items.count - 1)
                case .none:
                    break
                }
                withAnimation {
                    proxy.scrollTo(highlightedIndex, anchor: .center)
                }
            }
        }
        .onAppear { volumeObserver.start() }
        .onDisappear { volumeObserver.stop() }
    }
}

// MARK: - Volume Observer

enum VolumeDirection {
    case none, up, down
}

@Observable
final class VolumeObserver {
    var direction: VolumeDirection = .none

    private var cancellable: AnyCancellable?
    private var previousVolume: Float?
    private let session = AVAudioSession.sharedInstance()

    func start() {
        try? session.setActive(true)
        previousVolume = session.outputVolume

        cancellable = session.publisher(for: \.outputVolume)
            .removeDuplicates()
            .sink { [weak self] newVolume in
                guard let self, let prev = self.previousVolume else { return }
                if newVolume > prev {
                    self.direction = .up
                } else if newVolume < prev {
                    self.direction = .down
                }
                self.previousVolume = newVolume
                // Toggle back to .none so the next change triggers onChange
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.direction = .none
                }
            }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}

// MARK: - Hidden volume HUD

/// Places an invisible MPVolumeView to suppress the system volume HUD.
struct VolumeHiderView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.alpha = 0.001
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
