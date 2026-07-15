import XCTest
@testable import Copilot

final class ActiveConnectionTests: XCTestCase {
    private final class Connection {
        var disconnectCount = 0
    }

    func testRepeatedConnectDisconnectsOldConnectionBeforeReplacement() {
        let first = Connection()
        let second = Connection()
        var active: Connection? = first

        replaceActiveConnection(&active, with: second) { $0.disconnectCount += 1 }

        XCTAssertEqual(first.disconnectCount, 1)
        XCTAssertTrue(active === second)
        XCTAssertEqual(second.disconnectCount, 0)
    }
}
