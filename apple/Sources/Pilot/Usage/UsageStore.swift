import Foundation

/// A single usage window (rolling quota) for a provider — e.g. Codex's 5-hour
/// and weekly windows, or Claude's five-hour / seven-day windows.
struct UsageWindow: Equatable, Identifiable {
    let id: String
    let name: String
    /// Fraction used, 0...1.
    let utilization: Double
    /// When this window's quota resets, if known.
    let resetsAt: Date?
}

/// Credit balance / allowance, when the provider reports one.
enum CreditUnit: Equatable {
    case credits
    case currency(String)
}

struct CreditInfo: Equatable {
    var balance: Double? = nil
    var unit: CreditUnit = .credits
    var used: Double? = nil
    var limit: Double? = nil
    var unlimited: Bool = false
    /// Monthly-credit utilization (0...1), when reported instead of a balance.
    var utilization: Double? = nil

    var isEmpty: Bool {
        balance == nil && used == nil && limit == nil && !unlimited && utilization == nil
    }
}

/// Plan usage for one provider.
struct ProviderUsage: Equatable {
    var planLabel: String?
    var windows: [UsageWindow] = []
    var credits: CreditInfo?
}

/// Per-provider fetch state for the inspector.
enum ProviderState: Equatable {
    case loading
    case notSignedIn
    case usage(ProviderUsage)
    case error(String)
}

/// Pulls **plan usage, reset windows, and credits** for Claude, Codex, and Grok by
/// reusing the local CLI OAuth sessions (see `UsageSessions`)
/// and calling each CLI's own usage endpoint — no admin keys, no separate login.
///
/// ⚠️ These are undocumented endpoints the CLIs call internally; they can change.
/// Access is read-only; expired tokens surface a "re-run the CLI" message.
@Observable
@MainActor
final class UsageStore {
    private(set) var anthropic: ProviderState = .loading
    private(set) var openAI: ProviderState = .loading
    private(set) var xAI: ProviderState = .loading
    private(set) var isLoading = false

    private var loadTask: Task<Void, Never>?
    private var pollTimer: Timer?

    /// Matches `GitCommitStore` / `GitHubTasksStore` cadence.
    private static let pollInterval: TimeInterval = 60

    /// Begin (or restart) periodic refresh. Safe to call repeatedly.
    func start() {
        reload()
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in self.reload() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        loadTask?.cancel()
        loadTask = nil
    }

    /// Detect sessions and fetch all providers concurrently.
    func reload() {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task {
            async let anthropicResult = Self.fetchClaude()
            async let openAIResult = Self.fetchCodex()
            async let xAIResult = Self.fetchGrok()
            let (aRes, oRes, xRes) = await (anthropicResult, openAIResult, xAIResult)
            if Task.isCancelled { return }
            anthropic = Self.merge(previous: anthropic, result: aRes)
            openAI = Self.merge(previous: openAI, result: oRes)
            xAI = Self.merge(previous: xAI, result: xRes)
            isLoading = false
        }
    }

    /// Keep the last good usage on a transient fetch error, otherwise adopt the result.
    private static func merge(previous: ProviderState, result: ProviderFetch) -> ProviderState {
        switch result {
        case .success(let usage): return .usage(usage)
        case .notSignedIn: return .notSignedIn
        case .failure(let message):
            if case .usage = previous { return previous }
            return .error(message)
        }
    }

    // MARK: - Codex (OpenAI)

    nonisolated private static func fetchCodex() async -> ProviderFetch {
        guard let session = UsageSessions.CodexSession.load() else { return .notSignedIn }

        var headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "Accept": "application/json",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop",
            "User-Agent": "codex-cli",
        ]
        if let account = session.accountId { headers["ChatGPT-Account-Id"] = account }

        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let root: [String: Any]
        do {
            root = try await getJSONObject(url: url, headers: headers)
        } catch {
            return .failure(describe(error, provider: "Codex", reauth: "codex"))
        }

