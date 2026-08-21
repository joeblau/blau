import Foundation

/// USD rates per million tokens for one model.
///
/// - `cacheRead` defaults to 0.1x input (the Anthropic/Moonshot convention)
///   but can be overridden for models with bespoke cache pricing.
/// - `fastInput`/`fastOutput` are optional priority-tier rates (Claude).
struct AgenticModelRate: Sendable, Equatable {
    let inputPerMillionUSD: Double
    let outputPerMillionUSD: Double
    let cacheReadPerMillionUSD: Double
    let fastInputPerMillionUSD: Double?
    let fastOutputPerMillionUSD: Double?

    init(
        input: Double,
        output: Double,
        cacheRead: Double? = nil,
        fastInput: Double? = nil,
        fastOutput: Double? = nil
    ) {
        self.inputPerMillionUSD = input
        self.outputPerMillionUSD = output
        self.cacheReadPerMillionUSD = cacheRead ?? input * AgenticUsagePricing.cacheReadMultiplier
        self.fastInputPerMillionUSD = fastInput
        self.fastOutputPerMillionUSD = fastOutput
    }

    /// The input rate for a record, honoring the fast tier when the model
    /// defines one; models without a fast row bill fast calls at standard.
    func inputRate(fast: Bool) -> Double {
        fast ? (fastInputPerMillionUSD ?? inputPerMillionUSD) : inputPerMillionUSD
    }

    func outputRate(fast: Bool) -> Double {
        fast ? (fastOutputPerMillionUSD ?? outputPerMillionUSD) : outputPerMillionUSD
    }
}

/// The authoritative pricing table and cost math for Agentic Use.
///
/// Cost is computed from tokens except when the log itself carries an exact
/// cost (`nativeCostUSD`, Grok), which always wins. A model absent from
/// `rates` yields `nil` (an "unpriced" record) so unknown models surface in
/// the UI instead of silently costing $0.
enum AgenticUsagePricing {
    /// Cache writes bill at 1.25x the model's input rate (5-minute TTL).
    static let cacheWrite5mMultiplier = 1.25
    /// 1h-TTL cache writes bill at 2.0x the model's input rate, matching the
    /// API price sheet and ccusage.
    static let cacheWrite1hMultiplier = 2.0
    /// Default cache-read rate: 0.1x the model's input rate.
    static let cacheReadMultiplier = 0.1

    /// USD per 1M tokens. Adding a model is one line. Non-Claude rates match
    /// what ccusage bills (models.dev / LiteLLM), verified against its daily
    /// cost output to the cent for the high-volume models.
    static let rates: [String: AgenticModelRate] = [
        // Claude (Anthropic price sheet).
        "claude-opus-5": AgenticModelRate(input: 5.00, output: 25.00, fastInput: 10.00, fastOutput: 50.00),
        "claude-fable-5": AgenticModelRate(input: 10.00, output: 50.00),
        "claude-mythos-5": AgenticModelRate(input: 10.00, output: 50.00),
        "claude-opus-4-8": AgenticModelRate(input: 5.00, output: 25.00),
        "claude-opus-4-7": AgenticModelRate(input: 5.00, output: 25.00),
        "claude-opus-4-6": AgenticModelRate(input: 5.00, output: 25.00),
        "claude-opus-4-5": AgenticModelRate(input: 5.00, output: 25.00),
        "claude-sonnet-5": AgenticModelRate(input: 3.00, output: 15.00),
        "claude-sonnet-4-6": AgenticModelRate(input: 3.00, output: 15.00),
        "claude-sonnet-4-5": AgenticModelRate(input: 3.00, output: 15.00),
        "claude-haiku-4-5": AgenticModelRate(input: 1.00, output: 5.00),
        // Codex (OpenAI). Cache reads are a flat 0.1x input and no model here
        // has a long-context tier — the tiered rate sheets belong to the
        // hosted variants (databricks-*, *@eu), not the CLI's models.
        "gpt-5.6-sol": AgenticModelRate(input: 5.00, output: 30.00),
        "gpt-5.5": AgenticModelRate(input: 5.00, output: 30.00),
        "gpt-5.4": AgenticModelRate(input: 2.50, output: 15.00),
        "gpt-5.3-codex": AgenticModelRate(input: 1.75, output: 14.00),
        "gpt-5.3-codex-spark": AgenticModelRate(input: 1.75, output: 14.00),
        "gpt-5.2-codex": AgenticModelRate(input: 1.75, output: 14.00),
        "gpt-5.1-codex-mini": AgenticModelRate(input: 0.225, output: 1.80),
        "gpt-5-codex": AgenticModelRate(input: 1.25, output: 10.00),
        "gpt-5": AgenticModelRate(input: 1.375, output: 10.96, cacheRead: 0.156),
        // Grok (xAI). Normally billed from the log's own costUsdTicks; these
        // rates are the fallback for turns that lack a native cost.
        "grok-4.5": AgenticModelRate(input: 2.00, output: 6.00, cacheRead: 0.50),
        "grok-4.5-build": AgenticModelRate(input: 2.00, output: 6.00, cacheRead: 0.50),
        // Kimi (Moonshot). k3-256k, k3-max, and kimi-for-coding have no
        // published rate and surface as unpriced, matching ccusage.
        "k3": AgenticModelRate(input: 4.50, output: 22.50),
        "moonshot-ai/kimi-k3": AgenticModelRate(input: 3.00, output: 15.00),
    ]

