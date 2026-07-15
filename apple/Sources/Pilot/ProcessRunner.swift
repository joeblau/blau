import Darwin
import Foundation

/// An argument-array-only subprocess invocation. Diagnostics deliberately omit
/// the environment and can redact selected arguments before they reach logs.
struct ProcessInvocation: Sendable {
    var executableURL: URL
    var arguments: [String] = []
    var currentDirectoryURL: URL?
    var environment: [String: String]?
    var timeout: Duration = .seconds(15)
    var terminationGracePeriod: Duration = .milliseconds(250)
    var standardOutputLimit = 2 * 1_024 * 1_024
    var standardErrorLimit = 256 * 1_024
    var redactedArgumentIndexes: Set<Int> = []

    init(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(15),
        terminationGracePeriod: Duration = .milliseconds(250),
        standardOutputLimit: Int = 2 * 1_024 * 1_024,
        standardErrorLimit: Int = 256 * 1_024,
        redactedArgumentIndexes: Set<Int> = []
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.standardOutputLimit = standardOutputLimit
        self.standardErrorLimit = standardErrorLimit
        self.redactedArgumentIndexes = redactedArgumentIndexes
    }

    /// A PATH that covers system and common Homebrew developer-tool installs.
    static func developerTool(
        _ command: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        timeout: Duration = .seconds(15),
        standardOutputLimit: Int = 2 * 1_024 * 1_024,
        standardErrorLimit: Int = 256 * 1_024
    ) -> ProcessInvocation {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"
            + (environment["PATH"] ?? "")
        return ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [command] + arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment,
            timeout: timeout,
            standardOutputLimit: standardOutputLimit,
            standardErrorLimit: standardErrorLimit
        )
    }

    var redactedCommand: String {
        let rendered = arguments.enumerated().map { index, argument in
            redactedArgumentIndexes.contains(index) ? "<redacted>" : Self.shellQuoted(argument)
        }
        return ([Self.shellQuoted(executableURL.path)] + rendered).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:=@"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct ProcessRunResult: Sendable {
    enum Termination: Sendable, Equatable {
        case exit(Int32)
        case signal(Int32)
    }

    let termination: Termination
    let standardOutput: Data
    let standardError: Data
    let standardOutputTruncated: Bool
    let standardErrorTruncated: Bool
    let elapsed: Duration
    let redactedCommand: String

    var standardOutputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var standardErrorString: String {
        String(decoding: standardError, as: UTF8.self)
    }

    /// Safe for logs: output and environment values are never interpolated.
    var diagnosticSummary: String {
        let status: String
        switch termination {
        case .exit(let code): status = "exit=\(code)"
        case .signal(let signal): status = "signal=\(signal)"
        }
        let truncation = standardOutputTruncated || standardErrorTruncated ? " output=truncated" : ""
        return "\(redactedCommand) [\(status)\(truncation)]"
    }
}

enum ProcessRunnerError: Error, Sendable, LocalizedError {
    case launch(command: String, message: String)
    case nonZeroExit(ProcessRunResult)
    case timedOut(ProcessRunResult)
    case cancelled(ProcessRunResult)
    case outputTruncated(ProcessRunResult)

    var result: ProcessRunResult? {
        switch self {
        case .launch: nil
        case .nonZeroExit(let result), .timedOut(let result), .cancelled(let result),
             .outputTruncated(let result): result
        }
    }

    var errorDescription: String? {
        switch self {
        case .launch(let command, let message):
            "Could not launch \(command): \(message)"
        case .nonZeroExit(let result):
            "Command failed: \(result.diagnosticSummary)"
        case .timedOut(let result):
            "Command timed out: \(result.diagnosticSummary)"
        case .cancelled(let result):
            "Command cancelled: \(result.diagnosticSummary)"
        case .outputTruncated(let result):
            "Command exceeded its output limit: \(result.diagnosticSummary)"
        }
    }
}

