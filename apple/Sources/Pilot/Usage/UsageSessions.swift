import Foundation

/// Reads the OAuth sessions that the `codex` and `claude` CLIs already store on
/// this Mac, so we can query each provider's plan-usage endpoint **without asking
/// the user to log in again** (the approach popularized by CodexBar).
///
/// Everything here is strictly **read-only** — we never write back to the CLI's
/// credential store or refresh its tokens (the CLIs own that lifecycle). If a
/// token has expired we surface a "re-run the CLI" message rather than mutating
/// anyone else's state.
///
/// ⚠️ These endpoints (`chatgpt.com/backend-api/wham/usage`,
/// `api.anthropic.com/api/oauth/usage`) are the internal endpoints the CLIs call.
/// They are undocumented and can change without notice.
enum UsageSessions {

    // MARK: - Codex (OpenAI)

    /// The `codex` CLI's OAuth session, read from `~/.codex/auth.json`.
    struct CodexSession: Sendable {
        let accessToken: String
        let accountId: String?

        /// Load from `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`).
        static func load() -> CodexSession? {
            let home: URL
            if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
                home = URL(fileURLWithPath: codexHome)
            } else {
                home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            }
            let url = home.appendingPathComponent("auth.json")
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = root["tokens"] as? [String: Any],
                  let access = tokens["access_token"] as? String,
                  !access.isEmpty else { return nil }
            return CodexSession(accessToken: access, accountId: tokens["account_id"] as? String)
        }
    }

    // MARK: - Claude (Claude Code)

    /// Claude Code's OAuth session. Needs the `user:profile` scope to read usage.
    struct ClaudeSession: Sendable {
        let accessToken: String
        let scopes: [String]
        let subscriptionType: String?

        var hasProfileScope: Bool { scopes.contains("user:profile") }

        /// Load Claude Code's credentials — file first, then the macOS Keychain
        /// item Claude Code writes (via the `security` CLI, which may prompt once).
        static func load() -> ClaudeSession? {
            let fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            if let data = try? Data(contentsOf: fileURL), let session = parse(data) {
                return session
            }
            if let data = readKeychainViaSecurityCLI(service: keychainService), let session = parse(data) {
                return session
            }
            return nil
        }

        /// Keychain generic-password service Claude Code stores its creds under.
        static let keychainService = "Claude Code-credentials"

        private static func parse(_ data: Data) -> ClaudeSession? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = root["claudeAiOauth"] as? [String: Any],
                  let access = oauth["accessToken"] as? String,
                  !access.isEmpty else { return nil }
            return ClaudeSession(
                accessToken: access,
                scopes: (oauth["scopes"] as? [String]) ?? [],
                subscriptionType: oauth["subscriptionType"] as? String
            )
        }

        /// Read a generic-password item created by another app via `/usr/bin/security`.
        /// A direct `SecItemCopyMatching` from a different app is blocked by the
        /// item's ACL; the `security` CLI is the item's trusted reader and, on
        /// first access, macOS prompts the user to Allow. Read-only.
        private static func readKeychainViaSecurityCLI(service: String) -> Data? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", service, "-w"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let value = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value.data(using: .utf8)
        }
    }
}
