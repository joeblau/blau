import Foundation

/// Errors surfaced by the `emulator` CLI. `toolingMissing` is the friendly case
/// for a machine without the Android emulator package — the pane keeps showing
/// its adb-based device list instead of failing.
enum EmulatorError: Error {
    case toolingMissing
    case commandFailed(String)
}

/// Typed wrapper over the Android SDK `emulator` CLI, used to list installed
/// AVDs and boot one from the Simulator picker — the Android counterpart to
/// `SimctlBridge`'s list/boot for iOS. Pilot never bundles the SDK
/// (binary-provenance policy): it resolves the user's own install and degrades
/// to guidance when none exists. Mirrors `AdbBridge`'s resolution and one-shot
/// conventions; a booted emulator keeps running independently of Pilot.
enum EmulatorBridge {
    // MARK: - Executable resolution

    /// SDK roots to probe. Finder-launched apps get a minimal PATH, so the
    /// well-known locations must not depend on it.
    static var sdkRootCandidates: [String] {
        var roots: [String] = []
        let environment = ProcessInfo.processInfo.environment
        for variable in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[variable], !root.isEmpty { roots.append(root) }
        }
        roots.append(("~/Library/Android/sdk" as NSString).expandingTildeInPath)
        return roots
    }

    static var emulatorCandidatePaths: [String] {
        var candidates = sdkRootCandidates.map {
            ($0 as NSString).appendingPathComponent("emulator/emulator")
        }
        candidates.append("/opt/homebrew/bin/emulator")
        candidates.append("/usr/local/bin/emulator")
        return candidates
    }

    /// First executable candidate wins. Deliberately not cached: the pane
    /// re-resolves on every scan so installing the SDK doesn't need a relaunch.
    static func resolveEmulatorURL() -> URL? {
        for path in emulatorCandidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Listing

    /// Installed AVD names from `emulator -list-avds`, validated and bounded.
    static func listAVDs() throws -> [String] {
        guard let url = resolveEmulatorURL() else { throw EmulatorError.toolingMissing }
        let invocation = ProcessInvocation(
            executableURL: url,
            arguments: ["-list-avds"],
            timeout: .seconds(15),
            standardOutputLimit: 256 * 1_024,
            standardErrorLimit: 64 * 1_024
        )
        do {
            let data = try ProcessRunner.runBlocking(invocation).standardOutput
            return parseAVDList(String(decoding: data, as: UTF8.self))
        } catch let error as ProcessRunnerError {
            let message = error.result?.standardErrorString ?? error.localizedDescription
            throw EmulatorError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// One AVD name per line. Some setups print an unrelated warning line to
    /// stdout (e.g. a Metrics/HAXM notice), so keep only well-formed names, and
    /// bound the count. Sorted for a stable picker order.
    static func parseAVDList(_ output: String) -> [String] {
        var names: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if names.count >= 64 { break }
            let name = line.trimmingCharacters(in: .whitespaces)
            guard isValidAVDName(name), !names.contains(name) else { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// AVD names become an `@name` argv element and render in the UI, so
    /// validate them: `-list-avds` emits the AVD *id* (spaces collapsed to
    /// underscores), never arbitrary text, but an adversarial config directory
    /// must not be able to smuggle a flag or shell metacharacter into either.
    static func isValidAVDName(_ name: String) -> Bool {
        guard (1...128).contains(name.count), !name.hasPrefix("-") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Human-facing label: the AVD id with underscores relaxed back to spaces
    /// ("Medium_Phone_API_35" → "Medium Phone API 35").
    static func displayName(for avd: String) -> String {
        avd.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - Boot

    /// The long-lived emulator process for a boot. The caller owns the handle,
    /// but a booted emulator is a user resource: it is left running when the
    /// pane goes away, exactly as an emulator started from Android Studio would
    /// be. stdout/stderr are discarded so a chatty emulator can't fill a pipe
    /// and stall (the caller tracks boot progress over adb instead).
    static func makeBootProcess(emulatorURL: URL, avdName: String) -> Process {
        let process = Process()
        process.executableURL = emulatorURL
        process.arguments = ["@\(avdName)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}
