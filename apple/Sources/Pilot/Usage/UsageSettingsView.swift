import SwiftUI

/// Settings section for AI usage. There are **no keys to enter** — usage is read
/// from the `claude` and `codex` CLI sessions already on this Mac. This page
/// shows whether each is signed in and how to sign in if not.
struct UsageSettingsView: View {
    @State private var claudeSignedIn: Bool?
    @State private var codexSignedIn: Bool?

    private static let claudeDocsURL = URL(string: "https://code.claude.com/docs/en/overview")!
    private static let codexDocsURL = URL(string: "https://developers.openai.com/codex/cli")!

    var body: some View {
        Form {
            Section {
                statusRow(signedIn: claudeSignedIn)
                Link(destination: Self.claudeDocsURL) {
                    Label("Install & sign in to Claude Code", systemImage: "arrow.up.forward.app")
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("Run `claude` in a terminal to sign in. Usage is read from Claude Code's session — reading it from the Keychain may prompt you to Allow once.")
            }

            Section {
                statusRow(signedIn: codexSignedIn)
                Link(destination: Self.codexDocsURL) {
                    Label("Install & sign in to Codex", systemImage: "arrow.up.forward.app")
                }
            } header: {
                Text("Codex")
            } footer: {
                Text("Run `codex` in a terminal to sign in. Usage is read from ~/.codex/auth.json.")
            }

            Section {
                EmptyView()
            } footer: {
                Text("Usage is read only, using your existing CLI logins — no keys are stored. It calls each provider's internal plan-usage endpoint, which is undocumented and may change.")
            }
        }
        .task { await detect() }
    }

    @ViewBuilder
    private func statusRow(signedIn: Bool?) -> some View {
        LabeledContent("Status") {
            switch signedIn {
            case .some(true):
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            case .some(false):
                Label("Not signed in", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            case .none:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func detect() async {
        let claude = await Task.detached { UsageSessions.ClaudeSession.load() != nil }.value
        let codex = await Task.detached { UsageSessions.CodexSession.load() != nil }.value
        claudeSignedIn = claude
        codexSignedIn = codex
    }
}
