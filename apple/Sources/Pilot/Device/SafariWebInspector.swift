import AppKit

/// Reaches Safari's remote Web Inspector — where a connected iOS device's web
/// content is debugged. Safari's Develop menu lists every connected device that
/// has Web Inspector enabled; picking the mobile app's page opens the inspector.
///
/// macOS exposes no public API to open the Web Inspector pane itself, so the best
/// we can do is bring Safari frontmost with the device ready; the final
/// inspectable-target pick stays in Safari's Develop menu (#75).
enum SafariWebInspector {
    static func open() {
        guard let safari = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Safari"
        ) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: safari, configuration: configuration)
    }
}
