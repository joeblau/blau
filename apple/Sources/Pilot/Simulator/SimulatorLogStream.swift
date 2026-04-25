import Foundation
import OSLog

// SimulatorLogStream — spawns `xcrun simctl spawn <udid> log stream` and
// pipes lines to the pane's log viewer. This is the one part of the
// module that does NOT need private SPI — `simctl` is a public CLI.
//
// Ring buffer: last 10,000 lines in memory, older lines rolled off.

@MainActor
final class SimulatorLogStream {
    let udid: String

    private let logger = Logger(subsystem: "app.blau.pilot.simulator", category: "log-stream")
    private var process: Process?
    private var outputPipe: Pipe?
    private(set) var lines: [String] = []
    private let maxLines = 10_000

    weak var delegate: SimulatorLogStreamDelegate?

    init(udid: String) {
        self.udid = udid
    }

    func start() {
        guard process == nil else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = ["simctl", "spawn", udid, "log", "stream", "--style", "compact"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendOutput(text)
            }
        }

        do {
            try task.run()
            self.process = task
            self.outputPipe = pipe
            task.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.handleTermination()
                }
            }
        } catch {
            logger.error("Could not spawn simctl log stream: \(error.localizedDescription)")
        }
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        outputPipe = nil
    }

    private func appendOutput(_ text: String) {
        let newLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in newLines where !line.isEmpty {
            lines.append(line)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            delegate?.logStream(self, didAppendLine: line)
        }
    }

    private func handleTermination() {
        delegate?.logStreamDidEnd(self)
        process = nil
    }
}

@MainActor
protocol SimulatorLogStreamDelegate: AnyObject {
    func logStream(_ stream: SimulatorLogStream, didAppendLine line: String)
    func logStreamDidEnd(_ stream: SimulatorLogStream)
}
