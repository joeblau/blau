import Foundation
import Testing
@testable import Pilot

@Suite("Chromium profile location policy")
struct ChromiumProfilePolicyTests {
    private let applicationSupport = URL(
        fileURLWithPath: "/Users/alice/Library/Application Support",
        isDirectory: true
    )

    @Test
    func identifiersRejectTraversalAndPathSyntax() {
        #expect(ChromiumProfileIdentifier(rawValue: "") == nil)
        #expect(ChromiumProfileIdentifier(rawValue: ".") == nil)
        #expect(ChromiumProfileIdentifier(rawValue: "..") == nil)
        #expect(ChromiumProfileIdentifier(rawValue: "../Chrome") == nil)
        #expect(ChromiumProfileIdentifier(rawValue: "nested/profile") == nil)
        #expect(ChromiumProfileIdentifier(rawValue: "nested\\profile") == nil)
        #expect(ChromiumProfileIdentifier(rawValue: String(repeating: "a", count: 65)) == nil)
        #expect(ChromiumProfileIdentifier(rawValue: "work_profile-2") != nil)
    }

    @Test
    func profilesStayInsidePilotApplicationSupport() throws {
        let location = ChromiumProfileLocation(applicationSupportDirectory: applicationSupport)
        let work = try #require(ChromiumProfileIdentifier(rawValue: "work"))
        let profileURL = location.directory(for: work)

        #expect(
            profileURL.path
                == "/Users/alice/Library/Application Support/Pilot/Chromium/Profiles/work"
        )
        #expect(location.isManagedProfileDirectory(profileURL))
        #expect(location.ownsData(at: profileURL.appendingPathComponent("Cookies")))
    }

    @Test
    func workspaceAndSystemChromeLocationsAreNeverManaged() {
        let location = ChromiumProfileLocation(applicationSupportDirectory: applicationSupport)
        let workspaceProfile = URL(
            fileURLWithPath: "/Users/alice/Developer/project/.chromium",
            isDirectory: true
        )
        let systemChromeProfile = URL(
            fileURLWithPath: "/Users/alice/Library/Application Support/Google/Chrome/Default",
            isDirectory: true
        )
        let siblingPrefix = URL(
            fileURLWithPath: "/Users/alice/Library/Application Support/Pilot/Chromium/Profiles-Other/default",
            isDirectory: true
        )

        #expect(!location.isManagedProfileDirectory(workspaceProfile))
        #expect(!location.ownsData(at: workspaceProfile))
        #expect(!location.isManagedProfileDirectory(systemChromeProfile))
        #expect(!location.ownsData(at: systemChromeProfile))
        #expect(!location.ownsData(at: siblingPrefix))
    }

    @Test
    func distinctIdentifiersProduceIsolatedDirectories() throws {
        let location = ChromiumProfileLocation(applicationSupportDirectory: applicationSupport)
        let first = try #require(ChromiumProfileIdentifier(rawValue: "first"))
        let second = try #require(ChromiumProfileIdentifier(rawValue: "second"))

        #expect(location.directory(for: first) != location.directory(for: second))
        #expect(location.defaultProfileURL != location.directory(for: first))
    }

    @Test
    func symlinkedProfilesCannotEscapeTheManagedRoot() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let support = temporaryDirectory.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let location = ChromiumProfileLocation(
            applicationSupportDirectory: support
        )
        try FileManager.default.createDirectory(
            at: location.profilesRootURL,
            withIntermediateDirectories: true
        )
        let outside = temporaryDirectory.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: location.defaultProfileURL,
            withDestinationURL: outside
        )

        #expect(!location.isManagedProfileDirectory(location.defaultProfileURL))
        #expect(!location.ownsData(at: location.defaultProfileURL))
    }
}
