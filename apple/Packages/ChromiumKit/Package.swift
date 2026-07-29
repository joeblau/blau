// swift-tools-version: 6.0

import Foundation
import PackageDescription

private struct CEFIdentity: Decodable, Equatable {
    let version: String
    let commit: String
    let chromiumCommit: String
    let sandboxCompatibilityCommit: String
    let requiredXcodeMajorVersion: Int
}

private struct CEFSourceArchive: Decodable, Equatable {
    let architecture: String
    let distributionDirectory: String
    let url: String
    let bytes: Int
    let sha1: String
    let sha256: String
}

private struct ArtifactLayout: Decodable {
    let root: String
    let framework: String
    let headers: String
    let wrapperLibrary: String
    let license: String
    let credits: String
    let receipt: String
    let frameworkExecutable: String
    let architectures: [String]
}

private struct ArtifactLock: Decodable {
    let schemaVersion: Int
    let releaseID: String
    let cef: CEFIdentity
    let sourceArchives: [CEFSourceArchive]
    let artifactLayout: ArtifactLayout
}

private struct InstallationReceipt: Decodable {
    let schemaVersion: Int
    let releaseID: String
    let artifact: String
    let artifactBytes: Int
    let artifactSHA256: String
    let cef: CEFIdentity
    let sourceArchives: [CEFSourceArchive]
    let architectures: [String]
    let installedBytes: Int
    let installedFiles: [String: String]
    let toolVersions: [String: String]
}

private struct CEFInstallation {
    let enabled: Bool
    let artifactRoot: URL
    let libraries: URL
}

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()

private let chromiumRequested: Bool = {
    let environment = ProcessInfo.processInfo.environment
    let explicit = environment["BLAU_CHROMIUM_CEF_ENABLED"]?
        .lowercased()
    return ["1", "true", "yes"].contains(explicit)
        || environment["CONFIGURATION"] == "Chromium"
}()

private func isLowercaseHex(_ value: String, count: Int) -> Bool {
    value.count == count && value.allSatisfy {
        $0.isNumber || ("a"..."f").contains(String($0))
    }
}

private func sha256(of url: URL) -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", url.path]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0,
          let value = String(
              data: output.fileHandleForReading.readDataToEndOfFile(),
              encoding: .utf8
          )?.split(separator: " ").first
    else {
        return nil
    }
    return String(value)
}

