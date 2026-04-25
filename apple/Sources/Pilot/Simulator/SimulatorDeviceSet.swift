import Foundation
import OSLog

// SimulatorDeviceSet — Pilot-owned device pool at
//   ~/Library/Application Support/Pilot/CoreSimulator/Devices/
// with `Runtimes/` symlinked to Xcode's shared Developer dir so we avoid
// downloading multiple copies of iOS runtimes.
//
// Isolating from Xcode's default set prevents double-boot conflicts when
// the user has Xcode open on the same device.
//
// TODO(spi): The current implementation sets up the disk layout only.
// The live `SimDeviceSet` instance is obtained via:
//   SimServiceContext.sharedServiceContext(forDeveloperDir:error:) ->
//     .deviceSet(at: path, error:)
// Wire this up when porting SPI calls from fb-idb.

@MainActor
final class SimulatorDeviceSet {
    let rootURL: URL
    private let spi: CoreSimulatorSPI
    private let logger = Logger(subsystem: "app.blau.pilot.simulator", category: "device-set")

    init(spi: CoreSimulatorSPI) throws {
        self.spi = spi
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let devicesDir = support
            .appendingPathComponent("Pilot", isDirectory: true)
            .appendingPathComponent("CoreSimulator", isDirectory: true)
            .appendingPathComponent("Devices", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: devicesDir, withIntermediateDirectories: true)
        } catch {
            throw SimulatorError.deviceSetInitFailed(underlying: error.localizedDescription)
        }

        self.rootURL = devicesDir
        try ensureRuntimeSymlink()
    }

    private func ensureRuntimeSymlink() throws {
        guard let developer = spi.xcodeDeveloperPath else {
            throw SimulatorError.xcodeNotFound
        }
        let parent = rootURL.deletingLastPathComponent()
        let linkURL = parent.appendingPathComponent("Runtimes", isDirectory: true)
        let target = "\(developer)/Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/Runtimes"

        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: linkURL.path),
           let type = attrs[.type] as? FileAttributeType
        {
            if type == .typeSymbolicLink { return }
            try fm.removeItem(at: linkURL)
        }

        do {
            try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target)
        } catch {
            logger.warning("Could not create runtime symlink: \(error.localizedDescription)")
        }
    }

    /// Returns a `SimulatorDevice` wrapper for the given UDID.
    /// TODO(spi): Obtain the real `SimDevice` via
    ///   SimDeviceSet.deviceWithUDID(udid) and pass it to SimulatorDevice.init(simDevice:).
    func device(forUDID udid: String) throws -> SimulatorDevice {
        return SimulatorDevice(udid: udid, devicesRoot: rootURL)
    }

    /// Returns UDIDs of devices currently in the `booted` state.
    /// TODO(spi): Query live SimDeviceSet.devices and filter by state == booted.
    /// Until SPI is wired, returns empty (no orphans to reap).
    func bootedDeviceUDIDs() -> Set<String> {
        return []
    }

    // MARK: - Device type / runtime listing
    //
    // TODO(spi): Enumerate via SimServiceContext.supportedDeviceTypes and
    // .supportedRuntimes, filtered to runtimes that are actually installed.
    // Used by SimulatorDevicePicker.

    func availableDeviceTypes() -> [SimulatorDeviceTypeInfo] {
        let live = SimctlList.iPhoneAndIPadDeviceTypes()
        return live.isEmpty ? SimulatorDeviceTypeInfo.fallbackList : live
    }

    func availableRuntimes() -> [SimulatorRuntimeInfo] {
        return SimctlList.iOSRuntimes()
    }

    func createDevice(typeIdentifier: String, runtimeIdentifier: String, name: String) throws -> String {
        throw SimulatorError.spiUnavailable(symbol: "SimDeviceSet.createDeviceWithType:runtime:name:error:")
    }
}

struct SimulatorDeviceTypeInfo: Sendable, Identifiable, Hashable {
    var id: String { identifier }
    let identifier: String
    let displayName: String

    static let fallbackList: [SimulatorDeviceTypeInfo] = [
        .init(identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro", displayName: "iPhone 15 Pro"),
        .init(identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-15", displayName: "iPhone 15"),
        .init(identifier: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4", displayName: "iPad Pro 11-inch (M4)"),
    ]
}

struct SimulatorRuntimeInfo: Sendable, Identifiable, Hashable {
    var id: String { identifier }
    let identifier: String
    let displayName: String
    let isAvailable: Bool
}
