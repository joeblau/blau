import AppKit
import SwiftUI

/// The connected pane launcher shared by Pilot's main and extension windows.
/// Supplying the owning workspace lets Extension reuse the exact controls while
/// keeping independent runtime IDs for every terminal, browser, and device.
struct WorkspacePaneLauncher: View {
    let workspace: Workspace?

    @ObservedObject private var chromiumDiagnostics = ChromiumDiagnosticsCenter.shared
    @ObservedObject private var chromiumProfileAccess =
        ChromiumProfileAccessCoordinator.shared

    var body: some View {
        HStack(spacing: 0) {
            paneButtons
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: Capsule())
        .disabled(workspace == nil)
        .accessibilityIdentifier("workspace.pane-launcher")
    }

    @ViewBuilder
    private var paneButtons: some View {
        Button {
            workspace?.addPane(kind: .terminal, side: .right)
        } label: {
            launcherLabel("New Terminal", systemImage: PaneKind.terminal.systemImageName)
        }
        .frame(width: 36, height: 36)

        // No `primaryAction`: clicking opens the engine chooser rather than
        // silently picking WebKit, matching the Apple and Android buttons beside
        // it. ⌘B still opens a WebKit browser directly from the main menu.
        Menu {
            ForEach(BrowserEngine.allCases, id: \.self) { engine in
                Button {
                    addBrowserPane(engine: engine)
                } label: {
                    Label("\(engine.displayName) Browser", systemImage: engine.systemImageName)
                }
                .disabled(!browserCreationEnabled(for: engine))
            }

            // A greyed-out Chromium row is otherwise unexplained, and the three
            // causes need different answers — most often nothing is wrong at all,
            // just a build that deliberately ships without the CEF runtime.
            if let reason = chromiumUnavailableReason {
                Section {
                    Text(reason.message)
                }
            }
        } label: {
            launcherLabel("New Browser", systemImage: BrowserEngine.webKit.systemImageName)
        }
        .menuIndicator(.hidden)
        .frame(width: 36, height: 36)
        .help("Open a browser pane — choose WebKit or Chromium")
        .accessibilityIdentifier("workspace.browser-pane-launcher")

        Menu {
            Button {
                workspace?.addPane(kind: .simulator, side: .right)
            } label: {
                Label("Simulator", systemImage: PaneKind.simulator.systemImageName)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button {
                workspace?.addPane(kind: .device, side: .right)
            } label: {
                Label("Device Stream", systemImage: PaneKind.device.systemImageName)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        } label: {
            launcherLabel("Apple", systemImage: "apple.logo")
        }
        .menuIndicator(.hidden)
        .frame(width: 36, height: 36)
        .help("Open an Apple Simulator or QuickTime device stream")
        .accessibilityIdentifier("workspace.apple-pane-launcher")

        Menu {
            Button {
                addAndroidPane(target: .simulator)
            } label: {
                Label("Android Simulator", systemImage: "apps.iphone")
            }

            Button {
                addAndroidPane(target: .device)
            } label: {
                Label("Android Device", systemImage: "smartphone")
            }
        } label: {
            launcherLabel("Android") {
                Image("AndroidRobot")
            }
        }
        .menuIndicator(.hidden)
        .frame(width: 36, height: 36)
        .help("Open an Android Simulator or device stream")
        .accessibilityIdentifier("workspace.android-pane-launcher")

        Button {
            workspace?.addPane(kind: .editor, side: .right)
        } label: {
            launcherLabel("Open Editor", systemImage: PaneKind.editor.systemImageName)
        }
        .frame(width: 36, height: 36)
        .keyboardShortcut("e", modifiers: .command)
        .disabled(workspace?.effectiveRootPath == nil)
        .help(
            workspace?.effectiveRootPath == nil
                ? "Set a workspace root path to open the editor"
                : "Open a file editor with fuzzy file search"
        )

        Button {
            if let rootPath = workspace?.effectiveRootPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: rootPath))
            }
        } label: {
            launcherLabel("Open in Finder", systemImage: "folder")
        }
        .frame(width: 36, height: 36)
        .disabled(workspace?.effectiveRootPath == nil)
        .help(
            workspace?.effectiveRootPath == nil
                ? "Set a workspace root path to open it in Finder"
                : "Open the workspace folder in Finder"
        )
    }

    private func addAndroidPane(target: AndroidPaneTarget) {
        guard let pane = workspace?.addPane(kind: .android, side: .right) else { return }
        AndroidDeviceRegistry.shared.configure(target: target, for: pane.id)
    }

    private func addBrowserPane(engine: BrowserEngine) {
        workspace?.addBrowserPane(engine: engine, side: .right)
    }

    private var chromiumUnavailableReason: ChromiumUnavailableReason? {
        _ = chromiumDiagnostics.runtimeStatus
        _ = chromiumProfileAccess.isClearing
        return ChromiumBrowserCreationPolicy.unavailableReason
    }

    private func browserCreationEnabled(for engine: BrowserEngine) -> Bool {
        _ = chromiumDiagnostics.runtimeStatus
        _ = chromiumProfileAccess.isClearing
        return BrowserPaneCreationPolicy.permitsCreation(
            for: engine,
            chromiumCreationEnabled:
                ChromiumBrowserCreationPolicy.isCreationEnabled
        )
    }

    private func launcherLabel(_ title: String, systemImage: String) -> some View {
        launcherLabel(title) {
            Image(systemName: systemImage)
        }
    }

    private func launcherLabel<Icon: View>(
        _ title: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Label {
            Text(title)
        } icon: {
            icon()
        }
        .labelStyle(.iconOnly)
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
}
