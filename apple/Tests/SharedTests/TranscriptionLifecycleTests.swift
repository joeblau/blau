import Foundation
import Testing
@testable import Copilot

@Suite("Transcription model lifecycle", .serialized)
@MainActor
struct TranscriptionLifecycleTests {
    @Test("first run blocks offline and restricted transfers until explicit override")
    func firstRunNetworkPolicy() throws {
        #expect(throws: TranscriptionModelPreparationError.offline) {
            try TranscriptionDownloadPolicy.preparation(
                cachedEntry: nil,
                network: .offline,
                allowRestrictedNetwork: false
            )
        }
        #expect(throws: TranscriptionModelPreparationError.expensiveNetwork) {
            try TranscriptionDownloadPolicy.preparation(
                cachedEntry: nil,
                network: .expensive,
                allowRestrictedNetwork: false
            )
        }
        #expect(throws: TranscriptionModelPreparationError.constrainedNetwork) {
            try TranscriptionDownloadPolicy.preparation(
                cachedEntry: nil,
                network: .constrained,
                allowRestrictedNetwork: false
            )
        }
        #expect(try TranscriptionDownloadPolicy.preparation(
            cachedEntry: nil,
            network: .expensive,
            allowRestrictedNetwork: true
        ) == .download)
    }

    @Test("a complete cached model and tokenizer load while offline")
    func cachedStartupDoesNotRequireNetwork() throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let entry = try #require(fixture.cache.validEntry)
        #expect(try TranscriptionDownloadPolicy.preparation(
            cachedEntry: entry,
            network: .offline,
            allowRestrictedNetwork: false
        ) == .loadCached(entry))
    }

    @Test("Argmax Hub root resolves to the expected tokenizer repository")
    func tokenizerDownloadRoot() throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }

        let repositoryFromHubRoot = fixture.cache.tokenizerDownloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("openai", isDirectory: true)
            .appendingPathComponent("whisper-base", isDirectory: true)

        #expect(fixture.cache.tokenizerDownloadBase == fixture.documents
            .appendingPathComponent("huggingface", isDirectory: true))
        #expect(repositoryFromHubRoot == fixture.cache.tokenizerFolder)
    }

    @Test("cancelled downloads release the single-flight gate for an explicit retry")
    func duplicateLoadGate() {
        var gate = TranscriptionLoadGate()
        let first = gate.begin()
        let duplicate = gate.begin()
        #expect(first)
        #expect(!duplicate)
        gate.cancel()
        let retry = gate.begin()
        #expect(retry)
    }

    @Test("0.18 model layout migrates only with the Argmax tokenizer component")
    func legacyCacheMigration() throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }

        #expect(fixture.cache.validEntry == WhisperModelCache.Entry(
            modelFolder: fixture.model,
            tokenizerFolder: fixture.tokenizer
        ))
        #expect(fixture.cache.storedBytes > 3)
    }

    @Test("missing or corrupt tokenizer JSON invalidates an otherwise complete model")
    func tokenizerValidity() throws {
        let missing = try ModelCacheFixture(includeTokenizerConfig: false)
        defer { missing.remove() }
        #expect(missing.cache.validEntry == nil)

        let corrupt = try ModelCacheFixture(corruptTokenizer: true)
        defer { corrupt.remove() }
        #expect(corrupt.cache.validEntry == nil)
    }

    @Test("removing a cached model removes both CoreML and tokenizer repositories")
    func removeCompleteCache() throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        _ = fixture.cache.validEntry
        try fixture.cache.remove()
        #expect(!FileManager.default.fileExists(atPath: fixture.model.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.tokenizer.path))
        #expect(fixture.cache.validEntry == nil)
    }

    @Test("incomplete CoreML caches never masquerade as ready")
    func incompleteModelCache() throws {
        let fixture = try ModelCacheFixture(includeDecoder: false)
        defer { fixture.remove() }
        #expect(fixture.cache.validEntry == nil)

        try Data([1]).write(to: fixture.model.appendingPathComponent("TextDecoder.mlmodelc"))
        #expect(fixture.cache.validEntry != nil)
    }

    @Test("service model loading is single-flight for concurrent callers")
    func serviceModelLoadIsSingleFlight() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let entry = try #require(fixture.cache.validEntry)
        let loader = ControlledModelLoader(entry: entry)
        let service = makeService(fixture: fixture, loader: loader)

        let first = Task { await service.loadModel() }
        let second = Task { await service.loadModel() }
        await loader.waitForLoadCount(1)
        #expect(await loader.loadCount == 1)
        await loader.releaseNext()

        #expect(await first.value)
        #expect(await second.value)
        #expect(service.isModelLoaded)
        #expect(!service.isModelLoading)
    }

    @Test("caller cancellation owns cleanup and blocks retry overlap")
    func serviceModelLoadCancellation() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let entry = try #require(fixture.cache.validEntry)
        let loader = ControlledModelLoader(entry: entry)
        let service = makeService(fixture: fixture, loader: loader)

        let first = Task { await service.loadModel() }
        await loader.waitForLoadCount(1)
        first.cancel()
        await waitUntil { service.modelLoadingProgress.contains("Cancelling") }

        let overlappingRetry = Task { await service.loadModel() }
        await Task.yield()
        #expect(await loader.loadCount == 1)
        #expect(service.isModelLoading)

        await loader.releaseNext()
        #expect(!(await first.value))
        #expect(!(await overlappingRetry.value))
        #expect(!service.isModelLoading)
        #expect(!service.isModelLoaded)

        let retry = Task { await service.loadModel() }
        await loader.waitForLoadCount(2)
        #expect(await loader.loadCount == 2)
        await loader.releaseNext()
        #expect(await retry.value)
        #expect(service.isModelLoaded)
    }

    @Test("start returns only after the owned stream reports recording ready")
    func recordingReadinessAndStop() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .readyUntilStopped)
        let service = makeService(fixture: fixture, stream: stream)

        #expect(await service.start())
        #expect(service.isTranscribing)
        #expect(stream.runCount == 1)

        await service.stop()
        #expect(!service.isTranscribing)
        #expect(stream.stopCount == 1)
    }

    @Test("denied microphone permission never starts a stream")
    func deniedMicrophonePermission() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .readyUntilStopped)
        let service = makeService(fixture: fixture, permission: { false }, stream: stream)

        #expect(!(await service.start()))
        #expect(!service.isTranscribing)
        #expect(stream.runCount == 0)
        #expect(service.modelErrorMessage?.contains("Microphone access") == true)
    }

    @Test("a normally returning Argmax stream is not mistaken for readiness")
    func streamReturnBeforeReadiness() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .returnBeforeReady)
        let service = makeService(fixture: fixture, stream: stream)

        #expect(!(await service.start()))
        #expect(!service.isTranscribing)
        #expect(service.modelErrorMessage?.contains("did not become ready") == true)
    }

    @Test("stopping while permission is pending prevents a late stream start")
    func earlyStopDuringPermission() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let permission = ControlledPermission()
        let stream = ControlledStream(behavior: .readyUntilStopped)
        let service = makeService(
            fixture: fixture,
            permission: { await permission.request() },
            stream: stream
        )

        let start = Task { await service.start() }
        await permission.waitUntilRequested()
        await service.stop()
        await permission.resolve(true)

        #expect(!(await start.value))
        #expect(stream.runCount == 0)
        #expect(!service.isTranscribing)
    }

    @Test("stopping before the stream readiness callback cancels the owned stream")
    func earlyStopDuringStreamStart() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .waitWithoutReadiness)
        let service = makeService(fixture: fixture, stream: stream)

        let start = Task { await service.start() }
        await stream.waitUntilRunning()
        await service.stop()

        #expect(!(await start.value))
        #expect(stream.stopCount == 1)
        #expect(!service.isTranscribing)
    }

    @Test("start fails and concurrent stop waits while teardown is owned")
    func startDuringStopDoesNotOverlapReplacement() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let audioSession = ControlledAudioSession()
        let stream = ControlledStream(behavior: .readyUntilStopped, blocksStop: true)
        let service = makeService(fixture: fixture, stream: stream, audioSession: audioSession)

        #expect(await service.start())
        #expect(service.isTranscribing)
        #expect(audioSession.activationCount == 1)

        let stop = Task { await service.stop() }
        await stream.waitUntilStopRequested()
        #expect(!service.isTranscribing)

        let overlappingStart = await service.start()
        #expect(!overlappingStart)
        #expect(stream.runCount == 1)
        #expect(stream.stopCount == 1)
        #expect(audioSession.activationCount == 1)
        #expect(audioSession.deactivationCount == 0)

        let secondStopEntered = ControlledSignal()
        let secondStopProbe = ControlledCallProbe()
        let secondStop = Task {
            secondStopEntered.signal()
            await service.stop()
            secondStopProbe.markReturned()
        }
        await secondStopEntered.wait()
        #expect(!secondStopProbe.didReturn)
        #expect(stream.stopCount == 1)

        stream.releaseStop()
        await stop.value
        await secondStop.value
        #expect(!service.isTranscribing)
        #expect(secondStopProbe.didReturn)
        #expect(audioSession.deactivationCount == 1)
    }

    @Test("cached-model removal waits for active stream teardown")
    func removalWaitsForStopCompletion() async throws {
        let fixture = try ModelCacheFixture()
        defer { fixture.remove() }
        let stream = ControlledStream(behavior: .readyUntilStopped, blocksStop: true)
        let service = makeService(fixture: fixture, stream: stream)

        #expect(await service.start())
        let stop = Task { await service.stop() }
        await stream.waitUntilStopRequested()

        let removalEntered = ControlledSignal()
        let removalProbe = ControlledCallProbe()
        let removal = Task {
            removalEntered.signal()
            await service.removeCachedModel()
            removalProbe.markReturned()
        }
        await removalEntered.wait()
        #expect(!removalProbe.didReturn)
        #expect(service.hasCachedModel)

        stream.releaseStop()
        await stop.value
        await removal.value
        #expect(removalProbe.didReturn)
        #expect(!service.hasCachedModel)
    }

    private func makeService(
        fixture: ModelCacheFixture,
        loader: ControlledModelLoader? = nil,
        permission: @escaping @Sendable () async -> Bool = { true },
        stream: ControlledStream = ControlledStream(behavior: .readyUntilStopped),
        audioSession: ControlledAudioSession? = nil
    ) -> TranscriptionService {
        let entry = fixture.cache.validEntry!
        return TranscriptionService(
            testingCache: fixture.cache,
            modelLoader: { preparation, _ in
                if let loader { return try await loader.load() }
                guard case .loadCached(let cached) = preparation else {
                    throw TestFailure.unexpectedDownload
                }
                return TranscriptionLoadedModel(kit: nil, cacheEntry: cached)
            },
            permissionRequest: permission,
            streamFactory: { loaded, update in
                #expect(loaded.cacheEntry == entry)
                return TranscriptionStreamHandle(
                    run: { try await stream.run(update: update) },
                    stop: { await stream.stop() }
                )
            },
            activateAudioSession: { audioSession?.activate() },
            deactivateAudioSession: { audioSession?.deactivate() }
        )
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        while !predicate() { await Task.yield() }
    }
}

