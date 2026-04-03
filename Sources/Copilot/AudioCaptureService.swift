import AVFoundation
import UIKit

@MainActor
@Observable
final class AudioCaptureService {
    private(set) var isRecording = false
    private(set) var hasPermission = false

    private let engine = AVAudioEngine()
    private let haptic = UIImpactFeedbackGenerator(style: .heavy)
    private var sendChunk: ((Data) -> Void)?
    private var activeCount = 0

    func configure(sendChunk: @escaping (Data) -> Void) {
        self.sendChunk = sendChunk
        hasPermission = AVAudioApplication.shared.recordPermission == .granted
    }

    func requestPermission() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasPermission = granted
            }
        }
    }

    func startRecording() {
        activeCount += 1
        guard activeCount == 1, hasPermission else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else { return }

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else { return }

        input.installTap(onBus: 0, bufferSize: 512, format: hwFormat) { [weak self] buffer, _ in
            let frameCapacity = AVAudioFrameCount(512)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, outputBuffer.frameLength > 0 else { return }
            let byteCount = Int(outputBuffer.frameLength) * 2
            let data = Data(bytes: outputBuffer.int16ChannelData![0], count: byteCount)
            Task { @MainActor [weak self] in
                self?.sendChunk?(data)
            }
        }

        try? engine.start()
        isRecording = true
        haptic.impactOccurred()
    }

    func stopRecording() {
        activeCount = max(activeCount - 1, 0)
        guard activeCount == 0, isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        haptic.impactOccurred()
    }
}
