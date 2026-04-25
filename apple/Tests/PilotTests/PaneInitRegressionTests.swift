import Testing
@testable import Pilot

@Suite("Pane init per-kind state (R1-R5 regressions)")
struct PaneInitRegressionTests {

    // R1: New — .simulator init creates a SimulatorState
    @Test
    func simulatorKindInitCreatesSimulatorState() {
        let pane = Pane(kind: .simulator)
        #expect(pane.kind == .simulator)
        #expect(pane.simulatorState != nil)
        #expect(pane.browserState == nil)
    }

    // R2: Existing — .browser init still creates a BrowserState
    @Test
    func browserKindInitCreatesBrowserState() {
        let pane = Pane(kind: .browser)
        #expect(pane.kind == .browser)
        #expect(pane.browserState != nil)
        #expect(pane.simulatorState == nil)
    }

    // R3: Existing — .terminal init still has no per-kind state
    @Test
    func terminalKindInitHasNoPerKindState() {
        let pane = Pane(kind: .terminal)
        #expect(pane.kind == .terminal)
        #expect(pane.browserState == nil)
        #expect(pane.simulatorState == nil)
    }

    // R4: Pane default kind is still .terminal
    @Test
    func defaultKindIsTerminal() {
        let pane = Pane()
        #expect(pane.kind == .terminal)
    }

    // R5: PaneKind cases remain stable (schema stability)
    @Test
    func paneKindCaseCount() {
        #expect(PaneKind.allCases.count == 3)
        #expect(Set(PaneKind.allCases) == Set([.terminal, .browser, .simulator]))
    }

    // R6: PaneKind raw values are stable (SwiftData persistence compat)
    @Test
    func paneKindRawValuesAreStable() {
        #expect(PaneKind.terminal.rawValue == "terminal")
        #expect(PaneKind.browser.rawValue == "browser")
        #expect(PaneKind.simulator.rawValue == "simulator")
    }
}
