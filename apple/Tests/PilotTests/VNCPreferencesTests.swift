import Foundation
import Testing
@testable import Pilot

@Suite("VNC privacy defaults")
struct VNCPreferencesTests {
    @Test("Clipboard redirection is disabled until explicitly enabled")
    func clipboardDefaultsOff() throws {
        let suiteName = "VNCPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = UUID()

        #expect(!VNCPreferences.isClipboardRedirectionEnabled(id: id, defaults: defaults))
        VNCPreferences.setClipboardRedirectionEnabled(true, id: id, defaults: defaults)
        #expect(VNCPreferences.isClipboardRedirectionEnabled(id: id, defaults: defaults))
        VNCPreferences.remove(id: id, defaults: defaults)
        #expect(!VNCPreferences.isClipboardRedirectionEnabled(id: id, defaults: defaults))
    }
}
