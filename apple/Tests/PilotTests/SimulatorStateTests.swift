import Testing
@testable import Pilot

@Suite("SimulatorState model")
struct SimulatorStateTests {

    @Test
    func emptyInitNeedsProvisioning() {
        let state = SimulatorState()
        #expect(state.needsProvisioning)
        #expect(state.deviceUDID.isEmpty)
    }

    @Test
    func provisionedInitDoesNotNeedProvisioning() {
        let state = SimulatorState(
            deviceUDID: "ABC-123",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-15",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-3",
            displayName: "iPhone 15"
        )
        #expect(!state.needsProvisioning)
        #expect(state.displayName == "iPhone 15")
    }

    @Test
    func transientStatusStartsDisconnected() {
        let state = SimulatorState()
        #expect(state.connectionStatus == .disconnected)
        #expect(state.bootProgress == .idle)
        #expect(state.lastError == nil)
    }
}

@Suite("HIDEventPayload translation")
struct SimulatorInputBridgeTests {

    @Test
    func hardwareButtonEmitsMatchingPayload() {
        let bridge = SimulatorInputBridge()
        let payload = bridge.hardwareButton(.home)
        if case .hardwareButton(let button) = payload.kind {
            #expect(button == .home)
        } else {
            Issue.record("Expected .hardwareButton payload")
        }
    }
}
