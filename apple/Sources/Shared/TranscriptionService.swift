import Foundation
import Observation
@preconcurrency import WhisperKit

#if canImport(AVFAudio)
import AVFAudio
#endif

struct TranscriptionLoadedModel: @unchecked Sendable {
    let kit: WhisperKit?
    let cacheEntry: WhisperModelCache.Entry
}

struct TranscriptionStreamUpdate: Sendable {
    let isRecording: Bool
    let confirmedText: String
    let partialText: String
}

struct TranscriptionStreamHandle: @unchecked Sendable {
    let run: @Sendable () async throws -> Void
    let stop: @Sendable () async -> Void
}

private final class TranscriptionReadiness: @unchecked Sendable {
    enum Outcome: Sendable, Equatable {
        case ready
        case endedBeforeReady
        case failed(String)
        case cancelled
    }

    private let lock = NSLock()
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            let resolved = lock.withLock { () -> Outcome? in
                if let outcome { return outcome }
                self.continuation = continuation
                return nil
            }
            if let resolved { continuation.resume(returning: resolved) }
        }
    }

    func resolve(_ outcome: Outcome) {
        let continuation = lock.withLock { () -> CheckedContinuation<Outcome, Never>? in
            guard self.outcome == nil else { return nil }
            self.outcome = outcome
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: outcome)
    }

    var currentOutcome: Outcome? {
        lock.withLock { outcome }
    }
}

private final class TranscriptionStopRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@Sendable () async -> Void)?

    func install(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock { self.operation = operation }
    }

    func stop() async {
        let operation: (@Sendable () async -> Void)? = lock.withLock { self.operation }
        await operation?()
    }
}

private final class TranscriptionStopCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !isComplete else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func resolve() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isComplete else { return [] }
            isComplete = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }
}

private enum TranscriptionServiceError: LocalizedError {
    case incompleteCache

    var errorDescription: String? {
        "The speech model cache is incomplete. Remove it and download the model again."
    }
}

@Observable
@MainActor
final class TranscriptionService: @unchecked Sendable {
    typealias ModelLoader = @Sendable (
        TranscriptionModelPreparation,
        @escaping @Sendable (Progress) -> Void
    ) async throws -> TranscriptionLoadedModel
    typealias StreamFactory = @MainActor @Sendable (
        TranscriptionLoadedModel,
        @escaping @Sendable (TranscriptionStreamUpdate) -> Void
    ) throws -> TranscriptionStreamHandle

    var partialText: String = ""
    var finalText: String = ""
    var isTranscribing: Bool = false
    var isModelLoaded: Bool = false
    var isModelLoading: Bool = false
    var modelLoadingProgress: String = ""
    var modelLoadingFraction: Double?
    var modelErrorMessage: String?

    private var loadedModel: TranscriptionLoadedModel?
    private var modelOperationTask: Task<TranscriptionLoadedModel, Error>?
    private var modelCompletionTask: Task<Bool, Never>?
    private var modelLoadGate = TranscriptionLoadGate()
    private var modelLoadGeneration = 0
    private var modelCancellationRequested = false
    private var modelCancellationMessage: String?

    private var streamHandle: TranscriptionStreamHandle?
    private var streamTask: Task<Void, Never>?
    private var streamReadiness: TranscriptionReadiness?
    private var transcriptionGeneration = 0
    private var streamStopCompletion: TranscriptionStopCompletion?
    private var audioSessionGeneration: Int?

    private let modelCache: WhisperModelCache
    private let networkStatusProvider: @Sendable () -> TranscriptionNetworkStatus
    private let modelLoader: ModelLoader
    private let permissionRequest: @Sendable () async -> Bool
    private let streamFactory: StreamFactory
    private let activateAudioSession: @MainActor @Sendable () -> Void
    private let deactivateAudioSession: @MainActor @Sendable () -> Void

