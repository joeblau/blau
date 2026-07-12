import SwiftUI

/// Settings tab for connecting the Claude and OpenAI **Admin** APIs so the
/// inspector's Usage tab can report tokens and cost.
///
/// These endpoints require an org-scoped *admin* key — a regular inference key
/// is rejected — so the fields and footers say so explicitly.
struct UsageSettingsView: View {
    @State private var model = UsageSettingsModel()
    @State private var savedFlash = false

    var body: some View {
        Form {
            Section {
                SecureField("sk-ant-admin…", text: $model.anthropicKey)
                    .textContentType(.password)
            } header: {
                statusHeader("Claude Admin Key", connected: model.hasAnthropicKey)
            } footer: {
                Text("Create an Admin key in the Anthropic Console under Settings → Admin Keys. Usage & cost reporting needs an admin key, not a standard API key.")
            }

            Section {
                SecureField("sk-admin-…", text: $model.openAIKey)
                    .textContentType(.password)
            } header: {
                statusHeader("Codex (OpenAI) Admin Key", connected: model.hasOpenAIKey)
            } footer: {
                Text("Create an Admin key in the OpenAI platform under Settings → Admin keys. The Usage & Costs APIs require an admin key.")
            }

            Section {
                HStack {
                    Button {
                        model.save()
                        savedFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { savedFlash = false }
                    } label: {
                        Label("Save Keys", systemImage: "checkmark.circle")
                    }
                    if savedFlash {
                        Text("Saved")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Spacer()
                }
            } footer: {
                Text("Keys are stored in your macOS Keychain and never leave this device except to call each provider's usage API.")
            }
        }
        .animation(.snappy, value: savedFlash)
    }

    private func statusHeader(_ title: String, connected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if connected {
                Text("Connected")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.15), in: Capsule())
                    .textCase(nil)
            }
        }
    }
}
