import AVFoundation

@MainActor
@Observable
final class AudioPlaybackService {
    private(set) var isPlaying = false

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
    }

    func startPlayback() {
        guard !isPlaying else { return }
        try? engine.start()
        playerNode.play()
        isPlaying = true
    }

    func stopPlayback() {
        guard isPlaying else { return }
        playerNode.stop()
        engine.stop()
        isPlaying = false
    }

    func enqueue(_ data: Data) {
        guard isPlaying else { return }
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            memcpy(buffer.int16ChannelData![0], src, data.count)
        }
        playerNode.scheduleBuffer(buffer)
    }
}
