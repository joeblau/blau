import Foundation
import Observation
@preconcurrency import WhisperKit

@Observable
@MainActor
final class TranscriptionService: @unchecked Sendable {
    var partialText: String = ""
    var finalText: String = ""
    var isTranscribing: Bool = false
    var isModelLoaded: Bool = false
    var modelLoadingProgress: String = ""

    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private var transcriptionGeneration = 0

    func loadModel() async {
        guard !isModelLoaded else { return }
        modelLoadingProgress = "Loading model..."

        do {
            let kit = try await WhisperKit(
                WhisperKitConfig(
                    model: "openai_whisper-tiny",
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
    }

    private func handleStateChange(
        oldState: AudioStreamTranscriber.State,
        newState: AudioStreamTranscriber.State
    ) {
        let confirmed = newState.confirmedSegments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let unconfirmed = newState.unconfirmedSegments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let current = newState.currentText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        finalText = confirmed
        partialText = [unconfirmed, current]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