private enum TestFailure: Error {
    case unexpectedDownload
}

private actor ControlledModelLoader {
    let entry: WhisperModelCache.Entry
    private(set) var loadCount = 0
    private var releases: [CheckedContinuation<Void, Never>] = []

    init(entry: WhisperModelCache.Entry) {
        self.entry = entry
    }

    func load() async throws -> TranscriptionLoadedModel {
        loadCount += 1
        await withCheckedContinuation { releases.append($0) }
        return TranscriptionLoadedModel(kit: nil, cacheEntry: entry)
    }

    func waitForLoadCount(_ expected: Int) async {
        while loadCount < expected { await Task.yield() }
    }

    func releaseNext() {
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume()
    }
}

private final class ControlledStream: @unchecked Sendable {
    enum Behavior: Sendable {
        case readyUntilStopped
        case waitWithoutReadiness
        case returnBeforeReady
    }

    private let behavior: Behavior
    private let blocksStop: Bool
    private let lock = NSLock()
    private let continuation: AsyncStream<Void>.Continuation
    private let stream: AsyncStream<Void>
    private var runs = 0
    private var stops = 0
    private var stopReleased = false
    private var stopReleaseContinuation: CheckedContinuation<Void, Never>?

    init(behavior: Behavior, blocksStop: Bool = false) {
        self.behavior = behavior
        self.blocksStop = blocksStop
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    var runCount: Int { lock.withLock { runs } }
    var stopCount: Int { lock.withLock { stops } }

    func run(update: @escaping @Sendable (TranscriptionStreamUpdate) -> Void) async throws {
        lock.withLock { runs += 1 }
        switch behavior {
        case .returnBeforeReady:
            return
        case .readyUntilStopped:
            update(TranscriptionStreamUpdate(
                isRecording: true,
                confirmedText: "",
                partialText: ""
            ))
        case .waitWithoutReadiness:
            break
        }
        for await _ in stream {}
    }

    func stop() async {
        lock.withLock { stops += 1 }
        if blocksStop { await waitForStopRelease() }
        continuation.finish()
    }

    func waitUntilRunning() async {
        while runCount == 0 { await Task.yield() }
    }

    func waitUntilStopRequested() async {
        while stopCount == 0 { await Task.yield() }
    }

    func releaseStop() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            stopReleased = true
            defer { stopReleaseContinuation = nil }
            return stopReleaseContinuation
        }
        pending?.resume()
    }

    private func waitForStopRelease() async {
        await withCheckedContinuation { continuation in
            let alreadyReleased = lock.withLock { () -> Bool in
                guard !stopReleased else { return true }
                stopReleaseContinuation = continuation
                return false
            }
            if alreadyReleased { continuation.resume() }
        }
    }
}

