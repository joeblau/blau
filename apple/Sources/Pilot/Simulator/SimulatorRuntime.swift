import AppKit
import Combine
import Foundation
import OSLog

// ─────────────────────────────────────────────────────────────────────────
// SimulatorRuntime — @MainActor singleton coordinating all simulator work.
//
//   [dlopen private frameworks]
//         │
//         ▼
//   ┌────────────────────┐     ┌──────────────────────────────┐
//   │  SimulatorRuntime  │────▶│  SimDeviceSet (Pilot-owned)  │
//   │  (@MainActor)      │     │  ~/Library/Application       │
//   │                    │     │   Support/Pilot/CoreSim/     │
//   │                    │     │   Devices/                   │
//   └─────────┬──────────┘     └──────────────────────────────┘
//             │
//             │ XPC via SimServiceContext
//             ▼
//   ┌────────────────────────────────┐
//   │ com.apple.CoreSimulator.       │
//   │ CoreSimulatorService           │
//   └────────────────────────────────┘
//             │
//             ▼
//   ┌────────────────────┐
//   │ SimDevice (port)   │ ──▶ framebuffer + HID + logs
//   └────────────────────┘
//
// The SPI surface (SimServiceContext, SimDeviceSet, SimDevice) is
// accessed via dlopen / NSClassFromString so a missing symbol on a new
// macOS degrades gracefully via `SimulatorError.spiUnavailable`.
//
// See NOTICE (repo root): structure ported from fb-idb / FBSimulatorControl.
// ─────────────────────────────────────────────────────────────────────────

@MainActor
final class SimulatorRuntime {
    static let shared = SimulatorRuntime()

    private let logger = Logger(subsystem: "app.blau.pilot.simulator", category: "runtime")
    private let spi = CoreSimulatorSPI()
    private var deviceSet: SimulatorDeviceSet?
    private var activeDevices: [String: SimulatorDevice] = [:] // udid -> device

    private init() {}

    // MARK: - Probe

    func probe() throws {
        try spi.loadFrameworksIfNeeded()
        try spi.probeRequiredSymbols()
        logger.info("CoreSimulator SPI probe succeeded")
    }

    // MARK: - Device set

    func sharedDeviceSet() throws -> SimulatorDeviceSet {
        if let existing = deviceSet {
            return existing
        }
        try probe()
        let created = try SimulatorDeviceSet(spi: spi)
        deviceSet = created
        return created
    }

    // MARK: - Boot / shutdown

    func boot(udid: String) async throws -> SimulatorDevice {
        if let existing = activeDevices[udid] {
            return existing
        }
        let set = try sharedDeviceSet()
        let device = try set.device(forUDID: udid)
        try await device.boot()
        activeDevices[udid] = device
        return device
    }

    func shutdown(udid: String) async {
        guard let device = activeDevices.removeValue(forKey: udid) else { return }
        do {
            try await device.shutdown()
        } catch {
            logger.error("Shutdown failed for \(udid): \(String(describing: error))")
        }
    }

    func shutdownAll() async {
        let devices = Array(activeDevices.values)
        activeDevices.removeAll()
        for device in devices {
            do {
                try await device.shutdown()
            } catch {
                logger.error("Shutdown-all failed for \(device.udid): \(String(describing: error))")
            }
        }
    }

    // MARK: - Orphan reaper

    /// Shuts down any booted devices in Pilot's DeviceSet that have no active pane.
    /// Called at Pilot launch to clean up after a prior crash.
    func reapOrphans(activePaneUDIDs: Set<String>) async {
        guard let set = try? sharedDeviceSet() else { return }
        let booted = set.bootedDeviceUDIDs()
        let orphans = booted.subtracting(activePaneUDIDs)
        for udid in orphans {
            logger.notice("Reaping orphan simulator \(udid)")
            do {
                let device = try set.device(forUDID: udid)
                try await device.shutdown()
            } catch {
                logger.error("Orphan shutdown failed for \(udid): \(String(describing: error))")
            }
        }
    }

    // MARK: - Off-main-thread entry points
    //
    // These all dispatch to a background queue. They use `simctl` (public CLI)
    // for create / boot / shutdown, which keeps the entire user-facing flow
    // working without depending on the private CoreSimulator SPI. The private
    // SPI is only needed for framebuffer streaming and HID input injection,
    // both of which remain TODOs in the framebuffer + input modules.

    nonisolated func createDeviceOffMainThread(
        typeIdentifier: String,
        runtimeIdentifier: String,
        name: String
    ) async throws -> String {
        try await SimctlCommands.runOffMainThread {
            try SimctlCommands.createDevice(
                typeIdentifier: typeIdentifier,
                runtimeIdentifier: runtimeIdentifier,
                name: name
            )
        }
    }

