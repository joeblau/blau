import Foundation
import Testing
@testable import Pilot

@Suite("Remote desktop credential policy")
struct RemoteDesktopCredentialPolicyTests {
    @Test("A password is only persisted once the server accepts it")
    func savesOnlyAfterSuccess() {
        #expect(
            RemoteDesktopCredentialPolicy.onConnected(savePassword: true, password: "hunter2") == .save
        )
    }

    @Test("Opting out of saving clears any previously stored password")
    func optingOutDeletes() {
        #expect(
            RemoteDesktopCredentialPolicy.onConnected(savePassword: false, password: "hunter2") == .delete
        )
    }

    @Test("An empty password is never stored")
    func emptyPasswordIsNeverStored() {
        #expect(
            RemoteDesktopCredentialPolicy.onConnected(savePassword: true, password: "") == .delete
        )
    }

    /// The regression this policy exists for: a rejected password used to stay
    /// in the Keychain, so auto-connect replayed it on every tab-in and failed
    /// identically forever.
    @Test("A rejected password is dropped so auto-connect stops replaying it")
    func authenticationFailureDeletes() {
        #expect(RemoteDesktopCredentialPolicy.onFailure(isAuthenticationFailure: true) == .delete)
    }

    /// The other half: a dropped link must not discard a password that was
    /// working seconds earlier.
    @Test("A non-authentication failure leaves a working password alone")
    func networkFailureKeepsPassword() {
        #expect(RemoteDesktopCredentialPolicy.onFailure(isAuthenticationFailure: false) == .leaveAlone)
    }
}

@Suite("Remote desktop session manager")
@MainActor
struct RemoteDesktopSessionManagerTests {
    /// The property that makes tab switching free: the same connection id hands
    /// back the same session, so its `VNCConnection` is never rebuilt.
    @Test("The same connection keeps the same session across lookups")
    func sessionIsReusedPerConnection() {
        let manager = RemoteDesktopSessionManager()
        let id = UUID()
        #expect(manager.session(for: id) === manager.session(for: id))
    }

    @Test("Different connections get different sessions")
    func sessionsAreKeyedByConnection() {
        let manager = RemoteDesktopSessionManager()
        #expect(manager.session(for: UUID()) !== manager.session(for: UUID()))
    }

    @Test("A new session starts idle and is not live")
    func newSessionIsIdle() {
        let manager = RemoteDesktopSessionManager()
        let session = manager.session(for: UUID())
        #expect(session.status == .idle)
        #expect(!session.isLive)
        #expect(manager.liveSessionCount == 0)
    }

    @Test("Ending a session forgets it")
    func endingASessionForgetsIt() {
        let manager = RemoteDesktopSessionManager()
        let id = UUID()
        let original = manager.session(for: id)
        manager.endSession(for: id)
        #expect(manager.existingSession(for: id) == nil)
        #expect(manager.session(for: id) !== original)
    }

    @Test("Only the inactive tabs start ageing out")
    func activeTabIsNotBackgrounded() {
        let manager = RemoteDesktopSessionManager()
        let active = UUID()
        let other = UUID()
        _ = manager.session(for: active)
        _ = manager.session(for: other)

        manager.setActive(active)
        #expect(manager.existingSession(for: active)?.backgroundedAt == nil)
        #expect(manager.existingSession(for: other)?.backgroundedAt != nil)

        // Tabbing over flips which one is ageing.
        manager.setActive(other)
        #expect(manager.existingSession(for: other)?.backgroundedAt == nil)
        #expect(manager.existingSession(for: active)?.backgroundedAt != nil)
    }

    @Test("Backgrounding stamps once, not on every selection change")
    func backgroundTimestampIsNotRefreshed() {
        let manager = RemoteDesktopSessionManager()
        let active = UUID()
        let other = UUID()
        _ = manager.session(for: active)
        _ = manager.session(for: other)

        manager.setActive(active)
        let firstStamp = manager.existingSession(for: other)?.backgroundedAt
        manager.setActive(active)
        #expect(manager.existingSession(for: other)?.backgroundedAt == firstStamp)
    }

    /// Reaping drops the socket, never the tab: the session object has to
    /// survive so the connection still has somewhere to reconnect into.
    @Test("Reaping keeps the session object so the tab survives")
    func reapingKeepsTheSession() {
        let manager = RemoteDesktopSessionManager()
        let id = UUID()
        let session = manager.session(for: id)
        manager.setActive(nil)

        manager.reapIdleSessions(now: Date().addingTimeInterval(3600), gracePeriod: 60)

        #expect(manager.existingSession(for: id) === session)
        #expect(session.status == .idle)
    }
}
