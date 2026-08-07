@preconcurrency import ChromiumKit
import Combine
import Foundation
import Testing
@testable import Pilot

@Suite("Chromium browser creation policy")
struct ChromiumBrowserCreationPolicyTests {
    @Test
    @MainActor
    func profileClearPublishesBothBusyTransitions() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let location = ChromiumProfileLocation(
            applicationSupportDirectory: temporaryRoot
        )
        let profileURL = location.defaultProfileURL
        try FileManager.default.createDirectory(
            at: profileURL,
            withIntermediateDirectories: true
        )
        let gate = ChromiumProfileClearTestGate()
        let coordinator = ChromiumProfileAccessCoordinator { _, _ in
            await gate.wait()
        }
        let transitions = ChromiumBooleanTransitionRecorder()
        let observation = coordinator.$isClearing.sink { value in
            MainActor.assumeIsolated {
                transitions.values.append(value)
            }
        }
        defer {
            observation.cancel()
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        #expect(transitions.values == [false])
        let clearTask = Task {
            try await coordinator.clearProfile(
                at: profileURL,
                location: location
            )
        }
        var didReachClearOperation = false
        for _ in 0..<100 {
            if await gate.hasBlocked() {
                didReachClearOperation = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard didReachClearOperation else {
            await gate.open()
            _ = await clearTask.result
            Issue.record("Profile clear did not reach the injected operation.")
            return
        }
        #expect(transitions.values == [false, true])
        #expect(coordinator.isClearing)

        await gate.open()
        try await clearTask.value

        #expect(transitions.values == [false, true, false])
        #expect(!coordinator.isClearing)
    }

    @Test
    func webKitRemainsAvailableWhenChromiumFailsClosed() {
        #expect(BrowserPaneCreationPolicy.permitsCreation(
            for: .webKit,
            chromiumCreationEnabled: false
        ))
        #expect(!BrowserPaneCreationPolicy.permitsCreation(
            for: .chromium,
            chromiumCreationEnabled: false
        ))
        #expect(BrowserPaneCreationPolicy.permitsCreation(
            for: .chromium,
            chromiumCreationEnabled: true
        ))
    }

    @Test
    @MainActor
    func bridgeAvailabilityMatchesThePilotBuildConfiguration() {
        #if BLAU_CHROMIUM_CEF_ENABLED
        #expect(ChromiumEngine.shared.isRuntimeAvailable)
        #else
        #expect(!ChromiumEngine.shared.isRuntimeAvailable)
        #endif
    }

    @Test
    func permitsOnlyAnEmbeddedStartableRuntime() {
        #expect(ChromiumBrowserCreationPolicy.permitsCreation(
            runtimeAvailable: true,
            engineCanStartOrIsRunning: true,
            initializationFailed: false,
            profileClearInProgress: false
        ))
        #expect(!ChromiumBrowserCreationPolicy.permitsCreation(
            runtimeAvailable: false,
            engineCanStartOrIsRunning: true,
            initializationFailed: false,
            profileClearInProgress: false
        ))
        #expect(!ChromiumBrowserCreationPolicy.permitsCreation(
            runtimeAvailable: true,
            engineCanStartOrIsRunning: false,
            initializationFailed: false,
            profileClearInProgress: false
        ))
    }

    @Test
    func failsClosedDuringInitializationFailureOrProfileClear() {
        #expect(!ChromiumBrowserCreationPolicy.permitsCreation(
            runtimeAvailable: true,
            engineCanStartOrIsRunning: true,
            initializationFailed: true,
            profileClearInProgress: false
        ))
        #expect(!ChromiumBrowserCreationPolicy.permitsCreation(
            runtimeAvailable: true,
            engineCanStartOrIsRunning: true,
            initializationFailed: false,
            profileClearInProgress: true
        ))
    }

    /// A disabled Chromium row has three different causes and only one of them
    /// is worth opening diagnostics for, so the launcher reports them apart.
    @Test
    @MainActor
    func explainsWhyCreationIsUnavailable() {
#if BLAU_CHROMIUM_CEF_ENABLED
        // The real bridge is linked, so "not in this build" cannot be the reason.
        #expect(ChromiumBrowserCreationPolicy.unavailableReason != .notInThisBuild)
#else
        // Clean Debug and Release builds compile the stub bridge: nothing is
        // broken, the runtime simply isn't linked.
        #expect(ChromiumBrowserCreationPolicy.unavailableReason == .notInThisBuild)
        #expect(!ChromiumBrowserCreationPolicy.isCreationEnabled)
#endif
    }

    @Test
    func eachUnavailableReasonNamesItsOwnFix() {
        // The build-configuration case is the common one and must not send the
        // reader to a diagnostics panel that would only report "Unavailable".
        #expect(ChromiumUnavailableReason.notInThisBuild.message
            .contains("Chromium configuration"))
        #expect(!ChromiumUnavailableReason.notInThisBuild.message.contains("diagnostics"))
        #expect(ChromiumUnavailableReason.clearingBrowsingData.message
            .contains("clearing"))
        #expect(ChromiumUnavailableReason.engineUnavailable.message
            .contains("diagnostics"))
    }
}

