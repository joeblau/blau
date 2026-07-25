import Foundation
import Testing
@testable import Pilot

@Suite("Inspector keep-awake session")
struct AwakeSessionTests {
    @Test("Disabled sessions hold no power assertions")
    func disabledSessionHasNoAssertions() {
        let assertions = AwakeSessionPolicy.requiredAssertions(
            isEnabled: false,
            allowDisplaySleep: false,
            allowSystemSleepWhenDisplayClosed: false,
            screenSaverAllowanceActive: false
        )

        #expect(assertions.isEmpty)
    }

    @Test("Default session prevents idle system and display sleep")
    func defaultSessionAssertions() {
        let assertions = AwakeSessionPolicy.requiredAssertions(
            isEnabled: true,
            allowDisplaySleep: false,
            allowSystemSleepWhenDisplayClosed: true,
            screenSaverAllowanceActive: false
        )

        #expect(assertions == [.preventIdleSystemSleep, .preventDisplaySleep])
    }

    @Test("Session options relax and strengthen assertions")
    func sessionOptionAssertions() {
        let relaxed = AwakeSessionPolicy.requiredAssertions(
            isEnabled: true,
            allowDisplaySleep: true,
            allowSystemSleepWhenDisplayClosed: true,
            screenSaverAllowanceActive: false
        )
        let strong = AwakeSessionPolicy.requiredAssertions(
            isEnabled: true,
            allowDisplaySleep: false,
            allowSystemSleepWhenDisplayClosed: false,
            screenSaverAllowanceActive: false
        )
        let screenSaverAllowed = AwakeSessionPolicy.requiredAssertions(
            isEnabled: true,
            allowDisplaySleep: false,
            allowSystemSleepWhenDisplayClosed: true,
            screenSaverAllowanceActive: true
        )

        #expect(relaxed == [.preventIdleSystemSleep])
        #expect(
            strong == [
                .preventIdleSystemSleep,
                .preventDisplaySleep,
                .preventSystemSleep,
            ]
        )
        #expect(screenSaverAllowed == [.preventIdleSystemSleep])
    }

    @Test("Session duration uses a compact stable format")
    func durationFormatting() {
        #expect(AwakeSessionPolicy.formattedDuration(0) == "00m 00s")
        #expect(AwakeSessionPolicy.formattedDuration(9 * 60 + 47) == "09m 47s")
        #expect(AwakeSessionPolicy.formattedDuration(3_661) == "01h 01m 01s")
    }
}