    nonisolated func bootOffMainThread(udid: String) async throws {
        try await SimctlCommands.runOffMainThread {
            try SimctlCommands.boot(udid: udid)
        }
    }

    nonisolated func shutdownOffMainThread(udid: String) async {
        do {
            try await SimctlCommands.runOffMainThread {
                try SimctlCommands.shutdown(udid: udid)
            }
        } catch {
            // Logged in SimctlCommands; shutdown failures are non-fatal.
        }
    }

    nonisolated func deviceState(udid: String) async -> String? {
        try? await SimctlCommands.runOffMainThread {
            SimctlCommands.state(udid: udid)
        }
    }

    // MARK: - Diagnostics dump

    func diagnosticsDump() -> String {
        var lines: [String] = []
        lines.append("Pilot Simulator Diagnostics — \(Date())")
        lines.append("Xcode path: \(spi.xcodeDeveloperPath ?? "<not found>")")
        lines.append("CoreSimulator loaded: \(spi.isCoreSimulatorLoaded)")
        lines.append("SimulatorKit loaded: \(spi.isSimulatorKitLoaded)")
        lines.append("Device set path: \(deviceSet?.rootURL.path ?? "<not initialized>")")
        lines.append("Active devices: \(activeDevices.keys.sorted().joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Private-framework SPI gateway
//
// Centralizes dlopen + NSClassFromString + dlsym so the rest of the module
// does not sprinkle private API references. Every SPI lookup is probed and
// surfaced as `SimulatorError.spiUnavailable(symbol:)` on failure.
//
// TODO(spi): Implement symbol resolution by porting from
//   fb-idb's FBControlCore (FBCoreSimulatorNotifier, FBSimDeviceNotifier)
//   and FBSimulatorControl (FBSimulator, FBSimulatorBootConfiguration).
//   License: Apache 2.0. See NOTICE file.

final class CoreSimulatorSPI {
    private(set) var isCoreSimulatorLoaded = false
    private(set) var isSimulatorKitLoaded = false
    private(set) var xcodeDeveloperPath: String?

    private let logger = Logger(subsystem: "app.blau.pilot.simulator", category: "spi")

    func loadFrameworksIfNeeded() throws {
        if isCoreSimulatorLoaded { return }
        let developer = try locateXcodeDeveloperDirectory()
        xcodeDeveloperPath = developer

        // CoreSimulator.framework search order:
        //   1. System-wide (Xcode 14+ on macOS — shared by Xcode, simctl, idb)
        //   2. Inside Xcode.app (legacy)
        let coreSimulatorCandidates = [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(developer)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
        ]

        var loaded = false
        var attemptedPaths: [String] = []
        var lastDlerror: String?
        for path in coreSimulatorCandidates {
            attemptedPaths.append(path)
            if !FileManager.default.fileExists(atPath: path) { continue }
            if dlopen(path, RTLD_NOW) != nil {
                loaded = true
                logger.info("Loaded CoreSimulator from \(path)")
                break
            }
            if let err = dlerror() {
                lastDlerror = String(cString: err)
            }
        }

        guard loaded else {
            let detail = "Tried: \(attemptedPaths.joined(separator: ", "))."
                + (lastDlerror.map { " Last dlerror: \($0)" } ?? "")
            throw SimulatorError.frameworkLoadFailed(path: "CoreSimulator.framework", detail: detail)
        }
        isCoreSimulatorLoaded = true

        // SimulatorKit.framework lives inside Xcode.app on every version.
        let simulatorKitPath = "\(developer)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        if FileManager.default.fileExists(atPath: simulatorKitPath),
           dlopen(simulatorKitPath, RTLD_NOW) != nil
        {
            isSimulatorKitLoaded = true
        } else {
            logger.warning("SimulatorKit.framework not loadable at \(simulatorKitPath) — framebuffer features will be disabled")
        }
    }

    func probeRequiredSymbols() throws {
        // Required classes (fatal if missing)
        let requiredClasses = [
            "SimServiceContext",
            "SimDeviceSet",
            "SimDevice",
            "SimRuntime",
            "SimDeviceType",
        ]
        for name in requiredClasses {
            guard NSClassFromString(name) != nil else {
                throw SimulatorError.spiUnavailable(symbol: name)
            }
        }
    }

    private func locateXcodeDeveloperDirectory() throws -> String {
        if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           FileManager.default.fileExists(atPath: override)
        {
            return override
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        task.arguments = ["-p"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            throw SimulatorError.xcodeNotFound
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty, FileManager.default.fileExists(atPath: output) else {
            throw SimulatorError.xcodeNotFound
        }
        return output
    }
}
