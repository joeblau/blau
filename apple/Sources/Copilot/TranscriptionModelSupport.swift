import Foundation
import Network

enum TranscriptionNetworkStatus: Sendable, Equatable {
    case unknown
    case offline
    case unmetered
    case expensive
    case constrained
}

enum TranscriptionModelPreparation: Equatable {
    case loadCached(WhisperModelCache.Entry)
    case download
}

enum TranscriptionModelPreparationError: LocalizedError, Equatable {
    case networkStatusUnavailable
    case offline
    case expensiveNetwork
    case constrainedNetwork

    var errorDescription: String? {
        switch self {
        case .networkStatusUnavailable:
            "The iPhone is still checking the network. Wait a moment and retry the speech-model download."
        case .offline:
            "The speech model is not cached and the iPhone is offline. Connect to Wi-Fi and retry."
        case .expensiveNetwork:
            "The speech model is about 150 MB. Connect to Wi-Fi or choose Use Cellular when you retry."
        case .constrainedNetwork:
            "Low Data Mode is active. Connect to an unrestricted network or explicitly allow this download."
        }
    }
}

struct TranscriptionDownloadPolicy {
    static func preparation(
        cachedEntry: WhisperModelCache.Entry?,
        network: TranscriptionNetworkStatus,
        allowRestrictedNetwork: Bool
    ) throws -> TranscriptionModelPreparation {
        if let cachedEntry {
            return .loadCached(cachedEntry)
        }
        switch network {
        case .offline:
            throw TranscriptionModelPreparationError.offline
        case .expensive where !allowRestrictedNetwork:
            throw TranscriptionModelPreparationError.expensiveNetwork
        case .constrained where !allowRestrictedNetwork:
            throw TranscriptionModelPreparationError.constrainedNetwork
        case .unknown:
            throw TranscriptionModelPreparationError.networkStatusUnavailable
        case .unmetered, .expensive, .constrained:
            return .download
        }
    }
}

final class TranscriptionNetworkObserver: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "app.blau.copilot.transcription-network")
    private let lock = NSLock()
    private var value: TranscriptionNetworkStatus = .unknown

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let next: TranscriptionNetworkStatus
            if path.status != .satisfied {
                next = .offline
            } else if path.isConstrained {
                next = .constrained
            } else if path.isExpensive {
                next = .expensive
            } else {
                next = .unmetered
            }
            self?.lock.withLock { self?.value = next }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    var status: TranscriptionNetworkStatus {
        lock.withLock { value }
    }
}

/// Persists the exact variant folder returned by WhisperKit. The fallback path
/// is the cache layout shared by WhisperKit 0.18 and Argmax OSS 1.0, allowing an
/// existing model to migrate without another transfer.
struct WhisperModelCache: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let modelFolder: URL
        let tokenizerFolder: URL
    }

    static let modelName = "openai_whisper-base"
    private static let pathKey = "transcription.cachedModelPath.v1"
    private static let requiredModelNames = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
    private static let requiredTokenizerJSONNames = ["tokenizer.json", "tokenizer_config.json"]

    let defaults: UserDefaults
    let documentsURL: URL
    let fileManager: FileManager

    init(
        defaults: UserDefaults = .standard,
        documentsURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.documentsURL = documentsURL
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    var tokenizerFolder: URL {
        modelsFolder
            .appendingPathComponent("openai", isDirectory: true)
            .appendingPathComponent("whisper-base", isDirectory: true)
    }

    /// Argmax treats this value as a Hugging Face cache root while downloading.
    /// Its Hub client appends the `models` repository type before the repository
    /// identifier, so this must remain the parent of `modelsFolder`.
    /// Cached loads instead receive `Entry.tokenizerFolder`, the exact repository
    /// folder, after its local JSON has been validated.
    var tokenizerDownloadBase: URL {
        documentsURL.appendingPathComponent("huggingface", isDirectory: true)
    }

    var validEntry: Entry? {
        if let stored = defaults.string(forKey: Self.pathKey) {
            let url = URL(fileURLWithPath: stored)
            if isCompleteModel(at: url), isCompleteTokenizer(at: tokenizerFolder) {
                return Entry(modelFolder: url, tokenizerFolder: tokenizerFolder)
            }
        }

        let legacyCompatibleURL = modelsFolder
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(Self.modelName, isDirectory: true)
        guard isCompleteModel(at: legacyCompatibleURL),
              isCompleteTokenizer(at: tokenizerFolder) else { return nil }
        defaults.set(legacyCompatibleURL.path, forKey: Self.pathKey)
        return Entry(modelFolder: legacyCompatibleURL, tokenizerFolder: tokenizerFolder)
    }

    func remember(_ url: URL) {
        defaults.set(url.path, forKey: Self.pathKey)
    }

    var storedBytes: Int64 {
        guard let entry = validEntry else { return 0 }
        return bytes(in: entry.modelFolder) + bytes(in: entry.tokenizerFolder)
    }

    func remove() throws {
        var firstError: Error?
        let modelURL = defaults.string(forKey: Self.pathKey).map(URL.init(fileURLWithPath:))
            ?? modelsFolder
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(Self.modelName, isDirectory: true)
        for url in [modelURL, tokenizerFolder] where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                firstError = firstError ?? error
            }
        }
        defaults.removeObject(forKey: Self.pathKey)
        if let firstError { throw firstError }
    }

    func isCompleteModel(at url: URL) -> Bool {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        var found: Set<String> = []
        for case let item as URL in enumerator {
            let name = item.deletingPathExtension().lastPathComponent
            if Self.requiredModelNames.contains(name) {
                found.insert(name)
            }
        }
        return found.count == Self.requiredModelNames.count
    }

    func isCompleteTokenizer(at url: URL) -> Bool {
        Self.requiredTokenizerJSONNames.allSatisfy { name in
            let file = url.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file), !data.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return name != "tokenizer.json" || object["model"] is [String: Any]
        }
    }

    func isComplete(_ entry: Entry) -> Bool {
        isCompleteModel(at: entry.modelFolder)
            && entry.tokenizerFolder.standardizedFileURL == tokenizerFolder.standardizedFileURL
            && isCompleteTokenizer(at: entry.tokenizerFolder)
    }

    private var modelsFolder: URL {
        tokenizerDownloadBase
            .appendingPathComponent("models", isDirectory: true)
    }

    private func bytes(in root: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

struct TranscriptionLoadGate {
    private(set) var isLoading = false

    mutating func begin() -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        return true
    }

    mutating func finish() {
        isLoading = false
    }

    mutating func cancel() {
        isLoading = false
    }
}