    init() {
        let cache = WhisperModelCache()
        let networkObserver = TranscriptionNetworkObserver()
        modelCache = cache
        networkStatusProvider = { networkObserver.status }
        modelLoader = { preparation, progress in
            try await Self.loadWhisperModel(
                preparation: preparation,
                cache: cache,
                progress: progress
            )
        }
        permissionRequest = { await AudioProcessor.requestRecordPermission() }
        streamFactory = Self.makeWhisperStream
        activateAudioSession = Self.activateRecordingAudioSession
        deactivateAudioSession = Self.deactivateRecordingAudioSession
    }

    init(
        testingCache: WhisperModelCache,
        networkStatus: TranscriptionNetworkStatus = .unmetered,
        modelLoader: @escaping ModelLoader,
        permissionRequest: @escaping @Sendable () async -> Bool,
        streamFactory: @escaping StreamFactory,
        activateAudioSession: @escaping @MainActor @Sendable () -> Void = {},
        deactivateAudioSession: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        modelCache = testingCache
        networkStatusProvider = { networkStatus }
        self.modelLoader = modelLoader
        self.permissionRequest = permissionRequest
        self.streamFactory = streamFactory
        self.activateAudioSession = activateAudioSession
        self.deactivateAudioSession = deactivateAudioSession
    }

    var hasCachedModel: Bool { modelCache.validEntry != nil }

    var cachedModelSize: String {
        let bytes = modelCache.storedBytes
        guard bytes > 0 else { return "Not downloaded" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var networkStatus: TranscriptionNetworkStatus { networkStatusProvider() }

    @discardableResult
    func loadModel(allowRestrictedNetwork: Bool = false) async -> Bool {
        guard !isModelLoaded else { return true }
        if let existing = modelCompletionTask {
            return await waitForModelLoad(existing, generation: modelLoadGeneration)
        }
        guard modelLoadGate.begin() else { return false }

        let preparation: TranscriptionModelPreparation
        do {
            preparation = try TranscriptionDownloadPolicy.preparation(
                cachedEntry: modelCache.validEntry,
                network: networkStatusProvider(),
                allowRestrictedNetwork: allowRestrictedNetwork
            )
        } catch {
            modelLoadGate.finish()
            modelErrorMessage = error.localizedDescription
            return false
        }

        isModelLoading = true
        modelErrorMessage = nil
        modelLoadingProgress = preparation.isCached
            ? "Loading cached speech model…"
            : "Preparing speech model download…"
        modelLoadingFraction = preparation.isCached ? nil : 0
        modelLoadGeneration += 1
        modelCancellationRequested = false
        modelCancellationMessage = nil
        let generation = modelLoadGeneration

        let operation = Task { [weak self, modelLoader] in
            try await modelLoader(preparation) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateModelProgress(
                        progress,
                        generation: generation,
                        allowRestrictedNetwork: allowRestrictedNetwork
                    )
                }
            }
        }
        modelOperationTask = operation

        let completion = Task { [weak self] in
            let result: Result<TranscriptionLoadedModel, Error>
            do {
                result = .success(try await operation.value)
            } catch {
                result = .failure(error)
            }
            guard let self else { return false }
            return self.finishModelLoad(result, generation: generation)
        }
        modelCompletionTask = completion
        return await waitForModelLoad(completion, generation: generation)
    }

