import SwiftUI

/// Shared key for the Settings window's selected tab, so a "Connect" button can
/// deep-link straight to the Usage settings tab.
enum SettingsTab {
    static let storageKey = "settings.selectedTab"
    static let general = "general"
    static let usage = "usage"
}

/// Inspector "Usage" tab. Two stacked sections — **Claude** on top, **Codex**
/// (OpenAI) below — each showing token + cost totals, a per-model breakdown
/// (Claude Fable called out), and non-token "other usage" spend. When nothing is
/// connected, an empty-state button opens Settings straight to the Usage tab.
struct UsageListView: View {
    let store: UsageStore

    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var selectedSettingsTab = SettingsTab.general

    var body: some View {
        if !store.hasAnyCredentials {
            emptyState
        } else {
            connectedState
        }
    }

    // MARK: - Empty (nothing connected)

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Usage Connected", systemImage: "chart.bar.xaxis")
        } description: {
            Text("Connect the Claude and Codex (OpenAI) Admin APIs to see your AI usage and cost here.")
        } actions: {
            Button {
                openUsageSettings()
            } label: {
                Label("Connect APIs", systemImage: "key")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Connected

    private var connectedState: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    // Claude on top, Codex underneath — per the requested order.
                    if UsageCredentials.hasKey(for: .anthropic) {
                        ProviderUsageCard(
                            title: UsageCredentials.Provider.anthropic.displayName,
                            systemImage: "sparkle",
                            tint: .orange,
                            usage: store.anthropic,
                            error: store.anthropicError
                        )
                    }
                    if UsageCredentials.hasKey(for: .openAI) {
                        ProviderUsageCard(
                            title: UsageCredentials.Provider.openAI.displayName,
                            systemImage: "chevron.left.forwardslash.chevron.right",
                            tint: .green,
                            usage: store.openAI,
                            error: store.openAIError
                        )
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Picker("Window", selection: Binding(get: { store.window }, set: { store.window = $0 })) {
                ForEach(UsageWindow.allCases) { window in
                    Text(window.label).tag(window)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            if store.isLoading {
                ProgressView().controlSize(.mini)
            }

            Spacer()

            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh usage")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func openUsageSettings() {
        selectedSettingsTab = SettingsTab.usage
        openSettings()
    }
}

/// One provider's totals plus per-model and non-token cost breakdowns.
private struct ProviderUsageCard: View {
    let title: String
    let systemImage: String
    let tint: Color
    let usage: ProviderUsage?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .scaledFont(size: 12, weight: .semibold)
                Spacer()
                if let usage {
                    Text(Self.currency(usage.costUSD))
                        .scaledFont(size: 13, weight: .bold, design: .rounded)
                        .foregroundStyle(tint)
                }
            }

            if let error {
                Text(error)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let usage {
                // Top-line token/request totals.
                VStack(spacing: 4) {
                    metricRow("Input", Self.tokens(usage.inputTokens))
                    metricRow("Output", Self.tokens(usage.outputTokens))
                    metricRow("Cached", Self.tokens(usage.cachedTokens))
                    if usage.requests > 0 {
                        metricRow("Requests", usage.requests.formatted(.number))
                    }
                    if usage.webSearchRequests > 0 {
                        metricRow("Web searches", usage.webSearchRequests.formatted(.number))
                    }
                }

                // Per-model breakdown (Fable tagged).
                if !usage.models.isEmpty {
                    sectionLabel("Models")
                    VStack(spacing: 4) {
                        ForEach(usage.models) { model in
                            modelRow(model)
                        }
                    }
                }

                // Non-token spend (Anthropic: web search / code exec / session).
                if !usage.extraCosts.isEmpty {
                    sectionLabel("Other usage")
                    VStack(spacing: 4) {
                        ForEach(usage.extraCosts) { extra in
                            HStack {
                                Text(extra.label)
                                    .scaledFont(size: 11)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(Self.currency(extra.costUSD))
                                    .scaledFont(size: 11, design: .monospaced)
                            }
                        }
                    }
                }
            } else if error == nil {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(size: 9, weight: .semibold)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private func modelRow(_ model: ModelUsage) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(Self.modelName(model.model))
                        .scaledFont(size: 11, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if model.isFable {
                        Text("Fable")
                            .scaledFont(size: 8, weight: .bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.purple, in: Capsule())
                    }
                }
                Text("\(Self.tokens(model.totalTokens)) tokens")
                    .scaledFont(size: 9)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if model.costUSD > 0 {
                Text(Self.currency(model.costUSD))
                    .scaledFont(size: 11, design: .monospaced)
            }
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .scaledFont(size: 11, design: .monospaced)
        }
    }

    /// Trim provider prefixes for a compact label (e.g. `claude-opus-4-8` → `opus-4-8`).
    private static func modelName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "claude-", with: "")
    }

    private static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }

    private static func currency(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
