import Foundation

/// Per-model usage within a provider (Claude Fable, Opus, GPT-5, …).
struct ModelUsage: Equatable, Identifiable {
    let model: String
    var inputTokens = 0
    var outputTokens = 0
    var cachedTokens = 0
    var requests = 0
    var costUSD = 0.0

    var id: String { model }
    var totalTokens: Int { inputTokens + outputTokens }
    /// Whether this is a Claude Fable–family model, which the user wants called out.
    var isFable: Bool { model.localizedCaseInsensitiveContains("fable") }
}

/// A non-token cost line (Anthropic Cost Report `cost_type`s beyond tokens:
/// web search, code execution, session usage). This is the "extra usage" spend.
struct ExtraCost: Equatable, Identifiable {
    let label: String
    var costUSD: Double
    var id: String { label }
}

/// Aggregated usage for one provider over the selected window.
struct ProviderUsage: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cachedTokens = 0
    var requests = 0
    var costUSD = 0.0
    var webSearchRequests = 0
    /// Per-model breakdown, sorted by cost then tokens (descending).
    var models: [ModelUsage] = []
    /// Non-token cost lines (Anthropic only). Empty for providers that don't
    /// break cost down by type.
    var extraCosts: [ExtraCost] = []

    var totalTokens: Int { inputTokens + outputTokens }
    /// Fable-family total tokens (the "Claude Fable" bucket).
    var fableTokens: Int { models.filter(\.isFable).reduce(0) { $0 + $1.totalTokens } }
    /// All non-Fable models' total tokens.
    var otherModelTokens: Int { models.filter { !$0.isFable }.reduce(0) { $0 + $1.totalTokens } }
}

/// The reporting window, in whole days ending "now".
enum UsageWindow: Int, CaseIterable, Identifiable {
    case today = 1
    case sevenDays = 7
    case thirtyDays = 30

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
    }

    /// Anthropic/OpenAI usage data updates roughly hourly; the `today` window
    /// buckets by the hour for freshness, longer windows by the day.
    var bucketWidthAnthropic: String { self == .today ? "1h" : "1d" }
    var bucketWidthOpenAI: String { self == .today ? "1h" : "1d" }
    /// Max buckets to request per page (Anthropic caps 1d at 31, 1h at 168).
    var pageLimit: Int { self == .today ? 24 : 31 }
}

/// Pulls comprehensive AI usage + cost stats from the Claude and OpenAI ("Codex")
/// **Admin** APIs and exposes per-provider aggregates — including per-model
/// breakdowns and non-token cost lines — for the inspector's Usage tab.
///
/// Both providers gate usage/cost behind an org-scoped admin key (see
/// `UsageCredentials`); a regular inference key yields 401/403, surfaced here as
/// a per-provider error so one provider failing never blanks the other.
/// Credentials are read fresh from the Keychain on every `reload()`.
///
/// Note: Anthropic exposes **no credit-balance endpoint** — only spend (Cost
/// Report). We capture every `cost_type` it reports (tokens + web search + code
/// execution + session usage), which is the closest the API gets to "everything".
@Observable
@MainActor
final class UsageStore {
    private(set) var anthropic: ProviderUsage?
    private(set) var openAI: ProviderUsage?
    private(set) var anthropicError: String?
    private(set) var openAIError: String?
    private(set) var isLoading = false
    var window: UsageWindow = .thirtyDays {
        didSet { if oldValue != window { reload() } }
    }

    private var loadTask: Task<Void, Never>?
    private var pollTimer: Timer?

    /// Matches `GitCommitStore` / `GitHubTasksStore` cadence.
    private static let pollInterval: TimeInterval = 60

    /// True when at least one provider has an admin key stored.
    var hasAnyCredentials: Bool {
        UsageCredentials.hasKey(for: .anthropic) || UsageCredentials.hasKey(for: .openAI)
    }

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