        return .success(Self.parseCodexUsage(root, receivedAt: Date()))
    }

    nonisolated static func parseCodexUsage(
        _ root: [String: Any],
        receivedAt: Date = Date()
    ) -> ProviderUsage {
        let rootPlan = string(root, keys: ["plan_type", "planType"])
        var usage = ProviderUsage(planLabel: rootPlan?.replacingOccurrences(of: "_", with: " ").capitalized)

        func appendRateLimit(
            _ rateLimit: [String: Any],
            idPrefix: String,
            displayName: String? = nil
        ) {
            if usage.planLabel == nil,
               let plan = Self.string(rateLimit, keys: ["plan_type", "planType"])
            {
                usage.planLabel = plan.replacingOccurrences(of: "_", with: " ").capitalized
            }

            let primary = Self.dictionary(
                rateLimit,
                keys: ["primary_window", "primaryWindow", "primary"]
            )
            let secondary = Self.dictionary(
                rateLimit,
                keys: ["secondary_window", "secondaryWindow", "secondary"]
            )
            // Keep the pool's label on every window — Codex returns a main
            // rate limit plus scoped "additional" pools that share the same
            // 5-hour/weekly cadence, so the label is what tells them apart.
            if let primary,
               let window = Self.codexWindow(
                primary,
                id: "\(idPrefix)-primary",
                displayName: displayName,
                receivedAt: receivedAt)
            {
                usage.windows.append(window)
            }
            if let secondary,
               let window = Self.codexWindow(
                secondary,
                id: "\(idPrefix)-secondary",
                displayName: displayName,
                receivedAt: receivedAt)
            {
                usage.windows.append(window)
            }
            if usage.credits == nil,
               let credits = Self.dictionary(rateLimit, keys: ["credits"])
            {
                usage.credits = Self.codexCredits(credits)
            }
        }

        if let rateLimit = dictionary(root, keys: ["rate_limit", "rateLimits", "rate_limits"]) {
            appendRateLimit(rateLimit, idPrefix: "codex")
        }

        if let additional = (root["additional_rate_limits"] ?? root["additionalRateLimits"])
            as? [[String: Any]]
        {
            for (index, entry) in additional.enumerated() {
                let id = string(entry, keys: ["limit_id", "limitId", "metered_feature", "meteredFeature"])
                    ?? "additional-\(index)"
                let label = string(entry, keys: ["limit_name", "limitName", "metered_feature", "meteredFeature"])
                    ?? (id.hasPrefix("additional-")
                        ? "Additional \(index + 1)"
                        : id.replacingOccurrences(of: "_", with: " "))
                let rateLimit = dictionary(entry, keys: ["rate_limit", "rateLimits"]) ?? entry
                appendRateLimit(
                    rateLimit,
                    idPrefix: "codex-\(id)-\(index)",
                    displayName: label
                )
            }
        }

        if let buckets = (root["rateLimitsByLimitId"] ?? root["rate_limits_by_limit_id"])
            as? [String: Any]
        {
            for key in buckets.keys.sorted() where key != "codex" {
                guard let bucket = buckets[key] as? [String: Any] else { continue }
                let label = string(bucket, keys: ["limitName", "limit_name"])
                    ?? key.replacingOccurrences(of: "_", with: " ")
                appendRateLimit(bucket, idPrefix: "codex-\(key)", displayName: label)
            }
        }

        if let credits = dictionary(root, keys: ["credits"]) {
            usage.credits = codexCredits(credits)
        }
        return usage
    }

    nonisolated private static func codexWindow(
        _ dict: [String: Any],
        id: String,
        displayName: String?,
        receivedAt: Date
    ) -> UsageWindow? {
        guard let usedPercent = number(dict, keys: ["used_percent", "usedPercent"]),
              usedPercent.isFinite else { return nil }
        let seconds = windowSeconds(dict)
        let absoluteReset = date(value(dict, keys: ["reset_at", "resets_at", "resetsAt"]))
        let resetAfter = number(dict, keys: ["reset_after_seconds", "resetAfterSeconds"])
        let resetsAt = absoluteReset ?? resetAfter.map { receivedAt.addingTimeInterval(max(0, $0)) }
        let generatedName = windowName(seconds: seconds)
        let name = displayName.flatMap { label in
            let cleaned = label.replacingOccurrences(of: "_", with: " ").capitalized
            return generatedName == "Usage" ? cleaned : "\(cleaned) · \(generatedName)"
        } ?? generatedName
        return UsageWindow(
            id: id,
            name: name,
            utilization: min(max(usedPercent / 100.0, 0), 1),
            resetsAt: resetsAt
        )
    }

    nonisolated private static func codexCredits(_ dict: [String: Any]) -> CreditInfo? {
        let hasCredits = bool(dict, keys: ["has_credits", "hasCredits"])
        guard hasCredits != false else { return nil }
        let info = CreditInfo(
            balance: number(dict, keys: ["balance"]),
            unit: .credits,
            unlimited: bool(dict, keys: ["unlimited"]) ?? false
        )
        return info.isEmpty ? nil : info
    }

    // MARK: - Claude (Claude Code)

    nonisolated private static func fetchClaude() async -> ProviderFetch {
        guard let session = UsageSessions.ClaudeSession.load() else { return .notSignedIn }
        guard session.hasProfileScope else {
            return .failure("Claude: this session lacks the user:profile scope — re-run `claude` to sign in.")
        }

        let headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-cli/2.1.0 (external, cli)",
        ]
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let root: [String: Any]
        do {
            root = try await getJSONObject(url: url, headers: headers)
        } catch {
            return .failure(describe(error, provider: "Claude", reauth: "claude"))
        }

        return .success(Self.parseClaudeUsage(root, planLabel: session.subscriptionType))
    }

    nonisolated static func parseClaudeUsage(
        _ root: [String: Any],
        planLabel: String? = nil
    ) -> ProviderUsage {
        var usage = ProviderUsage(
            planLabel: planLabel?.replacingOccurrences(of: "_", with: " ").capitalized
        )
        // Account-level windows.
        let account: [(String, String)] = [
            ("five_hour", "5-hour"),
            ("seven_day", "Weekly"),
            ("seven_day_oauth_apps", "Weekly (apps)"),
        ]
        for (key, label) in account {
            if let window = root[key] as? [String: Any],
               let parsed = Self.claudeWindow(id: "claude-\(key)", name: label, window)
            {
                usage.windows.append(parsed)
            }
        }

        // Model-scoped windows (e.g. Fable, Opus, Sonnet). The newer `limits`
        // array names the model via `scope.model.display_name` and supersedes the
        // flat `seven_day_<model>` fields, so track which models it covers.
        var scopedModels = Set<String>()
        if let limits = root["limits"] as? [[String: Any]] {
            for (index, entry) in limits.enumerated() {
                guard bool(entry, keys: ["is_active", "isActive"]) != false,
                      let model = Self.claudeLimitModel(entry),
                      let percent = number(entry, keys: ["percent", "utilization"]), percent.isFinite
                else { continue }
                scopedModels.insert(model.lowercased())
                usage.windows.append(UsageWindow(
                    id: "claude-limit-\(index)",
                    name: "\(Self.claudeLimitPeriod(entry)) (\(model))",
                    utilization: min(max(percent / 100.0, 0), 1),
                    resetsAt: date(value(entry, keys: ["resets_at", "resetsAt"]))
                ))
            }
        }

        // Flat model-scoped fields, only when `limits` didn't already cover them.
        let flatScoped: [(String, String, String)] = [
            ("seven_day_opus", "Weekly (Opus)", "opus"),
            ("seven_day_sonnet", "Weekly (Sonnet)", "sonnet"),
        ]
        for (key, label, model) in flatScoped where !scopedModels.contains(model) {
            if let window = root[key] as? [String: Any],
               let parsed = Self.claudeWindow(id: "claude-\(key)", name: label, window)
            {
                usage.windows.append(parsed)
            }
        }

        if let extra = root["extra_usage"] as? [String: Any],
           bool(extra, keys: ["is_enabled", "isEnabled"]) != false
        {
            let used = number(extra, keys: ["used_credits", "usedCredits"]).map { $0 / 100.0 }
            let limit = number(extra, keys: ["monthly_limit", "monthlyLimit"]).map { $0 / 100.0 }
            let rawUtilization = number(extra, keys: ["utilization"])
            let utilization = rawUtilization.map { min(max($0 / 100.0, 0), 1) }
            let currency = string(extra, keys: ["currency"])?.uppercased() ?? "USD"
            let monthlyLimitValue = value(extra, keys: ["monthly_limit", "monthlyLimit"])
            let unlimited = monthlyLimitValue is NSNull
            let credits = CreditInfo(
                balance: nil,
                unit: .currency(currency),
                used: used,
                limit: limit,
                unlimited: unlimited,
                utilization: utilization
            )
            if !credits.isEmpty { usage.credits = credits }
        }
        return usage
    }

    nonisolated private static func claudeWindow(
        id: String,
        name: String,
        _ dict: [String: Any]
    ) -> UsageWindow? {
        // Claude reports utilization as a percentage in the 0...100 range.
        guard let raw = number(dict, keys: ["utilization"]), raw.isFinite else { return nil }
        return UsageWindow(
            id: id,
            name: name,
            utilization: min(max(raw / 100.0, 0), 1),
            resetsAt: date(value(dict, keys: ["resets_at", "resetsAt"]))
        )
    }

    /// The model a scoped `limits[]` entry applies to (e.g. "Fable"), if any.
    nonisolated private static func claudeLimitModel(_ entry: [String: Any]) -> String? {
        if let scope = entry["scope"] as? [String: Any] {
            if let model = scope["model"] as? [String: Any],
               let name = string(model, keys: ["display_name", "displayName", "name", "id"])
            {
                return name
            }
            if let name = string(scope, keys: ["display_name", "displayName", "name", "model"]) {
                return name
            }
        }
        return string(entry, keys: ["display_name", "displayName", "name"])
    }

    /// The window period for a scoped `limits[]` entry, inferred from its
    /// `group`/`kind` hint (scoped limits are weekly by default).
    nonisolated private static func claudeLimitPeriod(_ entry: [String: Any]) -> String {
        let hint = (string(entry, keys: ["group", "kind", "window", "period"]) ?? "").lowercased()
        if hint.contains("week") || hint.contains("7d") || hint.contains("seven") { return "Weekly" }
        if hint.contains("hour") || hint.contains("5h") || hint.contains("five") { return "5-hour" }
        if hint.contains("month") { return "Monthly" }
        if hint.contains("day") { return "Daily" }
        return "Weekly"
    }

    // MARK: - Grok (xAI)

    nonisolated private static func fetchGrok() async -> ProviderFetch {
        guard let session = UsageSessions.GrokSession.load() else { return .notSignedIn }
        let clientVersion = UsageSessions.GrokSession.installedVersion() ?? "0.2.93"
        let headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "Accept": "application/json",
            "User-Agent": "grok/\(clientVersion)",
            "x-grok-client-version": clientVersion,
        ]
        let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        do {
            let root = try await getJSONObject(url: url, headers: headers)
            return .success(Self.parseGrokUsage(root, fallbackPlan: session.authMode))
        } catch {
            return .failure(describe(error, provider: "Grok", reauth: "grok"))
        }
    }

    nonisolated static func parseGrokUsage(
        _ root: [String: Any],
        fallbackPlan: String? = nil
    ) -> ProviderUsage {
        let rawPlan = string(root, keys: ["subscriptionTier", "subscription_tier"])
            ?? fallbackPlan
        let planLabel: String?
        switch rawPlan?.lowercased() {
        case "oidc":
            planLabel = "SuperGrok"
        case "session", nil:
            planLabel = nil
        case .some(let plan):
            planLabel = plan.replacingOccurrences(of: "_", with: " ").capitalized
        }
        var usage = ProviderUsage(planLabel: planLabel)
        let currentPeriod = dictionary(root, keys: ["currentPeriod", "current_period"])
        let billingCycle = dictionary(root, keys: ["billingCycle", "billing_cycle"])
        let periodStart = date(value(currentPeriod ?? [:], keys: ["start"]))
            ?? date(value(root, keys: ["billingPeriodStart", "billing_period_start"]))
            ?? date(value(billingCycle ?? [:], keys: ["billingPeriodStart", "billing_period_start"]))
        let periodEnd = date(value(currentPeriod ?? [:], keys: ["end"]))
            ?? date(value(root, keys: ["billingPeriodEnd", "billing_period_end"]))
            ?? date(value(billingCycle ?? [:], keys: ["billingPeriodEnd", "billing_period_end"]))
        let limit = cents(root, keys: ["monthlyLimit", "monthly_limit"])
        let includedUsed = cents(root, keys: ["includedUsed", "included_used"])
            ?? cents(dictionary(root, keys: ["usage"]) ?? [:], keys: ["totalUsed", "total_used"])
        let percent = number(root, keys: ["creditUsagePercent", "credit_usage_percent"])
            ?? (limit.flatMap { limit in
                guard limit > 0, let includedUsed else { return nil }
                return includedUsed / limit * 100.0
            })

        if let percent, percent.isFinite {
            let periodType = string(currentPeriod ?? [:], keys: ["type"])
            let name: String
            if let periodType, periodType.localizedCaseInsensitiveContains("week") {
                name = "Weekly"
            } else if let periodType, periodType.localizedCaseInsensitiveContains("month") {
                name = "Monthly"
            } else if let periodStart, let periodEnd {
                name = windowName(seconds: periodEnd.timeIntervalSince(periodStart))
            } else {
                name = "Usage"
            }
            usage.windows.append(UsageWindow(
                id: "grok-current-period",
                name: name,
                utilization: min(max(percent / 100.0, 0), 1),
                resetsAt: periodEnd
            ))
        }

        if let prepaid = cents(root, keys: ["prepaidBalance", "prepaid_balance"]) {
            usage.credits = CreditInfo(
                balance: prepaid / 100.0,
                unit: .currency("USD")
            )
        } else if let cap = cents(root, keys: ["onDemandCap", "on_demand_cap"]), cap > 0 {
            let used = cents(root, keys: ["onDemandUsed", "on_demand_used"])
            usage.credits = CreditInfo(
                balance: nil,
                unit: .currency("USD"),
                used: used.map { $0 / 100.0 },
                limit: cap / 100.0
            )
        }
        return usage
    }

    // MARK: - Shared helpers

    /// Human name for a rolling window given its length in seconds.
    nonisolated static func windowName(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Usage" }
        let hours = seconds / 3600
        if hours <= 1.5 { return "Hourly" }
        if hours < 24 { return "\(Int(hours.rounded()))-hour" }
        let days = seconds / 86400
        if days <= 1.5 { return "Daily" }
        if days <= 7.5 { return "Weekly" }
        if days <= 31 { return "Monthly" }
        return "\(Int(days.rounded()))-day"
    }

    /// GET a JSON object, tolerating any field shape — these are undocumented
    /// endpoints whose schemas vary, so we parse defensively rather than with a
    /// strict `Decodable` that would throw on the first type mismatch.
    nonisolated private static func getJSONObject(url: URL, headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UsageFetchError.http(status: http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFetchError.malformed
        }
        return object
    }

    /// Coerce a JSON value to a Double whether it arrived as a number or a string.
    nonisolated static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    nonisolated private static func number(_ dict: [String: Any], keys: [String]) -> Double? {
        number(value(dict, keys: keys))
    }

    nonisolated private static func bool(_ dict: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dict[key] as? Bool { return value }
            if let value = dict[key] as? NSNumber { return value.boolValue }
            if let value = dict[key] as? String {
                if value.caseInsensitiveCompare("true") == .orderedSame || value == "1" { return true }
                if value.caseInsensitiveCompare("false") == .orderedSame || value == "0" { return false }
            }
        }
        return nil
    }

    nonisolated private static func string(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dict[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    nonisolated private static func dictionary(
        _ dict: [String: Any],
        keys: [String]
    ) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] { return value }
        }
        return nil
    }

    nonisolated private static func value(_ dict: [String: Any], keys: [String]) -> Any? {
        for key in keys where dict[key] != nil { return dict[key] }
        return nil
    }

    nonisolated private static func windowSeconds(_ dict: [String: Any]) -> Double? {
        if let seconds = number(
            dict,
            keys: ["limit_window_seconds", "limitWindowSeconds", "window_seconds", "windowSeconds"]
        ) {
            return seconds
        }
        return number(dict, keys: ["windowDurationMins", "window_minutes"]).map { $0 * 60 }
    }

    /// Billing JSON wraps cent values as `{ "val": number }`.
    nonisolated private static func cents(_ dict: [String: Any], keys: [String]) -> Double? {
        guard let raw = value(dict, keys: keys) else { return nil }
        if let wrapped = raw as? [String: Any] { return number(wrapped, keys: ["val", "value"]) }
        return number(raw)
    }

    /// Parse a reset timestamp from either unix seconds (Codex) or a string in a
    /// range of ISO-8601 / RFC formats (Claude).
    nonisolated static func date(_ any: Any?) -> Date? {
        if let numeric = number(any) { return unixDate(numeric) }
        guard let string = any as? String, !string.isEmpty else { return nil }

        for options in [ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
                        ISO8601DateFormatter.Options([.withInternetDateTime])] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = options
            if let parsed = iso.date(from: string) { return parsed }
        }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
                        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
                        "yyyy-MM-dd HH:mm:ssZZZZZ",
                        "EEE',' dd MMM yyyy HH':'mm':'ss zzz"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            if let parsed = formatter.date(from: string) { return parsed }
        }
        return nil
    }

    nonisolated private static func unixDate(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1_000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }

    nonisolated private static func describe(_ error: Error, provider: String, reauth cli: String) -> String {
        switch error {
        case UsageFetchError.http(let status) where status == 401 || status == 403:
            return "\(provider): session expired — re-run `\(cli)` to sign in."
        case UsageFetchError.http(let status) where status == 429:
            return "\(provider): usage endpoint is rate limited. Try again in a few minutes."
        case UsageFetchError.http(let status):
            return "\(provider): request failed (HTTP \(status))."
        default:
            return "\(provider): couldn’t read the usage response."
        }
    }
}

private enum UsageFetchError: Error {
    case http(status: Int)
    case malformed
}

/// Outcome of one provider fetch.
private enum ProviderFetch {
    case success(ProviderUsage)
    case notSignedIn
    case failure(String)
}
