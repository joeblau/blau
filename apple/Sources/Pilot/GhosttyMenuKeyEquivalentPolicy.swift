import AppKit

/// Decides whether a key equivalent pressed while a Ghostty terminal is the
/// first responder should be offered to Pilot's main menu before Ghostty's
/// binding system consumes it. Kept separate and pure so the routing is unit
/// testable, mirroring `BrowserWebShortcutPolicy` for the browser pane.
enum GhosttyMenuKeyEquivalentPolicy {
    /// Plain-⌘ keys Ghostty handles itself, so they never reach Pilot's menu:
    /// editing (⌘C/V/X/A/Z), pane focus (⌘F), and Settings (⌘,).
    static let reservedPlainCommandKeys: Set<String> = ["c", "v", "x", "a", "z", "f", ","]

    /// Control combos always stay with the terminal (Ghostty owns C-c, C-d, …).
    /// Plain ⌘ editing/focus keys stay too. Every ⌥⌘ combo is a Pilot shortcut
    /// (⌥⌘E toggles Extendo, ⌥⌘D opens the web inspector, ⌥⌘0 is Actual Size) —
    /// terminal Meta input is Option *without* Command — so those must reach the
    /// menu instead of being eaten by the terminal. `characters` is
    /// `charactersIgnoringModifiers`, lowercased.
    static func forwardsToMainMenu(
        hasCommand: Bool,
        hasControl: Bool,
        hasOption: Bool,
        characters: String
    ) -> Bool {
        guard hasCommand, !hasControl else { return false }
        if hasOption { return true }
        return !reservedPlainCommandKeys.contains(characters)
    }
}