    private func waitForModelLoad(_ task: Task<Bool, Never>, generation: Int) async -> Bool {
        await withTaskCancellationHandler {
            let succeeded = await task.value
            return !Task.isCancelled && succeeded
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.requestModelCancellation(
                    generation: generation,
                    message: "Speech model download was cancelled. You can retry when ready."
                )
            }
        }
    }

    private func finishModelLoad(
        _ result: Result<TranscriptionLoadedModel, Error>,
        generation: Int
    ) -> Bool {
        guard generation == modelLoadGeneration else { return false }
        defer {
            modelOperationTask = nil
            modelCompletionTask = nil
            modelLoadGate.finish()
            isModelLoading = false
            modelLoadingProgress = ""
            modelLoadingFraction = nil
            modelCancellationRequested = false
            modelCancellationMessage = nil
        }

        if modelCancellationRequested {
            modelErrorMessage = modelCancellationMessage
                ?? "Speech model download was cancelled. You can retry when ready."
            return false
        }

        switch result {
        case .success(let loaded):
            guard modelCache.isComplete(loaded.cacheEntry) else {
                modelErrorMessage = TranscriptionServiceError.incompleteCache.localizedDescription
                return false
            }
            modelCache.remember(loaded.cacheEntry.modelFolder)
            loadedModel = loaded
            isModelLoaded = true
            return true
        case .failure(let error):
            if error is CancellationError {
                modelErrorMessage = modelCancellationMessage
                    ?? "Speech model download was cancelled. You can retry when ready."
            } else {
                modelErrorMessage = "Speech model load failed: \(error.localizedDescription)"
            }
            return false
        }
    }

    private func updateModelProgress(
        _ progress: Progress,
        generation: Int,
        allowRestrictedNetwork: Bool
    ) {
        guard generation == modelLoadGeneration, !modelCancellationRequested else { return }
        if !allowRestrictedNetwork,
           [.offline, .expensive, .constrained].contains(networkStatusProvider()) {
            requestModelCancellation(
                generation: generation,
                message: "The speech-model download stopped because the network became unavailable or restricted. Connect to Wi-Fi or choose Use Cellular to retry."
            )
            return
        }
        let fraction = progress.fractionCompleted
        modelLoadingFraction = fraction.isFinite ? min(max(fraction, 0), 1) : nil
        modelLoadingProgress = fraction.isFinite && fraction > 0
            ? "Downloading speech model… \(Int(fraction * 100))%"
            : "Downloading speech model (about 150 MB)…"
    }

    func cancelModelLoad(message: String = "Speech model download was cancelled.") {
        requestModelCancellation(generation: modelLoadGeneration, message: message)
    }

    private func requestModelCancellation(generation: Int, message: String) {
        guard generation == modelLoadGeneration,
              modelCompletionTask != nil,
              !modelCancellationRequested else { return }
        modelCancellationRequested = true
        modelCancellationMessage = message
        modelLoadingProgress = "Cancelling speech-model load…"
        modelLoadingFraction = nil
        modelOperationTask?.cancel()
    }

    @discardableResult
    func start(allowRestrictedNetwork: Bool = false) async -> Bool {
        guard streamStopCompletion == nil else { return false }
        guard !isTranscribing else { return true }
        guard streamTask == nil else { return false }
        transcriptionGeneration += 1
        let generation = transcriptionGeneration

        if !isModelLoaded {
            guard await loadModel(allowRestrictedNetwork: allowRestrictedNetwork) else { return false }
        }
        guard generation == transcriptionGeneration,
              !Task.isCancelled,
              let loadedModel else { return false }

        guard await permissionRequest() else {
            guard generation == transcriptionGeneration else { return false }
            modelErrorMessage = "Microphone access was not granted. Enable microphone access in Settings and retry."
            return false
        }
        guard generation == transcriptionGeneration, !Task.isCancelled else { return false }

        activateAudioSession()
        audioSessionGeneration = generation
        partialText = ""
        finalText = ""

        let readiness = TranscriptionReadiness()
        let stopRelay = TranscriptionStopRelay()
        let update: @Sendable (TranscriptionStreamUpdate) -> Void = { [weak self] update in
            if update.isRecording { readiness.resolve(.ready) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard generation == self.transcriptionGeneration else {
                    if update.isRecording { await stopRelay.stop() }
                    return
                }
                self.finalText = update.confirmedText
                self.partialText = update.partialText
            }
        }

        let handle: TranscriptionStreamHandle
        do {
            handle = try streamFactory(loadedModel, update)
        } catch {
            modelErrorMessage = "Could not prepare transcription: \(error.localizedDescription)"
            deactivateAudioSessionIfOwned(by: generation)
            return false
        }
        stopRelay.install(handle.stop)
        streamHandle = handle
        streamReadiness = readiness

        let task = Task { [weak self] in
            do {
                try await handle.run()
                readiness.resolve(.endedBeforeReady)
                self?.streamDidEnd(generation: generation, readiness: readiness, error: nil)
            } catch is CancellationError {
                readiness.resolve(.cancelled)
                self?.streamDidEnd(generation: generation, readiness: readiness, error: nil)
            } catch {
                readiness.resolve(.failed(error.localizedDescription))
                self?.streamDidEnd(generation: generation, readiness: readiness, error: error)
            }
        }
        streamTask = task

        let outcome = await withTaskCancellationHandler {
            await readiness.wait()
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.stopStreamIfCurrent(generation: generation)
            }
        }

        switch outcome {
        case .ready:
            guard generation == transcriptionGeneration,
                  streamReadiness === readiness,
                  streamTask != nil else { return false }
            isTranscribing = true
            return true
        case .endedBeforeReady:
            if generation == transcriptionGeneration, modelErrorMessage == nil {
                modelErrorMessage = "Could not start transcription because microphone recording did not become ready."
            }
            return false
        case .failed(let message):
            if generation == transcriptionGeneration {
                modelErrorMessage = "Could not start transcription: \(message)"
            }
            return false
        case .cancelled:
            return false
        }
    }

    private func streamDidEnd(
        generation: Int,
        readiness: TranscriptionReadiness,
        error: Error?
    ) {
        guard generation == transcriptionGeneration, streamReadiness === readiness else { return }
        let wasReady = readiness.currentOutcome == .ready
        streamHandle = nil
        streamTask = nil
        streamReadiness = nil
        isTranscribing = false
        deactivateAudioSessionIfOwned(by: generation)
        if let error {
            modelErrorMessage = wasReady
                ? "Transcription stopped: \(error.localizedDescription)"
                : "Could not start transcription: \(error.localizedDescription)"
        } else if wasReady {
            modelErrorMessage = "Transcription stopped unexpectedly."
        } else {
            modelErrorMessage = "Could not start transcription because microphone recording did not become ready."
        }
    }

    private func stopStreamIfCurrent(generation: Int) async {
        guard generation == transcriptionGeneration else { return }
        await stop()
    }

    func removeCachedModel() async {
        await stop()
        loadedModel = nil
        isModelLoaded = false
        do {
            try modelCache.remove()
            modelErrorMessage = nil
        } catch {
            modelErrorMessage = "Could not remove the speech model: \(error.localizedDescription)"
        }
    }

    func stop() async {
        if let streamStopCompletion {
            await streamStopCompletion.wait()
            return
        }
        let completion = TranscriptionStopCompletion()
        streamStopCompletion = completion
        let stoppedGeneration = transcriptionGeneration
        transcriptionGeneration += 1
        let stopGeneration = transcriptionGeneration
        isTranscribing = false

        if modelCompletionTask != nil {
            cancelModelLoad()
            if let completion = modelCompletionTask { _ = await completion.value }
        }

        let readiness = streamReadiness
        let handle = streamHandle
        let task = streamTask
        streamReadiness = nil
        streamHandle = nil
        streamTask = nil
        readiness?.resolve(.cancelled)
        task?.cancel()
        await handle?.stop()
        if let task { await task.value }
        if stopGeneration == transcriptionGeneration {
            deactivateAudioSessionIfOwned(by: stoppedGeneration)
        }
        if streamStopCompletion === completion {
            streamStopCompletion = nil
        }
        completion.resolve()
    }

    private func deactivateAudioSessionIfOwned(by generation: Int) {
        guard audioSessionGeneration == generation else { return }
        audioSessionGeneration = nil
        deactivateAudioSession()
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

    private static func loadWhisperModel(
        preparation: TranscriptionModelPreparation,
        cache: WhisperModelCache,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> TranscriptionLoadedModel {
        let modelFolder: URL
        let tokenizerFolder: URL
        switch preparation {
        case .loadCached(let entry):
            guard cache.isComplete(entry) else { throw TranscriptionServiceError.incompleteCache }
            // This API parses only local files and never performs a Hub request.
            // Doing it first prevents WhisperKit's tokenizer loader from silently
            // falling back upstream for a corrupt cache.
            _ = try await AutoTokenizerWrapper.from(modelFolder: entry.tokenizerFolder)
            guard cache.isComplete(entry) else { throw TranscriptionServiceError.incompleteCache }
            modelFolder = entry.modelFolder
            tokenizerFolder = entry.tokenizerFolder
        case .download:
            modelFolder = try await WhisperKit.download(
                variant: WhisperModelCache.modelName,
                progressCallback: progress
            )
            try Task.checkCancellation()
            tokenizerFolder = cache.tokenizerDownloadBase
        }

        let kit = try await WhisperKit(
            WhisperKitConfig(
                model: WhisperModelCache.modelName,
                modelFolder: modelFolder.path,
                tokenizerFolder: tokenizerFolder,
                verbose: false,
                logLevel: .none,
                prewarm: true,
                load: true,
                download: false
            )
        )
        try Task.checkCancellation()

        let entry = WhisperModelCache.Entry(
            modelFolder: modelFolder,
            tokenizerFolder: cache.tokenizerFolder
        )
        guard cache.isComplete(entry), kit.tokenizer != nil else {
            throw TranscriptionServiceError.incompleteCache
        }
        return TranscriptionLoadedModel(kit: kit, cacheEntry: entry)
    }

    private static func makeWhisperStream(
        loaded: TranscriptionLoadedModel,
        update: @escaping @Sendable (TranscriptionStreamUpdate) -> Void
    ) throws -> TranscriptionStreamHandle {
        guard let kit = loaded.kit, let tokenizer = kit.tokenizer else {
            throw TranscriptionServiceError.incompleteCache
        }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperatureFallbackCount: 3,
            sampleLength: 224,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            clipTimestamps: [0]
        )

        let transcriber = AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: kit.audioProcessor,
            decodingOptions: options,
            requiredSegmentsForConfirmation: 2,
            silenceThreshold: 0.3,
            compressionCheckWindow: 60,
            useVAD: true,
            stateChangeCallback: { _, state in
                // Argmax flips `State.isRecording` immediately before it asks
                // AVAudioEngine to start. Require the default processor's engine
                // to be running as well, so a synchronous engine-start failure
                // cannot briefly masquerade as a ready microphone.
                let recordingIsReady: Bool
                if let processor = kit.audioProcessor as? AudioProcessor {
                    recordingIsReady = state.isRecording && processor.audioEngine?.isRunning == true
                } else {
                    recordingIsReady = state.isRecording
                }
                let confirmed = state.confirmedSegments
                    .map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let unconfirmed = state.unconfirmedSegments
                    .map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let current = state.currentText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "Waiting for speech...", with: "")
                update(TranscriptionStreamUpdate(
                    isRecording: recordingIsReady,
                    confirmedText: confirmed,
                    partialText: [unconfirmed, current]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                ))
            }
        )

        return TranscriptionStreamHandle(
            run: { try await transcriber.startStreamTranscription() },
            stop: { await transcriber.stopStreamTranscription() }
        )
    }

    // MARK: - AVAudioSession (iOS only)

    private static func activateRecordingAudioSession() {
        #if canImport(AVFAudio) && os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try? session.setActive(true)
        #endif
    }

    private static func deactivateRecordingAudioSession() {
        #if canImport(AVFAudio) && os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }
}

private extension TranscriptionModelPreparation {
    var isCached: Bool {
        if case .loadCached = self { return true }
        return false
    }
}