private func detectVerifiedCEFInstallation() -> CEFInstallation {
    let disabled = CEFInstallation(
        enabled: false,
        artifactRoot: packageRoot.appendingPathComponent("Artifacts/CEF"),
        libraries: packageRoot
    )

    guard chromiumRequested else {
        return disabled
    }

    do {
        let lockURL = packageRoot.appendingPathComponent("cef-artifacts.json")
        let lockData = try Data(contentsOf: lockURL)
        let lock = try JSONDecoder().decode(ArtifactLock.self, from: lockData)
        guard lock.schemaVersion == 1 else {
            return disabled
        }
        let artifactRoot = packageRoot.appendingPathComponent(
            lock.artifactLayout.root
        )
        let installedLockData = try Data(
            contentsOf: artifactRoot.appendingPathComponent(
                "cef-artifacts.json"
            )
        )
        guard installedLockData == lockData else {
            return disabled
        }

        let receiptURL = packageRoot.appendingPathComponent(
            lock.artifactLayout.receipt
        )
        let receipt = try JSONDecoder().decode(
            InstallationReceipt.self,
            from: Data(contentsOf: receiptURL)
        )
        guard receipt.schemaVersion == 1,
              receipt.releaseID == lock.releaseID,
              receipt.artifact == "ChromiumKitCEF.runtime.zip",
              receipt.artifactBytes > 0,
              isLowercaseHex(receipt.artifactSHA256, count: 64),
              receipt.cef == lock.cef,
              receipt.sourceArchives == lock.sourceArchives,
              receipt.architectures == lock.artifactLayout.architectures,
              receipt.installedBytes > 0,
              Set(receipt.toolVersions.keys) == Set([
                  "cmake",
                  "xcode",
                  "zip",
              ]),
              receipt.toolVersions.values.allSatisfy({ !$0.isEmpty })
        else {
            return disabled
        }

        let rootPrefix = "\(lock.artifactLayout.root)/"
        let installedPaths = [
            "\(lock.artifactLayout.framework)/Versions/A/\(lock.artifactLayout.frameworkExecutable)",
            "\(lock.artifactLayout.headers)/cef_app.h",
            lock.artifactLayout.wrapperLibrary,
            lock.artifactLayout.license,
            lock.artifactLayout.credits,
            "\(lock.artifactLayout.root)/cef-artifacts.json",
        ]
        let requiredHashes = Set(installedPaths.compactMap { path in
            path.hasPrefix(rootPrefix)
                ? String(path.dropFirst(rootPrefix.count))
                : nil
        })
        guard requiredHashes.count == installedPaths.count,
              Set(receipt.installedFiles.keys) == requiredHashes
        else {
            return disabled
        }
        for (relativePath, expectedHash) in receipt.installedFiles {
            let components = relativePath.split(separator: "/")
            guard !relativePath.hasPrefix("/"),
                  !components.contains(".."),
                  isLowercaseHex(expectedHash, count: 64),
                  sha256(
                      of: artifactRoot.appendingPathComponent(relativePath)
                  ) == expectedHash
            else {
                return disabled
            }
        }

        let framework = packageRoot.appendingPathComponent(
            lock.artifactLayout.framework
        )
        let executable = framework
            .appendingPathComponent("Versions/A")
            .appendingPathComponent(
                lock.artifactLayout.frameworkExecutable
            )
        let headers = packageRoot.appendingPathComponent(
            lock.artifactLayout.headers
        )
        let wrapperLibrary = packageRoot.appendingPathComponent(
            lock.artifactLayout.wrapperLibrary
        )
        let license = packageRoot.appendingPathComponent(
            lock.artifactLayout.license
        )
        let credits = packageRoot.appendingPathComponent(
            lock.artifactLayout.credits
        )
        guard FileManager.default.fileExists(atPath: executable.path),
              FileManager.default.fileExists(
                  atPath: headers.appendingPathComponent("cef_app.h").path
              ),
              FileManager.default.fileExists(atPath: wrapperLibrary.path),
              FileManager.default.fileExists(atPath: license.path),
              FileManager.default.fileExists(atPath: credits.path)
        else {
            return disabled
        }

        return CEFInstallation(
            enabled: true,
            artifactRoot: artifactRoot,
            libraries: wrapperLibrary.deletingLastPathComponent()
        )
    } catch {
        return disabled
    }
}

private let cefInstallation = detectVerifiedCEFInstallation()
if chromiumRequested && !cefInstallation.enabled {
    fatalError(
        "The Chromium configuration requires a verified CEF installation. "
            + "Run apple/bin/build-pilot-chromium.sh from a clean checkout."
    )
}
private var chromiumCXXSettings: [CXXSetting] = []
private var chromiumLinkerSettings: [LinkerSetting] = [
    .linkedFramework("AppKit"),
    .linkedFramework("CoreServices"),
]

if cefInstallation.enabled {
    chromiumCXXSettings.append(
        .define("BLAU_CHROMIUM_CEF_ENABLED", to: "1")
    )
    chromiumCXXSettings.append(
        .unsafeFlags(["-I", cefInstallation.artifactRoot.path])
    )
    chromiumLinkerSettings.append(
        .unsafeFlags([
            "-F", cefInstallation.artifactRoot.path,
            "-L", cefInstallation.libraries.path,
            "-lcef_dll_wrapper",
        ])
    )
}

let package = Package(
    name: "ChromiumKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ChromiumKit", targets: ["ChromiumKit"]),
    ],
    targets: [
        .target(
            name: "ChromiumKit",
            path: "Sources/ChromiumKit",
            publicHeadersPath: "include",
            cxxSettings: chromiumCXXSettings,
            linkerSettings: chromiumLinkerSettings
        ),
    ],
    cxxLanguageStandard: .cxx20
)
