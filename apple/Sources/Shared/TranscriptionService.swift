import Foundation
import Observation
@preconcurrency import WhisperKit

#if canImport(AVFAudio)
import AVFAudio
#endif

@Observable
@MainActor
final class TranscriptionService: @unchecked Sendable {
    var partialText: String = ""
    var finalText: String = ""
    var isTranscribing: Bool = false
    var isModelLoaded: Bool = false
    var modelLoadingProgress: String = ""

    /// Model selection rationale: `base` runs at roughly 0.1× real-time on
    /// recent iPhones via the Neural Engine, with materially better
    /// accuracy than `tiny` for the short command-style utterances
    /// walkie-talkie produces. WhisperKit downloads the CoreML model on
    /// first use and caches it on-device.
    private static let modelName = "openai_whisper-base"

    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private var transcriptionGeneration = 0

    func loadModel() async {
        guard !isModelLoaded else { return }
        modelLoadingProgress = "Loading model..."

        do {
            let kit = try await WhisperKit(
                WhisperKitConfig(
                    model: Self.modelName,
                    verbose: false,
                    logLevel: .none,
                    prewarm: true,
                    load: true,
                    download: true
                )
            )
            whisperKit = kit
            isModelLoaded = true
            modelLoadingProgress = ""
        } catch {
            modelLoadingProgress = "Model load failed: \(error.localizedDescription)"
        }
    }

    func start() async {
        guard !isTranscribing else { return }

        if !isModelLoaded {
            await loadModel()
        }
        guard let kit = whisperKit else { return }

        // On iOS, the shared `AVAudioSession` must be in a category that
        // permits recording before WhisperKit's `AudioProcessor` opens
        // the input node. macOS doesn't use `AVAudioSession`.
        Self.activateRecordingAudioSession()

        transcriptionGeneration += 1
        let generation = transcriptionGeneration

        partialText = ""
        finalText = ""
        isTranscribing = true

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperatureFallbackCount: 3,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            clipTimestamps: [0]
        )

        let callback: @Sendable (AudioStreamTranscriber.State, AudioStreamTranscriber.State) -> Void = {
            [weak self] _, newState in
            let confirmed = newState.confirmedSegments
                .map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let unconfirmed = newState.unconfirmedSegments
                .map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let current = newState.currentText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "Waiting for speech...", with: "")
            Task { @MainActor [weak self] in
                self?.finalText = confirmed
                self?.partialText = [unconfirmed, current]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
        }

        let transcriber = AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: kit.tokenizer!,
            audioProcessor: kit.audioProcessor,
            decodingOptions: options,
            requiredSegmentsForConfirmation: 2,
            silenceThreshold: 0.3,
            compressionCheckWindow: 60,
            useVAD: true,
            stateChangeCallback: callback
        )

        streamTranscriber = transcriber

        do {
            try await transcriber.startStreamTranscription()
        } catch {
            // Only clear state if no newer transcription has started.
            if transcriptionGeneration == generation {
                isTranscribing = false
            }
        }
    }

    func stop() async {
        transcriptionGeneration += 1
        await streamTranscriber?.stopStreamTranscription()
        streamTranscriber = nil
        isTranscribing = false
        Self.deactivateRecordingAudioSession()
    }

    /// Returns the best-effort full transcript captured during the most
    /// recent `start()/stop()` cycle. Call after `stop()` returns.
    var combinedText: String {
        [finalText, partialText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "Waiting for speech...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AVAudioSession (iOS only)

    private static func activateRecordingAudioSession() {
        #if canImport(AVFAudio) && os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // `.playAndRecord` (vs. `.record`) keeps system sounds and
            // other apps mixable, and `.duckOthers` lowers their volume
            // while we listen. `.allowBluetooth` covers AirPods mics.
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.duckOthers, .allowBluetooth, .defaultToSpeaker]
            )
            try session.setActive(true, options: [])
        } catch {
            // Best-effort: WhisperKit will surface an audio engine error
            // if the session isn't usable.
        }
        #endif
    }

    private static func deactivateRecordingAudioSession() {
        #if canImport(AVFAudio) && os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Notify other apps we're done so they can ramp back up.
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
}
