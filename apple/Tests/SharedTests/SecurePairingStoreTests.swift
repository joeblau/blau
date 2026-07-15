import Foundation
import XCTest
@testable import Copilot

final class SecurePairingStoreTests: XCTestCase {
    private final class MemoryStorage: PairingSecretStoring {
        var values: [String: Data] = [:]

        func read(account: String) throws -> Data? { values[account] }
        func write(_ data: Data, account: String) throws { values[account] = data }
        func delete(account: String) throws { values.removeValue(forKey: account) }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SecurePairingStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMigratesLegacyDefaultsToSecureStorageAndDeletesPlaintext() throws {
        let storage = MemoryStorage()
        let token = try SecurePairingStore.generateToken()
        let peer = Data((0..<32).map(UInt8.init)).base64EncodedString()
        defaults.set(token, forKey: SecurePairingStore.legacyTokenKey)
        defaults.set(peer, forKey: SecurePairingStore.legacyPeerKey)

        let secrets = try SecurePairingStore(
            storage: storage,
            defaults: defaults
        ).loadMigratingLegacy()

        XCTAssertEqual(secrets, PairingSecrets(token: token, peerPublicKey: peer))
        XCTAssertNil(defaults.object(forKey: SecurePairingStore.legacyTokenKey))
        XCTAssertNil(defaults.object(forKey: SecurePairingStore.legacyPeerKey))
        XCTAssertEqual(
            storage.values[SecurePairingStore.tokenAccount],
            Data(token.utf8)
        )
        XCTAssertEqual(
            storage.values[SecurePairingStore.peerAccount],
            Data(peer.utf8)
        )
    }

    func testSecureValuesWinOverStaleLegacyDefaults() throws {
        let storage = MemoryStorage()
        storage.values[SecurePairingStore.tokenAccount] = Data("secure-token".utf8)
        storage.values[SecurePairingStore.peerAccount] = Data("secure-peer".utf8)
        defaults.set("legacy-token", forKey: SecurePairingStore.legacyTokenKey)
        defaults.set("legacy-peer", forKey: SecurePairingStore.legacyPeerKey)

        let secrets = try SecurePairingStore(
            storage: storage,
            defaults: defaults
        ).loadMigratingLegacy()

        XCTAssertEqual(secrets.token, "secure-token")
        XCTAssertEqual(secrets.peerPublicKey, "secure-peer")
        XCTAssertNil(defaults.object(forKey: SecurePairingStore.legacyTokenKey))
        XCTAssertNil(defaults.object(forKey: SecurePairingStore.legacyPeerKey))
    }

    func testGeneratedTokensMeetWorkerValidation() throws {
        let first = try SecurePairingStore.generateToken()
        let second = try SecurePairingStore.generateToken()
        XCTAssertTrue(SecurePairingStore.isValidIdentifier(first))
        XCTAssertTrue(SecurePairingStore.isValidIdentifier(second))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(SecurePairingStore.isValidIdentifier(String(repeating: "a", count: 43)))
        XCTAssertFalse(SecurePairingStore.isValidIdentifier("ABCDEFGHé234567890123456789012345678"))
    }
}
