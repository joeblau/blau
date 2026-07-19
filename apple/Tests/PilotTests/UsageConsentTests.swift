import Foundation
import Testing
@testable import Pilot

@Suite("Usage credential consent")
@MainActor
struct UsageConsentTests {
    private actor FetchProbe {
        private var providers: [String] = []

        func record(_ provider: String) -> ProviderFetch {
            providers.append(provider)
            return .notSignedIn
        }

        func recordedProviders() -> [String] {
            providers
        }
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "UsageConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test("Every provider is disabled by default")
    func defaultsArePrivate() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!UsageConsent.isClaudeEnabled(defaults: defaults))
        #expect(!UsageConsent.isCodexEnabled(defaults: defaults))
        #expect(!UsageConsent.isGrokEnabled(defaults: defaults))
        #expect(!UsageConsent.isKimiEnabled(defaults: defaults))
    }

    @Test("Reload performs zero provider access before opt-in")
    func noAccessBeforeConsent() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = FetchProbe()
        let store = UsageStore(
            defaults: defaults,
            fetchers: .init(
                claude: { await probe.record("Claude") },
                codex: { await probe.record("Codex") },
                grok: { await probe.record("Grok") },
                kimi: { await probe.record("Kimi") }
            )
        )

        store.reload()
        await store.waitForCurrentLoad()

        #expect(await probe.recordedProviders().isEmpty)
        #expect(store.anthropic == .disabled)
        #expect(store.openAI == .disabled)
        #expect(store.xAI == .disabled)
        #expect(store.moonshot == .disabled)
    }

    @Test("Only an opted-in provider may reach its credential and network boundary")
    func consentIsPerProviderAndRevocable() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UsageConsent.codexKey)
        let probe = FetchProbe()
        let store = UsageStore(
            defaults: defaults,
            fetchers: .init(
                claude: { await probe.record("Claude") },
                codex: { await probe.record("Codex") },
                grok: { await probe.record("Grok") },
                kimi: { await probe.record("Kimi") }
            )
        )

        store.reload()
        await store.waitForCurrentLoad()

        #expect(await probe.recordedProviders() == ["Codex"])
        defaults.set(false, forKey: UsageConsent.codexKey)
        store.reload()
        await store.waitForCurrentLoad()
        #expect(store.openAI == .disabled)
    }

    @Test("Kimi credential access is independently opted in and revocable")
    func kimiConsentIsIndependentAndRevocable() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UsageConsent.kimiKey)
        let probe = FetchProbe()
        let store = UsageStore(
            defaults: defaults,
            fetchers: .init(
                claude: { await probe.record("Claude") },
                codex: { await probe.record("Codex") },
                grok: { await probe.record("Grok") },
                kimi: { await probe.record("Kimi") }
            )
        )

        store.reload()
        await store.waitForCurrentLoad()

        #expect(await probe.recordedProviders() == ["Kimi"])
        defaults.set(false, forKey: UsageConsent.kimiKey)
        store.reload()
        await store.waitForCurrentLoad()
        #expect(store.moonshot == .disabled)
    }
}
