import SwiftUI

/// Shared key for the Settings window's selected section, so a "Set up" button
/// can deep-link straight to the Usage settings section.
enum SettingsTab {
    static let storageKey = "settings.selectedTab"
    static let general = "general"
    static let usage = "usage"
}

/// Inspector "Usage" tab. Two stacked cards — **Claude** on top, **Codex**
/// (OpenAI) below — each showing plan usage windows (utilization + reset
/// countdown) and credits, read from your local `claude` / `codex` CLI sessions.
/// A not-signed-in card links to the Usage settings section for setup help.
struct UsageListView: View {
    let store: UsageStore

    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var selectedSettingsTab = SettingsTab.general

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    ProviderCard(
                        title: "Claude",
                        systemImage: "sparkle",
                        tint: .orange,
                        cli: "claude",
                        state: store.anthropic,
                        openSetup: openSetup
                    )
                    ProviderCard(
                        title: "Codex",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        tint: .green,
                        cli: "codex",
                        state: store.openAI,
                        openSetup: openSetup
                    )
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Plan Usage")
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
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

    private func openSetup() {
        selectedSettingsTab = SettingsTab.usage
        openSettings()
    }
}

/// One provider's plan usage card. Renders per `ProviderState`.
private struct ProviderCard: View {
    let title: String
    let systemImage: String
    let tint: Color
    let cli: String
    let state: ProviderState
    let openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(title)
                .scaledFont(size: 12, weight: .semibold)
            if case .usage(let usage) = state, let plan = usage.planLabel {
                Text(plan)
                    .scaledFont(size: 9, weight: .bold)
                    .foregroundStyle(tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.15), in: Capsule())
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .center)

        case .notSignedIn:
            setupPrompt(message: "Not signed in. Run `\(cli)` in a terminal to log in, then refresh.")

        case .error(let message):
            setupPrompt(message: message)

        case .usage(let usage):
            if usage.windows.isEmpty && usage.credits == nil {
                Text("No usage reported for this window.")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(usage.windows) { window in
                        windowRow(window)
                    }
                }
                if let credits = usage.credits, !credits.isEmpty {
                    Divider().padding(.vertical, 2)
                    creditsRow(credits)
                }
            }
        }
    }

    private func windowRow(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.name)
                    .scaledFont(size: 11, weight: .medium)
                Spacer()
                Text("\(Int((window.utilization * 100).rounded()))%")
                    .scaledFont(size: 11, weight: .semibold, design: .rounded)
                    .foregroundStyle(barColor(window.utilization))
            }
            ProgressView(value: min(max(window.utilization, 0), 1))
                .progressViewStyle(.linear)
                .tint(barColor(window.utilization))
            if let reset = Self.resetText(window.resetsAt) {
                Text(reset)
                    .scaledFont(size: 9)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func creditsRow(_ credits: CreditInfo) -> some View {
        HStack {
            Text("Credits")
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
            Spacer()
            if credits.unlimited {
                Text("Unlimited")
                    .scaledFont(size: 11, weight: .semibold)
            } else if let balance = credits.balanceUSD {
                Text(balance.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                    .scaledFont(size: 11, design: .monospaced)
            } else if let utilization = credits.utilization {
                Text("\(Int((utilization * 100).rounded()))% used")
                    .scaledFont(size: 11, design: .monospaced)
            }
        }
    }

    private func setupPrompt(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: openSetup) {
                Label("Set up", systemImage: "arrow.up.forward")
                    .scaledFont(size: 11)
            }
            .buttonStyle(.link)
        }
    }

    private func barColor(_ utilization: Double) -> Color {
        switch utilization {
        case ..<0.75: tint
        case ..<0.9: .yellow
        default: .red
        }
    }

    /// "resets in 3h 12m" / "resets in 2d 4h", or nil when unknown.
    private static func resetText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "resetting…" }
        let totalMinutes = Int(remaining / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }
}