private final class ControlledSignal: @unchecked Sendable {
    private let continuation: AsyncStream<Void>.Continuation
    private let stream: AsyncStream<Void>

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func signal() {
        continuation.yield()
        continuation.finish()
    }

    func wait() async {
        for await _ in stream { return }
    }
}

@MainActor
private final class ControlledCallProbe {
    private(set) var didReturn = false

    func markReturned() {
        didReturn = true
    }
}

@MainActor
private final class ControlledAudioSession: @unchecked Sendable {
    private(set) var activationCount = 0
    private(set) var deactivationCount = 0

    func activate() {
        activationCount += 1
    }

    func deactivate() {
        deactivationCount += 1
    }
}

private actor ControlledPermission {
    private var requested = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func request() async -> Bool {
        requested = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRequested() async {
        while !requested { await Task.yield() }
    }

    func resolve(_ granted: Bool) {
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

private struct ModelCacheFixture {
    let root: URL
    let documents: URL
    let model: URL
    let tokenizer: URL
    let defaults: UserDefaults

    var cache: WhisperModelCache {
        WhisperModelCache(
            defaults: defaults,
            documentsURL: documents,
            fileManager: .default
        )
    }

    init(
        includeDecoder: Bool = true,
        includeTokenizerConfig: Bool = true,
        corruptTokenizer: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blau-transcription-tests-\(UUID().uuidString)", isDirectory: true)
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        model = documents
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(WhisperModelCache.modelName, isDirectory: true)
        tokenizer = documents
            .appendingPathComponent("huggingface/models/openai/whisper-base", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data([1]).write(to: model.appendingPathComponent("MelSpectrogram.mlmodelc"))
        try Data([1]).write(to: model.appendingPathComponent("AudioEncoder.mlmodelc"))
        if includeDecoder {
            try Data([1]).write(to: model.appendingPathComponent("TextDecoder.mlmodelc"))
        }
        let tokenizerJSON = corruptTokenizer
            ? "{}"
            : #"{"model":{"type":"BPE","vocab":{},"merges":[]},"added_tokens":[]}"#
        let tokenizerData = Data(tokenizerJSON.utf8)
        try tokenizerData.write(to: tokenizer.appendingPathComponent("tokenizer.json"))
        if includeTokenizerConfig {
            try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer_config.json"))
        }
        let suite = "app.blau.tests.transcription.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
