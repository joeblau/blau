import Foundation

/// A single usage window (rolling quota) for a provider — e.g. Codex's 5-hour
/// and weekly windows, or Claude's five-hour / seven-day windows.
struct UsageWindow: Equatable, Identifiable {
    let name: String
    /// Fraction used, 0...1.
    let utilization: Double
    /// When this window's quota resets, if known.
    let resetsAt: Date?

    var id: String { name }
}

/// Credit balance / allowance, when the provider reports one.
struct CreditInfo: Equatable {
    var balanceUSD: Double?
    var unlimited: Bool = false
    /// Monthly-credit utilization (0...1), when reported instead of a balance.
    var utilization: Double?

    var isEmpty: Bool { balanceUSD == nil && !unlimited && utilization == nil }
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

/// Pulls **plan usage, reset windows, and credits** for Claude and Codex by
/// reusing the local `codex` / `claude` CLI OAuth sessions (see `UsageSessions`)
/// and calling each CLI's own usage endpoint — no admin keys, no separate login.
///
/// ⚠️ These are undocumented endpoints the CLIs call internally; they can change.
/// Access is read-only; expired tokens surface a "re-run the CLI" message.
@Observable
@MainActor
final class UsageStore {
    private(set) var anthropic: ProviderState = .loading
    private(set) var openAI: ProviderState = .loading
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

    /// Detect sessions and fetch both providers concurrently.
    func reload() {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task {
            async let anthropicResult = Self.fetchClaude()
            async let openAIResult = Self.fetchCodex()
            let (aRes, oRes) = await (anthropicResult, openAIResult)
            if Task.isCancelled { return }
            anthropic = Self.merge(previous: anthropic, result: aRes)
            openAI = Self.merge(previous: openAI, result: oRes)
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
            "User-Agent": "codex-cli",
        ]
        if let account = session.accountId { headers["ChatGPT-Account-Id"] = account }

        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let response: CodexUsageResponse
        do {
            response = try await getJSON(url: url, headers: headers)
        } catch {
            return .failure(describe(error, provider: "Codex", reauth: "codex"))
        }

        var usage = ProviderUsage(planLabel: response.plan_type?.capitalized)
        if let primary = response.rate_limit?.primary_window {
            usage.windows.append(Self.codexWindow(primary))
        }
        if let secondary = response.rate_limit?.secondary_window {
            usage.windows.append(Self.codexWindow(secondary))
        }
        if let credits = response.credits, credits.has_credits != false {
            usage.credits = CreditInfo(balanceUSD: credits.balance, unlimited: credits.unlimited ?? false)
        }
        return .success(usage)
    }

    nonisolated private static func codexWindow(_ window: CodexUsageResponse.Window) -> UsageWindow {
        UsageWindow(
            name: windowName(seconds: window.limit_window_seconds),
            utilization: (window.used_percent ?? 0) / 100.0,
            resetsAt: window.reset_at?.date
        )
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
        let response: ClaudeUsageResponse
        do {
            response = try await getJSON(url: url, headers: headers)
        } catch {
            return .failure(describe(error, provider: "Claude", reauth: "claude"))
        }

        var usage = ProviderUsage(planLabel: session.subscriptionType?.capitalized)
        if let window = response.five_hour { usage.windows.append(Self.claudeWindow("5-hour", window)) }
        if let window = response.seven_day { usage.windows.append(Self.claudeWindow("Weekly", window)) }
        if let window = response.seven_day_oauth_apps {
            usage.windows.append(Self.claudeWindow("Weekly (apps)", window))
        }
        return .success(usage)
    }

    nonisolated private static func claudeWindow(_ name: String, _ window: ClaudeUsageResponse.Window) -> UsageWindow {
        // Claude reports `utilization`; normalize a percent (>1) to a fraction.
        let raw = window.utilization ?? 0
        let fraction = raw > 1 ? raw / 100.0 : raw
        return UsageWindow(name: name, utilization: fraction, resetsAt: window.resets_at?.date)
    }

    // MARK: - Shared helpers

    /// Human name for a rolling window given its length in seconds.
    nonisolated private static func windowName(seconds: Double?) -> String {
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

    nonisolated private static func getJSON<T: Decodable>(url: URL, headers: [String: String]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UsageFetchError.http(status: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    nonisolated private static func describe(_ error: Error, provider: String, reauth cli: String) -> String {
        switch error {
        case UsageFetchError.http(let status) where status == 401 || status == 403:
            return "\(provider): session expired — re-run `\(cli)` to sign in."
        case UsageFetchError.http(let status) where status == 429:
            return "\(provider): usage endpoint is rate limited. Try again in a few minutes."
        case UsageFetchError.http(let status):
            return "\(provider): request failed (HTTP \(status))."
        case is DecodingError:
            return "\(provider): couldn’t read the usage response."
        default:
            return "\(provider): couldn’t reach the usage endpoint."
        }
    }
}

private enum UsageFetchError: Error {
    case http(status: Int)
}

/// Outcome of one provider fetch.
private enum ProviderFetch {
    case success(ProviderUsage)
    case notSignedIn
    case failure(String)
}

// MARK: - Flexible date

/// A timestamp that may arrive as unix seconds (Codex) or an RFC-1123 / ISO
/// string (Claude).
private struct FlexibleDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let unix = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: unix)
        } else if let string = try? container.decode(String.self) {
            date = FlexibleDate.parse(string)
        } else {
            date = nil
        }
    }

    private static func parse(_ string: String) -> Date? {
        if let iso = ISO8601DateFormatter().date(from: string) { return iso }
        let rfc1123 = DateFormatter()
        rfc1123.locale = Locale(identifier: "en_US_POSIX")
        rfc1123.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return rfc1123.date(from: string)
    }
}

// MARK: - Codex response models

private struct CodexUsageResponse: Decodable {
    let plan_type: String?
    let rate_limit: RateLimit?
    let credits: Credits?

    struct RateLimit: Decodable {
        let primary_window: Window?
        let secondary_window: Window?
    }
    struct Window: Decodable {
        let used_percent: Double?
        let reset_at: FlexibleDate?
        let limit_window_seconds: Double?
    }
    struct Credits: Decodable {
        let has_credits: Bool?
        let unlimited: Bool?
        let balance: Double?
    }
}

// MARK: - Claude response models

private struct ClaudeUsageResponse: Decodable {
    let five_hour: Window?
    let seven_day: Window?
    let seven_day_oauth_apps: Window?

    struct Window: Decodable {
        let utilization: Double?
        let resets_at: FlexibleDate?
    }
}
