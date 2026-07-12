import Foundation
import Security
import SwiftUI

/// Keychain-backed storage for the org-scoped **Admin API keys** used to pull AI
/// usage/cost stats.
///
/// Usage and cost reporting live behind each provider's Admin API, which is
/// authenticated with an *admin* key — Anthropic's `sk-ant-admin…` and OpenAI's
/// org admin key — not an ordinary inference key. A regular key returns 401/403
/// from these endpoints, so the Settings UI labels the fields accordingly.
///
/// Mirrors `DeviceIdentity`'s Keychain discipline: generic-password items scoped
/// to this app family, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and
/// idempotent writes (delete-then-add).
enum UsageCredentials {
    /// One provider whose usage we report on.
    enum Provider: String, CaseIterable {
        case anthropic
        case openAI

        var displayName: String {
            switch self {
            case .anthropic: "Claude"
            case .openAI: "Codex"
            }
        }

        /// Keychain account for this provider's admin key.
        fileprivate var account: String { "app.blau.usage.\(rawValue)" }
    }

    private static let service = "app.blau.usage"

    /// The stored admin key for `provider`, or `nil` if none has been saved.
    static func key(for provider: Provider) -> String? {
        guard let data = try? read(account: provider.account),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    /// True if a non-empty admin key is stored for `provider`.
    static func hasKey(for provider: Provider) -> Bool {
        key(for: provider) != nil
    }

    /// Persist (or clear, when `key` is empty/nil) the admin key for `provider`.
    static func setKey(_ key: String?, for provider: Provider) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            delete(account: provider.account)
        } else if let data = trimmed.data(using: .utf8) {
            try? write(data, account: provider.account)
        }
    }

    // MARK: - Keychain

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.status(status)
        }
    }

    private static func write(_ data: Data, account: String) throws {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    enum KeychainError: Error {
        case status(OSStatus)
    }
}

/// Form-facing model for the Usage settings tab. Holds the editable key strings,
/// seeds them from the Keychain on init, and persists on `save()`. Bumping
/// `changeToken` (via `save()`) lets observers — the `UsageStore` — know keys
/// changed and it should refetch.
@Observable
@MainActor
final class UsageSettingsModel {
    var anthropicKey: String
    var openAIKey: String
    /// Monotonic token incremented whenever keys are saved.
    private(set) var changeToken = 0

    init() {
        anthropicKey = UsageCredentials.key(for: .anthropic) ?? ""
        openAIKey = UsageCredentials.key(for: .openAI) ?? ""
    }

    var hasAnthropicKey: Bool { !anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasOpenAIKey: Bool { !openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Write both fields to the Keychain and signal observers to refetch.
    func save() {
        UsageCredentials.setKey(anthropicKey, for: .anthropic)
        UsageCredentials.setKey(openAIKey, for: .openAI)
        changeToken += 1
    }
}
