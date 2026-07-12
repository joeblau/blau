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
}