private actor ChromiumProfileClearTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isBlocked = false
    private var isOpen = false

    func wait() async {
        isBlocked = true
        guard !isOpen else { return }
        await withCheckedContinuation {
            continuation = $0
        }
    }

    func hasBlocked() -> Bool {
        isBlocked
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class ChromiumBooleanTransitionRecorder {
    var values: [Bool] = []
}

@Suite("Chromium diagnostic redaction")
struct ChromiumDiagnosticsTests {
    @Test
    func diagnosticsRetainOnlyOriginAndRedactionMetadata() throws {
        let url = try #require(URL(
            string: "https://alice:secret@example.com:8443/private/account?token=abc#details"
        ))
        let record = ChromiumDiagnosticRecord.make(
            event: .navigationFailed,
            errorCode: -105,
            url: url,
            headers: [
                "Authorization": "Bearer private-token",
                "Cookie": "session=private-cookie",
            ],
            localPath: "/Users/alice/Developer/private/index.html",
            pageContent: "<html>private page content</html>"
        )
        let rendered = record.description

        #expect(record.origin == "https://example.com:8443")
        #expect(record.errorCode == -105)
        #expect(record.redactedHeaderCount == 2)
        #expect(Set(record.redactions) == Set([
            .credentials,
            .headers,
            .localPath,
            .pageContent,
            .urlFragment,
            .urlPath,
            .urlQuery,
        ]))
        #expect(!rendered.contains("alice"))
        #expect(!rendered.contains("secret"))
        #expect(!rendered.contains("private/account"))
        #expect(!rendered.contains("token=abc"))
        #expect(!rendered.contains("Bearer"))
        #expect(!rendered.contains("private-cookie"))
        #expect(!rendered.contains("/Users/alice"))
        #expect(!rendered.contains("<html>"))
    }

    @Test
    func diagnosticMetadataIsBoundedWithoutCopyingPageContent() {
        let headers = Dictionary(uniqueKeysWithValues: (0..<100).map {
            ("Header-\($0)", "secret-\($0)")
        })
        let content = String(repeating: "x", count: 5_000)
        let record = ChromiumDiagnosticRecord.make(
            event: .rendererTerminated,
            headers: headers,
            pageContent: content
        )

        #expect(
            record.redactedHeaderCount
                == ChromiumDiagnosticRecord.maximumReportedHeaderCount
        )
        #expect(
            record.redactedPageContentByteCount
                == ChromiumDiagnosticRecord.maximumReportedPageContentBytes
        )
        #expect(record.pageContentWasTruncated)
        #expect(!record.description.contains(content))
    }

    @Test
    func fileURLsAndLocalPathsNeverBecomeDiagnosticOrigins() {
        let path = "/Users/alice/.ssh/id_ed25519"
        let record = ChromiumDiagnosticRecord.make(
            event: .launchRejected,
            url: URL(fileURLWithPath: path),
            localPath: path
        )

        #expect(record.origin == nil)
        #expect(record.redactions.contains(.urlPath))
        #expect(record.redactions.contains(.localPath))
        #expect(!record.description.contains(path))
    }

    @Test
    func defaultNetworkPortsAreRemovedFromSafeOrigins() throws {
        let url = try #require(URL(string: "https://example.com:443/path"))
        let record = ChromiumDiagnosticRecord.make(event: .popupBlocked, url: url)

        #expect(record.origin == "https://example.com")
        #expect(record.redactions.contains(.urlPath))
    }
}
