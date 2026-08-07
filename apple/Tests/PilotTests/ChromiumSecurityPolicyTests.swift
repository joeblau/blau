@preconcurrency import ChromiumKit
import Foundation
import Testing
@testable import Pilot

@Suite("Chromium navigation policy")
struct ChromiumNavigationPolicyTests {
    @Test
    func webNavigationStaysInTheCurrentPane() throws {
        let url = try #require(URL(string: "https://example.com/path"))
        let request = ChromiumNavigationRequest(url: url)

        #expect(ChromiumNavigationPolicy.disposition(for: request) == .allowInCurrentPane)
    }

    @Test
    func trustedPopupsBecomeManagedPilotPanes() throws {
        let url = try #require(URL(string: "https://example.com/popup"))
        let request = ChromiumNavigationRequest(
            url: url,
            target: .popup,
            hasTrustedUserGesture: true
        )

        #expect(ChromiumNavigationPolicy.disposition(for: request) == .openInNewPane(url))
    }

    @Test
    func scriptInitiatedPopupsAreBlocked() throws {
        let url = try #require(URL(string: "https://example.com/popup"))
        let request = ChromiumNavigationRequest(url: url, target: .newWindow)

        #expect(
            ChromiumNavigationPolicy.disposition(for: request)
                == .block(.popupWithoutUserGesture)
        )
    }

    @Test
    func externalSchemesRequireTrustedUserConfirmation() throws {
        let url = try #require(URL(string: "mailto:security@example.com?subject=Report"))
        let untrusted = ChromiumNavigationRequest(url: url)
        let trusted = ChromiumNavigationRequest(url: url, hasTrustedUserGesture: true)

        #expect(
            ChromiumNavigationPolicy.disposition(for: untrusted)
                == .block(.externalSchemeWithoutUserGesture("mailto"))
        )
        #expect(
            ChromiumNavigationPolicy.disposition(for: trusted)
                == .requestUserConfirmedExternalOpen(url)
        )
    }

    @Test
    func localAndPrivilegedSchemesAreBlocked() throws {
        let fileURL = URL(fileURLWithPath: "/Users/alice/.ssh/id_ed25519")
        let chromeURL = try #require(URL(string: "chrome://settings"))
        let javascriptURL = try #require(URL(string: "javascript:alert(1)"))

        #expect(
            ChromiumNavigationPolicy.disposition(
                for: ChromiumNavigationRequest(url: fileURL, hasTrustedUserGesture: true)
            ) == .block(.prohibitedScheme("file"))
        )
        #expect(
            ChromiumNavigationPolicy.disposition(
                for: ChromiumNavigationRequest(url: chromeURL, hasTrustedUserGesture: true)
            ) == .block(.prohibitedScheme("chrome"))
        )
        #expect(
            ChromiumNavigationPolicy.disposition(
                for: ChromiumNavigationRequest(url: javascriptURL, hasTrustedUserGesture: true)
            ) == .block(.prohibitedScheme("javascript"))
        )
    }

    @Test
    func sideLoadedExtensionUINavigatesInTheCurrentPaneOnly() throws {
        let url = try #require(
            URL(string: "chrome-extension://adbojkblhgobhcdckcplhgemldmjldel/index.html")
        )

        #expect(
            ChromiumNavigationPolicy.disposition(for: ChromiumNavigationRequest(url: url))
                == .allowInCurrentPane
        )
        #expect(
            ChromiumNavigationPolicy.disposition(
                for: ChromiumNavigationRequest(
                    url: url,
                    target: .popup,
                    hasTrustedUserGesture: true
                )
            ) == .block(.prohibitedScheme("chrome-extension"))
        )
    }
}

