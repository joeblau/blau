import Foundation
import OSLog

// SimctlCommands — public-CLI side-effects (create / boot / shutdown / delete).
// Pairs with SimctlList (which only reads). Same buffer-drain discipline:
// always read pipes BEFORE waitUntilExit to avoid deadlocking on output.
//
// All methods are blocking. Call from a background queue (use the
// `runOffMainThread` helper at the bottom).

enum SimctlCommands {
    private static let logger = Logger(subsystem: "app.blau.pilot.simulator", category: "simctl-commands")

    static func createDevice(
        typeIdentifier: String,
        runtimeIdentifier: String,
        name: String
    ) throws -> String {
        let result = run(arguments: ["create", name, typeIdentifier, runtimeIdentifier])
        switch result {
        case .success(let stdout):
            let udid = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !udid.isEmpty else {
                throw SimulatorError.deviceCreateFailed(underlying: "simctl create returned empty UDID")
            }
            return udid
        case .failure(let stderr):
            throw SimulatorError.deviceCreateFailed(underlying: stderr)
        }
    }

    /// Boots a simulator. Idempotent — if it's already booted, returns silently.
    static func boot(udid: String) throws {
        let result = run(arguments: ["boot", udid])
        if case .failure(let stderr) = result {
            if stderr.contains("current state: Booted") { return }
            throw SimulatorError.bootFailed(underlying: stderr)
        }
    }

    /// Shuts down a simulator. Idempotent — if it's already shutdown, returns silently.
    static func shutdown(udid: String) throws {
        let result = run(arguments: ["shutdown", udid])
        if case .failure(let stderr) = result {
            if stderr.contains("current state: Shutdown") { return }
            throw SimulatorError.shutdownFailed(underlying: stderr)
        }
    }

    /// Returns the runtime state of a device ("Booted" / "Shutdown" / "Booting" / etc.)
    /// or nil if the device is not in any DeviceSet.
    static func state(udid: String) -> String? {
        guard case .success(let stdout) = run(arguments: ["list", "devices", udid, "--json"]) else {
            return nil
        }
        guard let data = stdout.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = payload["devices"] as? [String: [[String: Any]]] else {
            return nil
        }
        for (_, devices) in devicesByRuntime {
            if let device = devices.first(where: { ($0["udid"] as? String) == udid }),
               let state = device["state"] as? String {
                return state
            }
        }
        return nil
    }

    static func delete(udid: String) {
        _ = run(arguments: ["delete", udid])
    }

    // MARK: - Off-main runner

    static func runOffMainThread<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private enum RunResult {
        case success(String)
        case failure(String)
    }

    private static func run(arguments: [String]) -> RunResult {
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
            return .failure(error.localizedDescription)
        }
        // Drain pipes BEFORE waitUntilExit (see SimctlList for the why).
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if task.terminationStatus == 0 {
            return .success(stdout)
        }
        logger.error("simctl \(arguments.joined(separator: " ")) exited \(task.terminationStatus): \(stderr)")
        return .failure(stderr.isEmpty ? "simctl exited \(task.terminationStatus)" : stderr)
    }
}