/// Runs developer tools without a shell, bounding both output streams and
/// reliably stopping children when the Swift task is cancelled or times out.
enum ProcessRunner {
    static func run(_ invocation: ProcessInvocation) async throws -> ProcessRunResult {
        let control = ProcessControl(gracePeriod: invocation.terminationGracePeriod)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try execute(invocation, control: control)
            }.value
        } onCancel: {
            control.requestStop(.cancelled)
        }
    }

    /// Compatibility bridge for synchronous framework APIs. New call sites
    /// should prefer `run`; both paths use the same bounded implementation.
    static func runBlocking(_ invocation: ProcessInvocation) throws -> ProcessRunResult {
        try execute(
            invocation,
            control: ProcessControl(gracePeriod: invocation.terminationGracePeriod),
            cancellationProbe: {
                withUnsafeCurrentTask { $0?.isCancelled ?? false }
            }
        )
    }

    private static func execute(
        _ invocation: ProcessInvocation,
        control: ProcessControl,
        cancellationProbe: (() -> Bool)? = nil
    ) throws -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.currentDirectoryURL
        if let environment = invocation.environment { process.environment = environment }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdout = OutputCapture(limit: invocation.standardOutputLimit)
        let stderr = OutputCapture(limit: invocation.standardErrorLimit)
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.drain(stdoutPipe.fileHandleForReading)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.drain(stderrPipe.fileHandleForReading)
            readers.leave()
        }

        let started = ContinuousClock.now
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            readers.wait()
            throw ProcessRunnerError.launch(
                command: invocation.redactedCommand,
                message: error.localizedDescription
            )
        }

        control.register(processIdentifier: process.processIdentifier)
        let timeout = DispatchWorkItem { control.requestStop(.timedOut) }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + invocation.timeout.timeInterval,
            execute: timeout
        )

        if let cancellationProbe {
            while process.isRunning {
                if cancellationProbe() { control.requestStop(.cancelled) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        process.waitUntilExit()
        timeout.cancel()
        let stopReason = control.finish()
        readers.wait()

        let termination: ProcessRunResult.Termination = switch process.terminationReason {
        case .exit: .exit(process.terminationStatus)
        case .uncaughtSignal: .signal(process.terminationStatus)
        @unknown default: .signal(process.terminationStatus)
        }
        let stdoutSnapshot = stdout.snapshot()
        let stderrSnapshot = stderr.snapshot()
        let result = ProcessRunResult(
            termination: termination,
            standardOutput: stdoutSnapshot.data,
            standardError: stderrSnapshot.data,
            standardOutputTruncated: stdoutSnapshot.truncated,
            standardErrorTruncated: stderrSnapshot.truncated,
            elapsed: started.duration(to: .now),
            redactedCommand: invocation.redactedCommand
        )

        switch stopReason {
        case .cancelled: throw ProcessRunnerError.cancelled(result)
        case .timedOut: throw ProcessRunnerError.timedOut(result)
        case nil: break
        }
        if result.standardOutputTruncated || result.standardErrorTruncated {
            throw ProcessRunnerError.outputTruncated(result)
        }
        guard result.termination == .exit(0) else {
            throw ProcessRunnerError.nonZeroExit(result)
        }
        return result
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func drain(_ handle: FileHandle) {
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 16 * 1_024), !next.isEmpty else { break }
                chunk = next
            } catch {
                break
            }
            lock.lock()
            let remaining = max(0, limit - data.count)
            if remaining > 0 { data.append(chunk.prefix(remaining)) }
            if chunk.count > remaining { truncated = true }
            lock.unlock()
        }
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, truncated)
    }
}

private final class ProcessControl: @unchecked Sendable {
    enum StopReason {
        case cancelled
        case timedOut
    }

    private let lock = NSLock()
    private let gracePeriod: Duration
    private var processIdentifier: pid_t?
    private var requestedStop: StopReason?
    private var finished = false

    init(gracePeriod: Duration) {
        self.gracePeriod = gracePeriod
    }

    func register(processIdentifier: pid_t) {
        lock.lock()
        self.processIdentifier = processIdentifier
        let shouldStop = requestedStop != nil && !finished
        lock.unlock()
        if shouldStop { terminateThenKill(processIdentifier) }
    }

    func requestStop(_ reason: StopReason) {
        lock.lock()
        guard requestedStop == nil else {
            lock.unlock()
            return
        }
        requestedStop = reason
        let pid = finished ? nil : processIdentifier
        lock.unlock()
        if let pid { terminateThenKill(pid) }
    }

    func finish() -> StopReason? {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        processIdentifier = nil
        return requestedStop
    }

    private func terminateThenKill(_ pid: pid_t) {
        Darwin.kill(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + gracePeriod.timeInterval
        ) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldKill = !self.finished && self.processIdentifier == pid
            self.lock.unlock()
            if shouldKill { Darwin.kill(pid, SIGKILL) }
        }
    }
}
