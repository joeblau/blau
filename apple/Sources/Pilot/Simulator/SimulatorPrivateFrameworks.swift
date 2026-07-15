import Foundation

/// Loads Apple's private simulator frameworks (CoreSimulator + SimulatorKit) and
/// resolves a booted `SimDevice` by UDID, all through the Obj-C runtime
/// (`NSClassFromString` / selectors) — never linked or imported, so the binary
/// carries no version-specific `@rpath` load command.
///
/// This is the same approach idb / serve-sim use. It is **private API**: fine for
/// a developer tool (not App Store), and the framework paths are guarded for the
/// Xcode 27 relocation of SimulatorKit into `Contents/SharedFrameworks`.
enum SimPrivateFrameworks {
    /// `xcode-select -p`, e.g. `/Applications/Xcode.app/Contents/Developer`.
    static func developerDir() -> String {
        let fallback = "/Applications/Xcode.app/Contents/Developer"
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcode-select"),
            arguments: ["-p"],
            timeout: .seconds(5),
            standardOutputLimit: 16 * 1_024
        )
        guard let result = try? ProcessRunner.runBlocking(invocation) else { return fallback }
        let directory = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.isEmpty ? fallback : directory
    }

    private static let loadOnce: Void = {
        let dev = developerDir()
        let candidates = [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(dev)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(dev)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",       // Xcode 27+
            "\(dev)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit", // Xcode 26 and older
        ]
        for path in candidates { _ = dlopen(path, RTLD_NOW) }
    }()

    static func load() { _ = loadOnce }

    /// Resolve the `SimDevice` NSObject for a UDID via `SimServiceContext`.
    static func findDevice(udid: String) -> NSObject? {
        load()
        guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type else { return nil }
        let dev = developerDir()
        let sharedSel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let context = contextClass.perform(sharedSel, with: dev, with: nil)?
            .takeUnretainedValue() as? NSObject else { return nil }
        let deviceSetSel = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let deviceSet = context.perform(deviceSetSel, with: nil)?
            .takeUnretainedValue() as? NSObject else { return nil }
        guard let devices = deviceSet.value(forKey: "devices") as? [NSObject] else { return nil }
        return devices.first {
            ($0.value(forKey: "UDID") as? NSUUID)?.uuidString.lowercased() == udid.lowercased()
        }
    }

    /// Whether a device is currently booted (its `stateString`).
    static func isBooted(_ device: NSObject) -> Bool {
        (device.value(forKey: "stateString") as? String) == "Booted"
    }
}