@Suite("Chromium origin permission policy")
struct ChromiumOriginPermissionPolicyTests {
    @Test
    func bridgeMapsEveryCEFPermissionCategoryToPilotPolicy() {
        let cefKinds: ChromiumKit.ChromiumPermissionKind = [
            .audioCapture,
            .videoCapture,
            .geolocation,
            .notifications,
            .clipboard,
            .midiSystemExclusive,
            .fileSystemAccess,
        ]

        #expect(
            ChromiumPermissionBridge.policyKinds(for: cefKinds) == [
                .microphone,
                .camera,
                .geolocation,
                .notifications,
                .clipboardRead,
                .clipboardWrite,
                .midi,
                .fileSystemAccess,
            ]
        )
    }

    @Test
    func bridgeRejectsEmptyAndPartiallyUnknownRequests() {
        let mixed: ChromiumKit.ChromiumPermissionKind = [
            .geolocation,
            .other,
        ]

        #expect(
            ChromiumPermissionBridge.policyKinds(
                for: ChromiumKit.ChromiumPermissionKind()
            ) == nil
        )
        #expect(ChromiumPermissionBridge.policyKinds(for: mixed) == nil)
    }

    @Test
    func missingDecisionsDenyByDefault() throws {
        let url = try #require(URL(string: "https://example.com"))
        let origin = try #require(ChromiumOrigin(url: url))
        let policy = ChromiumOriginPermissionPolicy()

        #expect(policy.decision(for: .camera, origin: origin) == .deny)
        #expect(policy.recordedDecision(for: .camera, origin: origin) == nil)
    }

    @Test
    func grantsAreScopedToExactOriginAndPermission() throws {
        let originURL = try #require(URL(string: "https://example.com"))
        let subdomainURL = try #require(URL(string: "https://sub.example.com"))
        let alternatePortURL = try #require(
            URL(string: "https://example.com:8443")
        )
        let origin = try #require(ChromiumOrigin(url: originURL))
        let subdomain = try #require(ChromiumOrigin(url: subdomainURL))
        let alternatePort = try #require(
            ChromiumOrigin(url: alternatePortURL)
        )
        var policy = ChromiumOriginPermissionPolicy()

        let didRecord = policy.recordUserDecision(
            .allow,
            for: .camera,
            origin: origin
        )
        #expect(didRecord)
        #expect(policy.decision(for: .camera, origin: origin) == .allow)
        #expect(policy.decision(for: .microphone, origin: origin) == .deny)
        #expect(policy.decision(for: .camera, origin: subdomain) == .deny)
        #expect(policy.decision(for: .camera, origin: alternatePort) == .deny)
    }

    @Test
    func defaultPortsCanonicalizeToTheSameOrigin() throws {
        let implicitURL = try #require(URL(string: "https://example.com"))
        let explicitURL = try #require(URL(string: "https://example.com:443"))
        let implicit = try #require(ChromiumOrigin(url: implicitURL))
        let explicit = try #require(ChromiumOrigin(url: explicitURL))

        #expect(implicit == explicit)
        #expect(implicit.serialized == "https://example.com")
    }

    @Test
    func insecureRemoteOriginsCannotBeGranted() throws {
        let url = try #require(URL(string: "http://example.com"))
        let origin = try #require(ChromiumOrigin(url: url))
        var policy = ChromiumOriginPermissionPolicy()

        let didRecord = policy.recordUserDecision(
            .allow,
            for: .geolocation,
            origin: origin
        )
        #expect(!didRecord)
        #expect(policy.decision(for: .geolocation, origin: origin) == .deny)
    }
}

@Suite("Chromium download quarantine")
struct ChromiumDownloadQuarantineTests {
    @Test
    func completedDownloadReceivesPrivacyBoundedQuarantineMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pilot-chromium-quarantine-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("download.txt")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("download".utf8).write(to: fileURL)

        var error: NSError?
        #expect(ChromiumKitApplyDownloadQuarantine(fileURL, &error))
        #expect(error == nil)

        let values = try fileURL.resourceValues(
            forKeys: [.quarantinePropertiesKey]
        )
        let properties = try #require(values.quarantineProperties)
        #expect(!properties.isEmpty)
        let serialized = String(describing: properties)
        #expect(!serialized.contains("secret-token"))
        #expect(!serialized.contains("https://"))
    }

    @Test
    func quarantineRejectsNonFileURLsAndDirectories() throws {
        let remoteURL = try #require(
            URL(string: "https://example.com/file?secret-token=1")
        )
        var remoteError: NSError?
        #expect(
            !ChromiumKitApplyDownloadQuarantine(
                remoteURL,
                &remoteError
            )
        )
        #expect(
            remoteError?.code
                == ChromiumKitError.downloadQuarantineFailed.rawValue
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pilot-chromium-quarantine-directory-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        var directoryError: NSError?
        #expect(
            !ChromiumKitApplyDownloadQuarantine(
                directory,
                &directoryError
            )
        )
        #expect(
            directoryError?.code
                == ChromiumKitError.downloadQuarantineFailed.rawValue
        )
    }
}

