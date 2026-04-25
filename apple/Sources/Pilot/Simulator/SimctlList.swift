import Foundation
import OSLog

// SimctlList — thin wrapper around `xcrun simctl list ... --json`.
// Public CLI, no SPI required. Used by SimulatorDeviceSet to populate
// the device picker even before the CoreSimulator SPI is fully wired.

enum SimctlList {
    private static let logger = Logger(subsystem: "app.blau.pilot.simulator", category: "simctl")

    /// Returns available iOS runtimes (deduplicated by identifier).
    static func iOSRuntimes() -> [SimulatorRuntimeInfo] {
        guard let payload = runJSON(arguments: ["list", "runtimes", "--json"]) else {
            return []
        }
        guard let rawRuntimes = payload["runtimes"] as? [[String: Any]] else {
            return []
        }
        var seen = Set<String>()
        var result: [SimulatorRuntimeInfo] = []
        for item in rawRuntimes {
            guard let platform = item["platform"] as? String, platform == "iOS",
                  let identifier = item["identifier"] as? String,
                  let name = item["name"] as? String else { continue }
            if seen.contains(identifier) { continue }
            seen.insert(identifier)
            let isAvailable = (item["isAvailable"] as? Bool) ?? false
            result.append(SimulatorRuntimeInfo(
                identifier: identifier,
                displayName: name,
                isAvailable: isAvailable
            ))
        }
        // Preserve simctl's natural order (newest first for runtimes).
        return result
    }

    /// Returns available device types filtered to iPhone + iPad families.
    /// simctl returns these in newest-first order; we preserve it.
    static func iPhoneAndIPadDeviceTypes() -> [SimulatorDeviceTypeInfo] {
        guard let payload = runJSON(arguments: ["list", "devicetypes", "--json"]) else {
            return []
        }
        guard let rawTypes = payload["devicetypes"] as? [[String: Any]] else {
            return []
        }
        var seen = Set<String>()
        var iphones: [SimulatorDeviceTypeInfo] = []
        var ipads: [SimulatorDeviceTypeInfo] = []
        for item in rawTypes {
            guard let family = item["productFamily"] as? String,
                  family == "iPhone" || family == "iPad",
                  let identifier = item["identifier"] as? String,
                  let name = item["name"] as? String else { continue }
            if seen.contains(identifier) { continue }
            seen.insert(identifier)
            let info = SimulatorDeviceTypeInfo(identifier: identifier, displayName: name)
            if family == "iPhone" { iphones.append(info) } else { ipads.append(info) }
        }
        // iPhone first, then iPad. Each preserves simctl's newest-first order.
        return iphones + ipads
    }

    // MARK: - Private runner

    private static func runJSON(arguments: [String]) -> [String: Any]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = ["simctl"] + arguments
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
        } catch {
            logger.error("simctl spawn failed: \(error.localizedDescription)")
            return nil
        }
        // CRITICAL: Read the pipe BEFORE waitUntilExit. simctl's output can
        // exceed 100KB (the runtimes JSON is ~124KB on a typical Mac with
        // multiple iOS runtimes). If we wait first, the child process blocks
        // writing to a full pipe and we deadlock.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            logger.error("simctl \(arguments.joined(separator: " ")) exited \(task.terminationStatus): \(errText)")
            return nil
        }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            logger.error("simctl JSON parse failed: \(error.localizedDescription)")
            return nil
        }
    }
}
