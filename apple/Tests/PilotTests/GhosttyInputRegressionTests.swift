import AppKit
import GhosttyKit
import Testing
@testable import Pilot

@Suite("Ghostty mouse input regressions")
struct GhosttyInputRegressionTests {
    @Test("Built-in input overrides keep scrolling slow and Shift selection available")
    func builtInInputOverrides() {
        let lines = Set(GhosttyRuntime.terminalOverrideConfig.split(separator: "\n").map(String.init))
        #expect(lines.contains("mouse-scroll-multiplier = precision:1,discrete:1"))
        #expect(lines.contains("mouse-shift-capture = never"))
    }

    @Test(
        "Scroll metadata uses Ghostty's precision/momentum bit layout",
        arguments: [
            (NSEvent.Phase(), Int32(0)),
            (.began, Int32(2)),
            (.stationary, Int32(4)),
            (.changed, Int32(6)),
            (.ended, Int32(8)),
            (.cancelled, Int32(10)),
            (.mayBegin, Int32(12)),
        ]
    )
    func packsScrollMetadata(momentum: NSEvent.Phase, expected: Int32) {
        #expect(GhosttyScrollModifiers.packedValue(
            precision: false,
            momentumPhase: momentum
        ) == expected)
        #expect(GhosttyScrollModifiers.packedValue(
            precision: true,
            momentumPhase: momentum
        ) == expected | 1)
    }

    @Test("Combined momentum phases do not leak unrelated bits")
    func rejectsCombinedMomentumPhases() {
        let combined: NSEvent.Phase = [.began, .changed]
        #expect(GhosttyScrollModifiers.packedValue(
            precision: false,
            momentumPhase: combined
        ) == 0)
        #expect(GhosttyScrollModifiers.packedValue(
            precision: true,
            momentumPhase: combined
        ) == 1)
    }

    @Test("Only an unshifted captured press is deferred for drag arbitration")
    func capturedPressRouting() {
        #expect(GhosttyCapturedMouseSelectionPolicy.shouldDeferPress(
            isMouseCaptured: true,
            modifierFlags: []
        ))
        #expect(!GhosttyCapturedMouseSelectionPolicy.shouldDeferPress(
            isMouseCaptured: false,
            modifierFlags: []
        ))
        #expect(!GhosttyCapturedMouseSelectionPolicy.shouldDeferPress(
            isMouseCaptured: true,
            modifierFlags: .shift
        ))
    }

    @Test("A drag begins at the threshold and multi-clicks begin immediately")
    func selectionStartPolicy() {
        #expect(!GhosttyCapturedMouseSelectionPolicy.shouldBeginSelection(
            clickCount: 1,
            dragDistance: GhosttyCapturedMouseSelectionPolicy.dragThreshold - 0.01
        ))
        #expect(GhosttyCapturedMouseSelectionPolicy.shouldBeginSelection(
            clickCount: 1,
            dragDistance: GhosttyCapturedMouseSelectionPolicy.dragThreshold
        ))
        #expect(GhosttyCapturedMouseSelectionPolicy.shouldBeginSelection(
            clickCount: 2,
            dragDistance: 0
        ))
        #expect(GhosttyCapturedMouseSelectionPolicy.shouldBeginSelection(
            clickCount: 3,
            dragDistance: 0
        ))
    }

    @Test("Native selection forces Shift without losing existing modifiers")
    func selectionModifiersPreserveExistingBits() {
        let original = ghostty_input_mods_e(
            rawValue: GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_ALT.rawValue
        )
        let routed = GhosttyCapturedMouseSelectionPolicy.selectionModifiers(from: original)

        #expect(routed.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(routed.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0)
        #expect(routed.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
    }

    @Test("⌥⌘ shortcuts reach Pilot's menu instead of the terminal (⌥⌘E toggles Extendo)")
    func optionCommandCombosForwardToMenu() {
        // The regression: a focused terminal swallowed ⌥⌘E because Option combos
        // skipped the menu handoff entirely.
        #expect(GhosttyMenuKeyEquivalentPolicy.forwardsToMainMenu(
            hasCommand: true, hasControl: false, hasOption: true, characters: "e"
        ))
        #expect(GhosttyMenuKeyEquivalentPolicy.forwardsToMainMenu(
            hasCommand: true, hasControl: false, hasOption: true, characters: "d"
        ))
        // Even a plain-⌘ editing key forwards once Option is added — ⌥⌘C is not
        // Ghostty copy, and an unmatched combo still falls through to the terminal.
        #expect(GhosttyMenuKeyEquivalentPolicy.forwardsToMainMenu(
            hasCommand: true, hasControl: false, hasOption: true, characters: "c"
        ))
    }

    @Test("Plain ⌘ global shortcuts forward but editing/focus keys stay with Ghostty")
    func plainCommandRouting() {
        #expect(GhosttyMenuKeyEquivalentPolicy.forwardsToMainMenu(
            hasCommand: true, hasControl: false, hasOption: false, characters: "t"
        ))
        for reserved in ["c", "v", "x", "a", "z", "f", ","] {
            #expect(!GhosttyMenuKeyEquivalentPolicy.forwardsToMainMenu(
                hasCommand: true, hasControl: false, hasOption: false, characters: reserved
            ))
        }
    }

    @Test("Control combos and non-Command keys never leave the terminal")
    func controlAndModifierlessKeysStayLocal() {
        // Ghostty owns C-c, C-d, … — Control must never hand off to the menu.
        #expect(!GhosttyMenuKeyEquivalentPolicy.forwardsToMainMenu(
            hasCommand: true, hasControl: true, hasOption: false, characters: "e"
        ))
        #expect(!GhosttyMenuKeyEquivalentPolicy.forwardsToMainMenu(
            hasCommand: true, hasControl: true, hasOption: true, characters: "e"
        ))
        #expect(!GhosttyMenuKeyEquivalentPolicy.forwardsToMainMenu(
            hasCommand: false, hasControl: false, hasOption: true, characters: "e"
        ))
    }
}
