import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// A shared, extensible Settings surface for Copilot, Pilot, and Plotter.
//
// `SettingsSections` is the cross-platform body (a set of `Section`s meant to
// live inside a `Form`); it's the container we add to over time — pairing,
// appearance, diagnostics, etc. For now it carries a placeholder Identity &
// Keys section (the home for peer key sharing, #51) and an About section.
//
// The iOS apps present it as a sheet via `SettingsButton`/`SettingsScreen`;
// Pilot drops `SettingsSections` into a macOS `Settings { }` scene.

/// App name / version / build read from the bundle's Info.plist. The project
/// maps these to `PRODUCT_NAME` / `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.
enum AppInfo {
    static var name: String {
        bundleString("CFBundleDisplayName") ?? bundleString("CFBundleName") ?? "blau"
    }
    static var version: String { bundleString("CFBundleShortVersionString") ?? "—" }
    static var build: String { bundleString("CFBundleVersion") ?? "—" }

    private static func bundleString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}

/// The settings sections shared across all three apps. Place inside a `Form`.
struct SettingsSections: View {
    /// The device's long-term public key (base64), loaded once from the
    /// Keychain-backed identity (issue #51). `nil` while loading or on failure.
    @State private var publicKey: String?
    #if os(macOS)
    /// Pilot presents its secure-messaging screen as a sheet (the macOS Settings
    /// scene has no NavigationStack to push into).
    @State private var showSecureMessaging = false
    #endif

    var body: some View {
        Section {
            LabeledContent("Public key") {
                if let publicKey {
                    Text(publicKey)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text("Generating…")
                        .foregroundStyle(.secondary)
                }
            }
            // Share the device's public key so a peer can enter it during
            // pairing for the Noise IK handshake (issue #51).
            if let publicKey {
                #if os(iOS)
                ShareLink(item: publicKey) {
                    Label("Share device key…", systemImage: "key")
                }
                #else
                Button {
                    #if canImport(AppKit)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(publicKey, forType: .string)
                    #endif
                } label: {
                    Label("Copy device key", systemImage: "key")
                }
                #endif
            }
            // Copilot-only: peer-to-peer secure messaging over the encrypted
            // channel (issue #51). Gated to the Copilot target so the screen,
            // which lives in Sources/Copilot, doesn't leak into Pilot/Plotter.
            #if os(iOS) && COPILOT
            NavigationLink {
                SecureMessagingView()
            } label: {
                Label("Secure messaging…", systemImage: "lock.fill")
            }
            #endif
            // Pilot (macOS): the responder side of the same encrypted channel
            // (issue #51, Phase 4). Presented as a sheet from the Settings window.
            #if os(macOS)
            Button {
                showSecureMessaging = true
            } label: {
                Label("Secure messaging…", systemImage: "lock.fill")
            }
            #endif
        } header: {
            Text("Identity & Keys")
        } footer: {
            Text("Share this device's public key with your peer to encrypt the peer-to-peer channel.")
        }
        .task {
            // Generate-or-load off the main actor; Keychain access can block.
            publicKey = await Task.detached { DeviceIdentity.publicKeyBase64() }.value
        }
        #if os(macOS)
        .sheet(isPresented: $showSecureMessaging) {
            NavigationStack {
                PilotSecureMessagingView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSecureMessaging = false }
                        }
                    }
            }
        }
        #endif

        Section("About") {
            LabeledContent("App", value: AppInfo.name)
            LabeledContent("Version", value: AppInfo.version)
            LabeledContent("Build", value: AppInfo.build)
        }
    }
}

#if os(iOS)
/// Self-contained gear button for the iOS apps (Copilot, Plotter): tapping it
/// presents the shared settings in a sheet. Owns its own presentation state, so
/// a host only needs to drop it into a toolbar or overlay.
struct SettingsButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
        .sheet(isPresented: $isPresented) {
            SettingsScreen()
        }
    }
}

/// The iOS settings screen: the shared sections in a `Form`, wrapped in a
/// `NavigationStack` with a Done button for sheet presentation.
struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                SettingsSections()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