@Suite("Chromium user interaction policy")
struct ChromiumUserInteractionPolicyTests {
    @Test
    func downloadRequiresSelectedPaneSafeWebURLAndLeafFilename() throws {
        let safeURL = try #require(
            URL(string: "https://example.com/download")
        )
        #expect(
            ChromiumUserInteractionPolicy.allowsDownload(
                url: safeURL,
                suggestedFilename: " report.txt ",
                isActiveAndSelected: true
            )
        )
        #expect(
            !ChromiumUserInteractionPolicy.allowsDownload(
                url: safeURL,
                suggestedFilename: "report.txt",
                isActiveAndSelected: false
            )
        )

        for filename in [
            "",
            ".",
            "..",
            "../report.txt",
            "nested/report.txt",
            "report\nsecret.txt",
            String(repeating: "a", count: 256),
        ] {
            #expect(
                !ChromiumUserInteractionPolicy.allowsDownload(
                    url: safeURL,
                    suggestedFilename: filename,
                    isActiveAndSelected: true
                )
            )
        }
    }

    @Test
    func downloadAndSaveRejectCredentialsLocalFilesAndMissingHosts() throws {
        let credentialURL = try #require(
            URL(string: "https://alice:secret@example.com/report")
        )
        let missingHost = try #require(URL(string: "https:report"))
        let localFile = URL(fileURLWithPath: "/tmp/report.txt")

        for url in [credentialURL, missingHost, localFile] {
            #expect(
                !ChromiumUserInteractionPolicy.allowsDownload(
                    url: url,
                    suggestedFilename: "report.txt",
                    isActiveAndSelected: true
                )
            )
            #expect(
                !ChromiumUserInteractionPolicy.allowsSavePage(
                    url: url,
                    isActiveAndSelected: true
                )
            )
        }
    }

    @Test
    func nativePanelsAndContextMenuRequireTheSelectedActivePane() {
        #expect(
            ChromiumUserInteractionPolicy.allowsFileChooser(
                isActiveAndSelected: true
            )
        )
        #expect(
            ChromiumUserInteractionPolicy.allowsContextMenu(
                isActiveAndSelected: true
            )
        )
        #expect(
            ChromiumUserInteractionPolicy.allowsPrint(
                isActiveAndSelected: true
            )
        )

        #expect(
            !ChromiumUserInteractionPolicy.allowsFileChooser(
                isActiveAndSelected: false
            )
        )
        #expect(
            !ChromiumUserInteractionPolicy.allowsContextMenu(
                isActiveAndSelected: false
            )
        )
        #expect(
            !ChromiumUserInteractionPolicy.allowsPrint(
                isActiveAndSelected: false
            )
        )
    }
}

@Suite("Chromium DevTools and launch switches")
struct ChromiumLaunchSecurityPolicyTests {
    @Test
    func productionDevToolsAreLocalAndUserInitiatedOnly() {
        let policy = ChromiumDevToolsPolicy.productionDefault

        #expect(policy.allowsManagedLocalInspector)
        #expect(!policy.exposesRemoteDebuggingEndpoint)
        #expect(policy.disposition(for: .trustedUserAction) == .openManagedLocalInspector)
        #expect(policy.disposition(for: .page) == .deny)
        #expect(policy.disposition(for: .startup) == .deny)
        #expect(policy.disposition(for: .automation) == .deny)
    }

    @Test
    func prohibitedSwitchesAreNormalizedAndReported() {
        let arguments = [
            "--no-sandbox",
            "--IGNORE-CERTIFICATE-ERRORS=true",
            "--remote-debugging-address=0.0.0.0",
            "-user-data-dir /tmp/profile",
            "--disable-web-security",
        ]
        let violations = ChromiumSwitchPolicy.violations(in: arguments)

        #expect(violations.count == arguments.count)
        #expect(Set(violations.map(\.name)) == Set([
            "no-sandbox",
            "ignore-certificate-errors",
            "remote-debugging-address",
            "user-data-dir",
            "disable-web-security",
        ]))
        #expect(Set(violations.map(\.reason)) == Set([
            .sandboxBypass,
            .certificateBypass,
            .remoteDebugging,
            .profileEscape,
            .webSecurityBypass,
        ]))
    }

    @Test
    func ordinaryNonSecuritySwitchesDoNotProduceProhibitedViolations() {
        #expect(ChromiumSwitchPolicy.violations(in: [
            "--lang=en-US",
            "--log-severity=warning",
            "--disable-extensions",
        ]).isEmpty)
    }
}
