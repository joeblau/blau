import Foundation

/// Reads the OAuth sessions that the `codex`, `claude`, `grok`, and `kimi` CLIs already
/// store on this Mac, so we can query each provider's plan-usage endpoint
/// **without asking the user to log in again** (the approach popularized by
/// CodexBar).
///
/// Everything here is strictly **read-only** — we never write back to the CLI's
/// credential store or refresh its tokens (the CLIs own that lifecycle). If a
/// token has expired we surface a "re-run the CLI" message rather than mutating
/// anyone else's state.
///
/// ⚠️ These endpoints (`chatgpt.com/backend-api/wham/usage`,
/// `api.anthropic.com/api/oauth/usage`, Grok's CLI billing endpoint, and Kimi
/// Code's `/usages` endpoint) are the internal endpoints the CLIs call.
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

    // MARK: - Kimi (Moonshot AI)

    /// Kimi Code's OAuth session, read without refreshing or rewriting it.
    ///
    /// Current Kimi Code stores credentials below `$KIMI_CODE_HOME` (default
    /// `~/.kimi-code`). The former Python CLI used `$KIMI_SHARE_DIR` (default
    /// `~/.kimi`), so that location remains a read-only fallback for users who
    /// have not migrated yet.
    struct KimiSession: Sendable {
        let accessToken: String
        let expiresAt: Date?

        var isExpired: Bool { isExpired(at: Date()) }

        func isExpired(at date: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= date
        }

        /// Load the current credential file first, then the legacy file.
        static func load() -> KimiSession? {
            for url in credentialURLs() {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                guard let data = try? Data(contentsOf: url) else { return nil }
                // A present current credential owns account selection. Do not
                // silently fall back to a legacy account if it is malformed;
                // an expired token is surfaced separately by the usage store.
                return parse(data: data)
            }
            return nil
        }

        /// Parse the CLI's snake-case token wire format. Internal so tests can
        /// validate it without ever reading a developer's real credentials.
        static func parse(data: Data) -> KimiSession? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = nonemptyString(root["access_token"])
            else { return nil }

            let expiresAt = parseDate(root["expires_at"])
            return KimiSession(accessToken: accessToken, expiresAt: expiresAt)
        }

        private static func credentialURLs() -> [URL] {
            let environment = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser
            let currentHome = environment["KIMI_CODE_HOME"].flatMap(nonemptyString)
                .map(expandedFileURL)
                ?? home.appendingPathComponent(".kimi-code")
            let legacyHome = environment["KIMI_SHARE_DIR"].flatMap(nonemptyString)
                .map(expandedFileURL)
                ?? home.appendingPathComponent(".kimi")

            var seen = Set<String>()
            return [currentHome, legacyHome].compactMap { root in
                let url = root.appendingPathComponent("credentials/kimi-code.json")
                return seen.insert(url.standardizedFileURL.path).inserted ? url : nil
            }
        }

        private static func expandedFileURL(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }

        private static func nonemptyString(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func parseDate(_ value: Any?) -> Date? {
            if let number = value as? NSNumber {
                return Date(timeIntervalSince1970: number.doubleValue)
            }
            guard let string = nonemptyString(value), let seconds = Double(string) else {
                return nil
            }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    // MARK: - Grok (xAI)

    /// The Grok CLI's OAuth session, read from `~/.grok/auth.json`.
    ///
    /// Unlike Codex and Claude, Grok stores a map keyed by OAuth scope. A
    /// current OIDC entry is preferred, but an older grok.com sign-in entry is
    /// still accepted so existing CLI sessions continue to work.
    struct GrokSession: Sendable {
        let accessToken: String
        let scope: String
        let authMode: String?
        let email: String?
        let teamId: String?
        let expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }

        /// Load from `$GROK_HOME/auth.json` (default `~/.grok/auth.json`).
        static func load() -> GrokSession? {
            guard let data = try? Data(contentsOf: homeURL().appendingPathComponent("auth.json")) else {
                return nil
            }
            return parse(data: data)
        }

        /// Version sent by the installed CLI to its billing endpoint.
        static func installedVersion() -> String? {
            let url = homeURL().appendingPathComponent("version.json")
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return nonemptyString(root["version"])
        }

        /// Parse Grok's scope-keyed auth file. Internal so fixture-based tests
        /// can cover scope preference without reading a developer's credentials.
        static func parse(data: Data, now: Date = Date()) -> GrokSession? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let entries: [(scope: String, value: [String: Any])] = root.compactMap { scope, value in
                guard let value = value as? [String: Any], nonemptyString(value["key"]) != nil else {
                    return nil
                }
                return (scope, value)
            }.sorted { $0.scope < $1.scope }

            let activeEntries = entries.filter { entry in
                guard let expiresAt = parseDate(entry.value["expires_at"]) else { return true }
                return expiresAt > now
            }
            func newest(_ candidates: [(scope: String, value: [String: Any])])
                -> (scope: String, value: [String: Any])?
            {
                candidates.max { lhs, rhs in
                    let lhsExpiry = parseDate(lhs.value["expires_at"]) ?? .distantPast
                    let rhsExpiry = parseDate(rhs.value["expires_at"]) ?? .distantPast
                    if lhsExpiry == rhsExpiry { return lhs.scope > rhs.scope }
                    return lhsExpiry < rhsExpiry
                }
            }
            let selected = newest(activeEntries.filter {
                $0.scope.hasPrefix("https://auth.x.ai::")
            }) ?? newest(activeEntries.filter {
                $0.scope == "https://accounts.x.ai/sign-in" || $0.scope.contains("/sign-in")
            })
            guard let selected, let accessToken = nonemptyString(selected.value["key"]) else {
                return nil
            }

            return GrokSession(
                accessToken: accessToken,
                scope: selected.scope,
                authMode: nonemptyString(selected.value["auth_mode"]),
                email: nonemptyString(selected.value["email"]),
                teamId: nonemptyString(selected.value["team_id"]),
                expiresAt: parseDate(selected.value["expires_at"])
            )
        }

        private static func nonemptyString(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func homeURL() -> URL {
            if let grokHome = ProcessInfo.processInfo.environment["GROK_HOME"], !grokHome.isEmpty {
                return URL(fileURLWithPath: (grokHome as NSString).expandingTildeInPath)
            }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        }

        private static func parseDate(_ value: Any?) -> Date? {
            if let number = value as? NSNumber {
                return Date(timeIntervalSince1970: number.doubleValue)
            }
            guard let string = nonemptyString(value) else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: string) { return parsed }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
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
            let invocation = ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["find-generic-password", "-s", service, "-w"],
                timeout: .seconds(30),
                standardOutputLimit: 1 * 1_024 * 1_024,
                standardErrorLimit: 64 * 1_024,
                redactedArgumentIndexes: [2]
            )
            guard let result = try? ProcessRunner.runBlocking(invocation),
                  let value = String(data: result.standardOutput, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value.data(using: .utf8)
        }
    }
}
