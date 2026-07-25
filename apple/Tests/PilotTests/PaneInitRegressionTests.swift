import AppKit
import Testing
@testable import Pilot

@Suite("Pane init per-kind state (R1-R5 regressions)")
struct PaneInitRegressionTests {

    // R1: Device init has no persistent per-kind state; runtime state is owned by the view.
    @Test
    func deviceKindInitHasNoPerKindState() {
        let pane = Pane(kind: .device)
        #expect(pane.kind == .device)
        #expect(pane.browserState == nil)
    }

    // R2: Existing — .browser init still creates a BrowserState
    @Test
    func browserKindInitCreatesBrowserState() {
        let pane = Pane(kind: .browser)
        #expect(pane.kind == .browser)
        #expect(pane.browserState != nil)
    }

    // R3: Existing — .terminal init still has no per-kind state
    @Test
    func terminalKindInitHasNoPerKindState() {
        let pane = Pane(kind: .terminal)
        #expect(pane.kind == .terminal)
        #expect(pane.browserState == nil)
    }

    // R4: Pane default kind is still .terminal
    @Test
    func defaultKindIsTerminal() {
        let pane = Pane()
        #expect(pane.kind == .terminal)
    }

    // R7: Android init has no persistent per-kind state; runtime state is
    // owned by AndroidDeviceRegistry.
    @Test
    func androidKindInitHasNoPerKindState() {
        let pane = Pane(kind: .android)
        #expect(pane.kind == .android)
        #expect(pane.browserState == nil)
    }

    // R5: PaneKind cases remain stable. Adding a new kind requires updating this
    // list and adding an initialization-invariant test above.
    @Test
    func paneKindCaseCount() {
        #expect(PaneKind.allCases.count == 6)
        #expect(Set(PaneKind.allCases) == Set([.terminal, .browser, .device, .simulator, .android, .editor]))
    }

    // R6: PaneKind raw values are stable (SwiftData persistence compat)
    @Test
    func paneKindRawValuesAreStable() {
        #expect(PaneKind.terminal.rawValue == "terminal")
        #expect(PaneKind.browser.rawValue == "browser")
        #expect(PaneKind.device.rawValue == "device")
        #expect(PaneKind.simulator.rawValue == "simulator")
        #expect(PaneKind.android.rawValue == "android")
        #expect(PaneKind.editor.rawValue == "editor")
    }

    @Test("Wrapped editors remove horizontal displacement and preserve vertical scroll")
    func wrappedEditorNormalizesScrollPosition() {
        let normalized = EditorViewportPolicy.normalizedWrappedScrollPosition(
            CGPoint(x: 84, y: 512)
        )

        #expect(normalized == CGPoint(x: 0, y: 512))
        #expect(EditorViewportPolicy.normalizedWrappedScrollPosition(nil) == nil)
    }

    @Test("Find panel visibility keeps editor text outside the overlay")
    func findPanelVisibilityAdjustsEditorViewport() {
        let startingPosition = CGPoint(x: 0, y: 320)
        let opened = EditorViewportPolicy.adjustedScrollPosition(
            startingPosition,
            findPanelWasVisible: false,
            findPanelIsVisible: true
        )
        let closed = EditorViewportPolicy.adjustedScrollPosition(
            opened,
            findPanelWasVisible: true,
            findPanelIsVisible: false
        )

        #expect(opened == CGPoint(x: 0, y: 292))
        #expect(closed == startingPosition)
        #expect(
            EditorViewportPolicy.adjustedScrollPosition(
                startingPosition,
                findPanelWasVisible: true,
                findPanelIsVisible: true
            ) == startingPosition
        )
        #expect(
            EditorViewportPolicy.adjustedScrollPosition(
                nil,
                findPanelWasVisible: false,
                findPanelIsVisible: true
            ) == CGPoint(x: 0, y: -28)
        )
    }

    @MainActor
    @Test("Editor find panel receives clicks above the text surface")
    func findPanelIsPromotedForHitTesting() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let findPanel = NSView(frame: container.bounds)
        let textSurface = NSView(frame: container.bounds)
        container.addSubview(findPanel)
        container.addSubview(textSurface)

        #expect(container.hitTest(NSPoint(x: 20, y: 20)) === textSurface)

        let repairCount = EditorFindPanelHitTestingPolicy.bringFindPanelsToFront(
            in: container,
            matching: { $0 === findPanel }
        )

        #expect(repairCount == 1)
        #expect(container.hitTest(NSPoint(x: 20, y: 20)) === findPanel)
    }
}
