import Foundation
import Testing
@testable import Pilot

@Suite("Built privacy manifest")
struct PrivacyManifestTests {
    @Test("Pilot declares camera access before opening a device pane")
    func cameraUsageDescriptionIsPresent() {
        let description = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
        #expect(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
}