    /// Fetch both providers concurrently, reading keys fresh from the Keychain.
    func reload() {
        loadTask?.cancel()
        let window = window
        let anthropicKey = UsageCredentials.key(for: .anthropic)
        let openAIKey = UsageCredentials.key(for: .openAI)

        guard anthropicKey != nil || openAIKey != nil else {
            anthropic = nil; openAI = nil
            anthropicError = nil; openAIError = nil
            isLoading = false
            return
        }

        isLoading = true
        loadTask = Task {
            async let anthropicResult = Self.fetchAnthropicOptional(key: anthropicKey, window: window)
            async let openAIResult = Self.fetchOpenAIOptional(key: openAIKey, window: window)

            let (aRes, oRes) = await (anthropicResult, openAIResult)
            if Task.isCancelled { return }

            switch aRes {
            case .some(.success(let usage)): anthropic = usage; anthropicError = nil
            case .some(.failure(let error)): anthropicError = error // keep last good `anthropic`
            case .none: anthropic = nil; anthropicError = nil
            }
            switch oRes {
            case .some(.success(let usage)): openAI = usage; openAIError = nil
            case .some(.failure(let error)): openAIError = error
            case .none: openAI = nil; openAIError = nil
            }
            isLoading = false
        }
    }

    // MARK: - Window helpers

