import SwiftUI

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
    var body: some View {
        Section {
            LabeledContent("Public key") {
                Text("Not yet generated")
                    .foregroundStyle(.secondary)
            }
            // Key exchange / trusted-peer management lands in #51; the entry
            // point is present but disabled so the screen is wired end-to-end.
            Button {
                // Intentionally empty until key sharing ships (#51).
            } label: {
                Label("Share device key…", systemImage: "key")
            }
            .disabled(true)
        } header: {
            Text("Identity & Keys")
        } footer: {
            Text("Exchange device keys to encrypt the peer-to-peer channel. Coming soon.")
        }

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
