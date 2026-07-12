import Foundation
import Testing
@testable import Pilot

@Suite("AI usage reporting")
struct UsageReportingTests {
    @Test("Codex accepts current scalar variants, reset fallbacks, and credit balances")
    func codexCurrentResponse() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let root: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": "25.5",
                    "limit_window_seconds": 18_000,
                    "reset_after_seconds": "60",
                ],
                "secondary_window": [
                    "usedPercent": 80,
                    "windowDurationMins": 10_080,
                    "resetsAt": 1_800_604_800,
                ],
            ],
            "additional_rate_limits": [[
                "limit_name": "fast_model",
                "metered_feature": "fast",
                "rate_limit": [
                    "primary_window": [
                        "used_percent": 10,
                        "limit_window_seconds": 3_600,
                        "reset_at": 1_800_003_600,
                    ],
                ],
            ]],
            "credits": [
                "has_credits": true,
                "unlimited": false,
                "balance": "1129.25",
            ],
        ]

        let usage = UsageStore.parseCodexUsage(root, receivedAt: receivedAt)

        #expect(usage.planLabel == "Pro")
        #expect(usage.windows.count == 3)
        #expect(Set(usage.windows.map(\.id)).count == 3)
        let primary = try #require(usage.windows.first { $0.id == "codex-primary" })
        #expect(abs(primary.utilization - 0.255) < 0.000_001)
        #expect(primary.name == "5-hour")
        #expect(primary.resetsAt == receivedAt.addingTimeInterval(60))
        let weekly = try #require(usage.windows.first { $0.id == "codex-secondary" })
        #expect(weekly.name == "Weekly")
        #expect(abs(weekly.utilization - 0.8) < 0.000_001)
        #expect(usage.credits?.balance == 1129.25)
        #expect(usage.credits?.unit == .credits)
    }

    @Test("Codex omits malformed windows instead of reporting false zero usage")
    func codexRejectsMalformedWindow() {
        let usage = UsageStore.parseCodexUsage([
            "rate_limit": [
                "primary_window": [
                    "limit_window_seconds": 18_000,
                    "reset_at": 1_800_000_000,
                ],
            ],
        ])

        #expect(usage.windows.isEmpty)
    }

    @Test("Claude exposes extra-usage credits in major currency units")
    func claudeCredits() throws {
        let usage = UsageStore.parseClaudeUsage([
            "five_hour": [
                "utilization": 42,
                "resets_at": "2026-07-12T20:00:00Z",
            ],
            "seven_day": [
                "utilization": 1,
                "resets_at": "2026-07-19T20:00:00Z",
            ],
            "extra_usage": [
                "is_enabled": true,
                "monthly_limit": 5_000,
                "used_credits": 1_234,
                "utilization": 24.68,
                "currency": "usd",
            ],
        ], planLabel: "max")

        #expect(usage.planLabel == "Max")
        let window = try #require(usage.windows.first)
        #expect(abs(window.utilization - 0.42) < 0.000_001)
        let weekly = try #require(usage.windows.first { $0.id == "claude-seven_day" })
        #expect(abs(weekly.utilization - 0.01) < 0.000_001)
        let credits = try #require(usage.credits)
        #expect(credits.unit == .currency("USD"))
        #expect(credits.used == 12.34)
        #expect(credits.limit == 50)
        #expect(abs((credits.utilization ?? 0) - 0.2468) < 0.000_001)
    }

    @Test("Claude shows explicitly unlimited extra usage")
    func claudeUnlimitedCredits() throws {
        let usage = UsageStore.parseClaudeUsage([
            "extra_usage": [
                "is_enabled": true,
                "monthly_limit": NSNull(),
                "used_credits": NSNull(),
                "utilization": NSNull(),
                "currency": "usd",
            ],
        ])

        let credits = try #require(usage.credits)
        #expect(credits.unlimited)
        #expect(!credits.isEmpty)
    }

    @Test("Grok maps weekly billing usage, reset time, plan, and prepaid balance")
    func grokBilling() throws {
        let usage = UsageStore.parseGrokUsage([
            "subscriptionTier": "super_grok",
            "creditUsagePercent": "37.5",
            "currentPeriod": [
                "type": "weekly",
                "start": "2026-07-06T12:00:00Z",
                "end": "2026-07-13T12:00:00Z",
            ],
            "prepaidBalance": ["val": 2_500],
        ])

        #expect(usage.planLabel == "Super Grok")
        let window = try #require(usage.windows.first)
        #expect(window.name == "Weekly")
        #expect(abs(window.utilization - 0.375) < 0.000_001)
        #expect(window.resetsAt == UsageStore.date("2026-07-13T12:00:00Z"))
        #expect(usage.credits?.balance == 25)
        #expect(usage.credits?.unit == .currency("USD"))
    }

    @Test("Grok auth prefers the current OIDC scope")
    func grokAuthScopePreference() throws {
        let data = try #require("""
        {
          "https://accounts.x.ai/sign-in": {
            "key": "legacy-token",
            "auth_mode": "session"
          },
          "https://auth.x.ai::expired-client": {
            "key": "expired-token",
            "auth_mode": "oidc",
            "expires_at": "2026-01-01T12:00:00Z"
          },
          "https://auth.x.ai::client-id": {
            "key": "oidc-token",
            "auth_mode": "oidc",
            "email": "dev@example.com",
            "team_id": "team-1",
            "expires_at": "2026-08-01T12:00:00Z"
          }
        }
        """.data(using: .utf8))

        let now = try #require(UsageStore.date("2026-07-12T12:00:00Z"))
        let session = try #require(UsageSessions.GrokSession.parse(data: data, now: now))
        #expect(session.accessToken == "oidc-token")
        #expect(session.authMode == "oidc")
        #expect(session.email == "dev@example.com")
        #expect(session.teamId == "team-1")
    }

    @Test(
        "Reset countdown formats fixed boundaries",
        arguments: [
            (TimeInterval(-1), "resetting…"),
            (TimeInterval(59 * 60 + 5), "resets in 59m 05s"),
            (TimeInterval(3 * 3_600 + 12 * 60), "resets in 3h 12m"),
            (TimeInterval(2 * 86_400 + 4 * 3_600), "resets in 2d 4h"),
        ]
    )
    func countdown(remaining: TimeInterval, expected: String) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UsageResetCountdown.text(
            until: now.addingTimeInterval(remaining),
            now: now
        ) == expected)
    }
}
