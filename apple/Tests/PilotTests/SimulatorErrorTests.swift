import Testing
@testable import Pilot

@Suite("SimulatorError localized strings")
struct SimulatorErrorTests {

    @Test
    func xcodeNotFoundMentionsXcodeSelect() {
        let msg = SimulatorError.xcodeNotFound.errorDescription ?? ""
        #expect(msg.contains("Xcode"))
        #expect(msg.contains("xcode-select"))
    }

    @Test
    func spiUnavailableIncludesSymbol() {
        let msg = SimulatorError.spiUnavailable(symbol: "SimDevice").errorDescription ?? ""
        #expect(msg.contains("SimDevice"))
    }

    @Test
    func runtimeNotInstalledIncludesIdentifier() {
        let msg = SimulatorError.runtimeNotInstalled(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-3").errorDescription ?? ""
        #expect(msg.contains("iOS-18-3"))
    }

    @Test
    func bootTimeoutMentionsSeconds() {
        let msg = SimulatorError.bootTimeout(seconds: 60).errorDescription ?? ""
        #expect(msg.contains("60"))
    }

    @Test
    func allCasesProduceNonEmptyDescription() {
        let cases: [SimulatorError] = [
            .xcodeNotFound,
            .spiUnavailable(symbol: "X"),
            .deviceSetInitFailed(underlying: "err"),
            .runtimeNotInstalled(identifier: "id"),
            .deviceTypeNotAvailable(identifier: "id"),
            .deviceCreateFailed(underlying: "err"),
            .bootFailed(underlying: "err"),
            .bootTimeout(seconds: 60),
            .shutdownFailed(underlying: "err"),
            .framebufferSubscribeFailed(underlying: "err"),
            .framebufferDisconnected,
            .inputSendFailed(underlying: "err"),
            .xpcDisconnected,
            .logStreamEnded,
        ]
        for c in cases {
            let desc = c.errorDescription ?? ""
            #expect(!desc.isEmpty, "Description empty for \(c)")
        }
    }
}