    /// Start-of-window as an RFC 3339 UTC timestamp (bucket-aligned) and its unix seconds.
    nonisolated private static func startOfWindow(_ window: UsageWindow) -> (rfc3339: String, unix: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let start: Date
        if window == .today {
            start = calendar.startOfDay(for: now)
        } else {
            let startOfToday = calendar.startOfDay(for: now)
            start = calendar.date(byAdding: .day, value: -(window.rawValue - 1), to: startOfToday) ?? startOfToday
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return (formatter.string(from: start), Int(start.timeIntervalSince1970))
    }

    /// Sort a model map into a stable, cost-then-token-descending list.
    nonisolated private static func sortedModels(_ map: [String: ModelUsage]) -> [ModelUsage] {
        map.values.sorted {
            if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.model < $1.model
        }
    }

    // MARK: - Anthropic

    nonisolated private static func fetchAnthropicOptional(key: String?, window: UsageWindow) async -> ProviderFetch? {
        guard let key else { return nil }
        return await fetchAnthropic(key: key, window: window)
    }

    nonisolated private static func fetchAnthropic(key: String, window: UsageWindow) async -> ProviderFetch {
        let start = startOfWindow(window).rfc3339
        let headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
        var usage = ProviderUsage()
        var models: [String: ModelUsage] = [:]

        // 1. Token usage, grouped by model.
        do {
            var page: String?
            var guardCounter = 0
            repeat {
                var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!
                var items = [
                    URLQueryItem(name: "starting_at", value: start),
                    URLQueryItem(name: "bucket_width", value: window.bucketWidthAnthropic),
                    URLQueryItem(name: "limit", value: String(window.pageLimit)),
                    URLQueryItem(name: "group_by[]", value: "model"),
                ]
                if let page { items.append(URLQueryItem(name: "page", value: page)) }
                components.queryItems = items

                let report: AnthropicUsageReport = try await getJSON(url: components.url!, headers: headers)
                for bucket in report.data {
                    for result in bucket.results {
                        let inputTokens = result.uncached_input_tokens ?? 0
                        let cache = (result.cache_read_input_tokens ?? 0)
                            + (result.cache_creation?.ephemeral_1h_input_tokens ?? 0)
                            + (result.cache_creation?.ephemeral_5m_input_tokens ?? 0)
                        let outputTokens = result.output_tokens ?? 0
                        let webSearch = result.server_tool_use?.web_search_requests ?? 0

                        usage.inputTokens += inputTokens
                        usage.cachedTokens += cache
                        usage.outputTokens += outputTokens
                        usage.webSearchRequests += webSearch

                        let name = result.model ?? "Other"
                        var entry = models[name] ?? ModelUsage(model: name)
                        entry.inputTokens += inputTokens
                        entry.cachedTokens += cache
                        entry.outputTokens += outputTokens
                        models[name] = entry
                    }
                }
                page = report.has_more ? report.next_page : nil
                guardCounter += 1
            } while page != nil && guardCounter < 40
        } catch {
            return .failure(describe(error, provider: "Claude"))
        }

        // 2. Cost, grouped by description (fills `model`, `cost_type`, `token_type`).
        //    `amount` is a decimal string in CENTS → divide by 100 for dollars.
        var extraCosts: [String: Double] = [:]
        do {
            var page: String?
            var guardCounter = 0
            repeat {
                var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
                var items = [
                    URLQueryItem(name: "starting_at", value: start),
                    URLQueryItem(name: "bucket_width", value: "1d"),
                    URLQueryItem(name: "limit", value: "31"),
                    URLQueryItem(name: "group_by[]", value: "description"),
                ]
                if let page { items.append(URLQueryItem(name: "page", value: page)) }
                components.queryItems = items

                let report: AnthropicCostReport = try await getJSON(url: components.url!, headers: headers)
                for bucket in report.data {
                    for result in bucket.results {
                        let dollars = (Double(result.amount) ?? 0) / 100.0
                        usage.costUSD += dollars

                        if result.cost_type == "tokens", let name = result.model {
                            var entry = models[name] ?? ModelUsage(model: name)
                            entry.costUSD += dollars
                            models[name] = entry
                        } else {
                            // Non-token spend: web_search / code_execution / session_usage.
                            let label = costTypeLabel(result.cost_type)
                            extraCosts[label, default: 0] += dollars
                        }
                    }
                }
                page = report.has_more ? report.next_page : nil
                guardCounter += 1
            } while page != nil && guardCounter < 40
        } catch {
            return .failure(describe(error, provider: "Claude"))
        }

        usage.models = sortedModels(models)
        usage.extraCosts = extraCosts
            .filter { $0.value > 0 }
            .map { ExtraCost(label: $0.key, costUSD: $0.value) }
            .sorted { $0.costUSD > $1.costUSD }
        return .success(usage)
    }

    nonisolated private static func costTypeLabel(_ raw: String?) -> String {
        switch raw {
        case "web_search": "Web search"
        case "code_execution": "Code execution"
        case "session_usage": "Session usage"
        case "tokens": "Tokens"
        default: (raw?.replacingOccurrences(of: "_", with: " ").capitalized) ?? "Other"
        }
    }

    // MARK: - OpenAI ("Codex")

    nonisolated private static func fetchOpenAIOptional(key: String?, window: UsageWindow) async -> ProviderFetch? {
        guard let key else { return nil }
        return await fetchOpenAI(key: key, window: window)
    }

    nonisolated private static func fetchOpenAI(key: String, window: UsageWindow) async -> ProviderFetch {
        let start = startOfWindow(window).unix
        let headers = ["Authorization": "Bearer \(key)"]
        var usage = ProviderUsage()
        var models: [String: ModelUsage] = [:]

        // 1. Completions token usage, grouped by model.
        do {
            var page: String?
            var guardCounter = 0
            repeat {
                var components = URLComponents(string: "https://api.openai.com/v1/organizations/usage/completions")!
                var items = [
                    URLQueryItem(name: "start_time", value: String(start)),
                    URLQueryItem(name: "bucket_width", value: window.bucketWidthOpenAI),
                    URLQueryItem(name: "limit", value: String(window.pageLimit)),
                    URLQueryItem(name: "group_by", value: "model"),
                ]
                if let page { items.append(URLQueryItem(name: "page", value: page)) }
                components.queryItems = items

                let report: OpenAIUsageReport = try await getJSON(url: components.url!, headers: headers)
                for bucket in report.data {
                    for result in bucket.results {
                        let inputTokens = result.input_tokens ?? 0
                        let cached = result.input_cached_tokens ?? 0
                        let outputTokens = result.output_tokens ?? 0
                        let requests = result.num_model_requests ?? 0

                        usage.inputTokens += inputTokens
                        usage.cachedTokens += cached
                        usage.outputTokens += outputTokens
                        usage.requests += requests

                        let name = result.model ?? "Other"
                        var entry = models[name] ?? ModelUsage(model: name)
                        entry.inputTokens += inputTokens
                        entry.cachedTokens += cached
                        entry.outputTokens += outputTokens
                        entry.requests += requests
                        models[name] = entry
                    }
                }
                page = (report.has_more == true) ? report.next_page : nil
                guardCounter += 1
            } while page != nil && guardCounter < 40
        } catch {
            return .failure(describe(error, provider: "Codex"))
        }

        // 2. Cost (dollars — OpenAI reports `amount.value` already in USD).
        //    OpenAI's Costs endpoint can't group by model, so this is a total only.
        do {
            var page: String?
            var guardCounter = 0
            repeat {
                var components = URLComponents(string: "https://api.openai.com/v1/organizations/costs")!
                var items = [
                    URLQueryItem(name: "start_time", value: String(start)),
                    URLQueryItem(name: "bucket_width", value: "1d"),
                    URLQueryItem(name: "limit", value: "31"),
                ]
                if let page { items.append(URLQueryItem(name: "page", value: page)) }
                components.queryItems = items

                let report: OpenAICostReport = try await getJSON(url: components.url!, headers: headers)
                for bucket in report.data {
                    for result in bucket.results {
                        usage.costUSD += result.amount?.value ?? 0
                    }
                }
                page = (report.has_more == true) ? report.next_page : nil
                guardCounter += 1
            } while page != nil && guardCounter < 40
        } catch {
            return .failure(describe(error, provider: "Codex"))
        }

        usage.models = sortedModels(models)
        return .success(usage)
    }

    // MARK: - Networking

    nonisolated private static func getJSON<T: Decodable>(url: URL, headers: [String: String]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UsageFetchError.http(status: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    nonisolated private static func describe(_ error: Error, provider: String) -> String {
        switch error {
        case UsageFetchError.http(let status) where status == 401 || status == 403:
            return "\(provider): key rejected — an Admin API key is required for usage."
        case UsageFetchError.http(let status):
            return "\(provider): request failed (HTTP \(status))."
        case is DecodingError:
            return "\(provider): couldn’t read the usage response."
        default:
            return "\(provider): couldn’t reach the usage API."
        }
    }
}

private enum UsageFetchError: Error {
    case http(status: Int)
}

/// Outcome of one provider fetch. A plain two-case enum (rather than
/// `Result<_, String>`, whose `Failure` must be an `Error`) so failures can
/// carry a ready-to-display message.
private enum ProviderFetch {
    case success(ProviderUsage)
    case failure(String)
}

// MARK: - Anthropic response models

private struct AnthropicUsageReport: Decodable {
    let data: [Bucket]
    let has_more: Bool
    let next_page: String?

    struct Bucket: Decodable { let results: [Item] }
    struct Item: Decodable {
        let model: String?
        let uncached_input_tokens: Int?
        let cache_read_input_tokens: Int?
        let output_tokens: Int?
        let cache_creation: CacheCreation?
        let server_tool_use: ServerToolUse?
    }
    struct CacheCreation: Decodable {
        let ephemeral_1h_input_tokens: Int?
        let ephemeral_5m_input_tokens: Int?
    }
    struct ServerToolUse: Decodable {
        let web_search_requests: Int?
    }
}

private struct AnthropicCostReport: Decodable {
    let data: [Bucket]
    let has_more: Bool
    let next_page: String?

    struct Bucket: Decodable { let results: [Item] }
    struct Item: Decodable {
        let amount: String
        let cost_type: String?
        let model: String?
    }
}

// MARK: - OpenAI response models

private struct OpenAIUsageReport: Decodable {
    let data: [Bucket]
    let has_more: Bool?
    let next_page: String?

    struct Bucket: Decodable { let results: [Item] }
    struct Item: Decodable {
        let model: String?
        let input_tokens: Int?
        let output_tokens: Int?
        let input_cached_tokens: Int?
        let num_model_requests: Int?
    }
}

private struct OpenAICostReport: Decodable {
    let data: [Bucket]
    let has_more: Bool?
    let next_page: String?

    struct Bucket: Decodable { let results: [Item] }
    struct Item: Decodable { let amount: Amount? }
    struct Amount: Decodable { let value: Double? }
}
