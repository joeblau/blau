import AppKit
import Foundation

/// Known third-party IDEs we'll launch a workspace into. Order in this
/// enum is the priority order — the first installed one wins.
enum ExternalIDE: CaseIterable {
    case cursor
    case codex
    case vscode

    /// Primary bundle identifiers, paired with secondary fallbacks for
    /// apps that ship under multiple IDs across releases.
    var bundleIdentifiers: [String] {
        switch self {
        case .cursor:
            // Cursor ships via ToDesktop; this is the stable bundle ID.
            return ["com.todesktop.230313mzl4w4u92"]
        case .codex:
            // OpenAI's Codex desktop hasn't fully stabilized its bundle
            // ID — accept the common candidates and let LaunchServices
            // pick the one that's installed.
            return ["com.openai.codex", "com.openai.Codex"]
        case .vscode:
            return ["com.microsoft.VSCode"]
        }
    }

    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .vscode: return "VS Code"
        }
    }

    /// Resolves to the on-disk URL of the installed app, or `nil` if no
    /// matching app is registered with LaunchServices.
    var installedURL: URL? {
        for id in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        return nil
    }
}

enum IDELauncher {
    /// The first installed IDE in priority order — Cursor, then Codex,
    /// then VS Code. `nil` if none are installed.
    static var preferred: ExternalIDE? {
        ExternalIDE.allCases.first { $0.installedURL != nil }
    }

    /// Opens `directoryPath` in `ide`. No-op if the IDE isn't actually
    /// installed (defensive — the caller should check `preferred` first).
    static func open(directoryPath: String, in ide: ExternalIDE) {
        guard let appURL = ide.installedURL else { return }
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        NSWorkspace.shared.open(
            [directoryURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }
}