    static func rate(for model: String) -> AgenticModelRate? {
        rates[model]
    }

    static func isPriced(_ model: String) -> Bool {
        rates[model] != nil
    }

    /// Actual USD cost of one record, or `nil` when the model is unpriced.
    ///
    /// cost = (input x in) + (cacheWrite5m x in x 1.25) + (cacheWrite1h x in x 2.0)
    ///        + (cacheRead x cacheReadRate) + (output x out), per million tokens —
    /// unless the record carries a native cost, which is exact and wins.
    static func cost(of record: AgenticUsageRecord) -> Double? {
        if let native = record.nativeCostUSD { return native }
        guard let rate = rates[record.model] else { return nil }
        let effective = effectiveRates(for: rate, record: record)
        let write1h = min(record.cacheWrite1hTokens, record.cacheWriteTokens)
        let write5m = record.cacheWriteTokens - write1h
        let total = Double(record.inputTokens) * effective.input
            + Double(write5m) * effective.input * cacheWrite5mMultiplier
            + Double(write1h) * effective.input * cacheWrite1hMultiplier
            + Double(record.cacheReadTokens) * effective.cacheRead
            + Double(record.outputTokens) * effective.output
        return total / 1_000_000
    }

    /// Hypothetical cost if every input token had billed at the full input
    /// rate — the baseline that makes "cache savings" (`fullRateCost - cost`)
    /// meaningful. `nil` when the model is unpriced (native-cost records
    /// still need a table entry to have a baseline).
    static func fullRateCost(of record: AgenticUsageRecord) -> Double? {
        guard let rate = rates[record.model] else { return nil }
        let effective = effectiveRates(for: rate, record: record)
        let total = Double(record.observedInputTokens) * effective.input
            + Double(record.outputTokens) * effective.output
        return total / 1_000_000
    }

    /// A record's rates, honoring the priority tier when the model defines
    /// one. Fast calls scale the cache-read rate off the fast input rate so
    /// the 0.1x relationship holds on both tiers.
    private static func effectiveRates(
        for rate: AgenticModelRate,
        record: AgenticUsageRecord
    ) -> (input: Double, output: Double, cacheRead: Double) {
        (
            rate.inputRate(fast: record.isFast),
            rate.outputRate(fast: record.isFast),
            record.isFast
                ? rate.inputRate(fast: true) * cacheReadMultiplier
                : rate.cacheReadPerMillionUSD
        )
    }
}
