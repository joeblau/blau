import AVFoundation
import Darwin
import Darwin.Mach
import Foundation
import WhisperKit

private struct Manifest: Decodable {
    let model: String
    let cases: [BenchmarkCase]
}

private struct BenchmarkCase: Decodable {
    let audioPath: String
    let expected: String
}

private struct CaseResult: Codable {
    let audioPath: String
    let expected: String
    let recognized: String
    let audioSeconds: Double
    let transcriptionSeconds: Double
    let realTimeFactor: Double
    let wordErrorRate: Double
}

private struct Report: Codable {
    let sdk: String
    let generatedAt: Date
    let hardware: String
    let operatingSystem: String
    let model: String
    let modelLoadSeconds: Double
    let firstTranscriptionSeconds: Double?
    let meanRealTimeFactor: Double?
    let peakResidentBytes: UInt64
    let commandAccuracy: Double?
    let cases: [CaseResult]
}

private final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "whisper-benchmark.memory"))
    private var peak: UInt64 = 0

    func start() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(25))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let resident = Self.residentBytes()
            self.lock.withLock { self.peak = max(self.peak, resident) }
        }
        timer.resume()
    }

    func stop() -> UInt64 {
        timer.cancel()
        return lock.withLock { peak }
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

@main
private enum WhisperBenchmark {
    static func main() async throws {
        let arguments = try Arguments.parse(CommandLine.arguments)
        let data = try Data(contentsOf: arguments.manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard !manifest.cases.isEmpty else {
            throw BenchmarkError.invalidArguments("The manifest must contain at least one audio case.")
        }

        let sampler = MemorySampler()
        sampler.start()
        let clock = ContinuousClock()
        let loadStart = clock.now
        let kit = try await WhisperKit(WhisperKitConfig(
            model: manifest.model,
            modelFolder: arguments.modelFolder?.path,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: arguments.allowDownload
        ))
        let loadSeconds = seconds(loadStart.duration(to: clock.now))

        guard kit.tokenizer != nil else {
            throw BenchmarkError.incompleteModel
        }

        var results: [CaseResult] = []
        for benchmarkCase in manifest.cases {
            let audioURL = URL(fileURLWithPath: benchmarkCase.audioPath)
            let asset = AVURLAsset(url: audioURL)
            let duration = try await asset.load(.duration).seconds
            let started = clock.now
            let transcription = try await kit.transcribe(
                audioPath: audioURL.path,
                decodeOptions: DecodingOptions(language: "en", usePrefillPrompt: true)
            )
            let elapsed = seconds(started.duration(to: clock.now))
            let recognized = transcription.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(CaseResult(
                audioPath: audioURL.path,
                expected: benchmarkCase.expected,
                recognized: recognized,
                audioSeconds: duration,
                transcriptionSeconds: elapsed,
                realTimeFactor: duration > 0 ? elapsed / duration : 0,
                wordErrorRate: wordErrorRate(expected: benchmarkCase.expected, actual: recognized)
            ))
        }

        let report = Report(
            sdk: "argmax-oss-swift 1.0.0",
            generatedAt: Date(),
            hardware: hardwareModel(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            model: manifest.model,
            modelLoadSeconds: loadSeconds,
            firstTranscriptionSeconds: results.first?.transcriptionSeconds,
            meanRealTimeFactor: results.isEmpty ? nil : results.map(\.realTimeFactor).reduce(0, +) / Double(results.count),
            peakResidentBytes: sampler.stop(),
            commandAccuracy: results.isEmpty ? nil : 1 - results.map(\.wordErrorRate).reduce(0, +) / Double(results.count),
            cases: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let output = try encoder.encode(report)
        try output.write(to: arguments.outputURL, options: .atomic)
        print(arguments.outputURL.path)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func wordErrorRate(expected: String, actual: String) -> Double {
        let lhs = words(expected)
        let rhs = words(actual)
        guard !lhs.isEmpty else { return rhs.isEmpty ? 0 : 1 }
        var prior = Array(0...rhs.count)
        for (leftIndex, leftWord) in lhs.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightWord) in rhs.enumerated() {
                current.append(min(
                    prior[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    prior[rightIndex] + (leftWord == rightWord ? 0 : 1)
                ))
            }
            prior = current
        }
        return min(Double(prior[rhs.count]) / Double(lhs.count), 1)
    }

    private static func words(_ value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

private struct Arguments {
    let manifestURL: URL
    let outputURL: URL
    let modelFolder: URL?
    let allowDownload: Bool

    static func parse(_ values: [String]) throws -> Arguments {
        var manifest: URL?
        var output: URL?
        var modelFolder: URL?
        var allowDownload = false
        var index = 1
        while index < values.count {
            switch values[index] {
            case "--manifest":
                index += 1
                guard index < values.count else { throw BenchmarkError.invalidArguments("Missing --manifest value") }
                manifest = URL(fileURLWithPath: values[index])
            case "--output":
                index += 1
                guard index < values.count else { throw BenchmarkError.invalidArguments("Missing --output value") }
                output = URL(fileURLWithPath: values[index])
            case "--model-folder":
                index += 1
                guard index < values.count else { throw BenchmarkError.invalidArguments("Missing --model-folder value") }
                modelFolder = URL(fileURLWithPath: values[index])
            case "--download":
                allowDownload = true
            default:
                throw BenchmarkError.invalidArguments("Unknown argument: \(values[index])")
            }
            index += 1
        }
        guard let manifest, let output else {
            throw BenchmarkError.invalidArguments(
                "Usage: WhisperBenchmark --manifest cases.json --output report.json [--model-folder PATH | --download]"
            )
        }
        guard modelFolder != nil || allowDownload else {
            throw BenchmarkError.invalidArguments("Pass a cached --model-folder or explicitly consent with --download")
        }
        return Arguments(
            manifestURL: manifest,
            outputURL: output,
            modelFolder: modelFolder,
            allowDownload: allowDownload
        )
    }
}

private enum BenchmarkError: LocalizedError {
    case invalidArguments(String)
    case incompleteModel

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): message
        case .incompleteModel: "The loaded model has no tokenizer. Remove the cache and retry."
        }
    }
}
