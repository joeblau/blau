@preconcurrency import ChromiumKit
import Foundation

enum ChromiumNavigationTarget: Hashable, Sendable {
    case currentPane
    case newPane
    case popup
    case newWindow
}

struct ChromiumNavigationRequest: Equatable, Sendable {
    let url: URL
    let target: ChromiumNavigationTarget
    let hasTrustedUserGesture: Bool

    init(
        url: URL,
        target: ChromiumNavigationTarget = .currentPane,
        hasTrustedUserGesture: Bool = false
    ) {
        self.url = url
        self.target = target
        self.hasTrustedUserGesture = hasTrustedUserGesture
    }
}

enum ChromiumNavigationBlockReason: Equatable, Sendable {
    case malformedURL
    case popupWithoutUserGesture
    case externalSchemeWithoutUserGesture(String)
    case prohibitedScheme(String)
}

/// No result permits CEF to create an unmanaged native window.
enum ChromiumNavigationDisposition: Equatable, Sendable {
    case allowInCurrentPane
    case openInNewPane(URL)
    case requestUserConfirmedExternalOpen(URL)
    case block(ChromiumNavigationBlockReason)
}

enum ChromiumNavigationPolicy {
    private static let externalSchemes: Set<String> = [
        "facetime",
        "facetime-audio",
        "mailto",
        "sms",
        "tel",
    ]

    static func disposition(for request: ChromiumNavigationRequest) -> ChromiumNavigationDisposition {
        guard let rawScheme = request.url.scheme, !rawScheme.isEmpty else {
            return .block(.malformedURL)
        }
        let scheme = rawScheme.lowercased()
        let opensNewSurface = request.target != .currentPane

        if opensNewSurface, !request.hasTrustedUserGesture {
            return .block(.popupWithoutUserGesture)
        }

        switch scheme {
        case "http", "https":
            guard request.url.host?.isEmpty == false else {
                return .block(.malformedURL)
            }
            return opensNewSurface
                ? .openInNewPane(request.url)
                : .allowInCurrentPane
        case "about":
            guard request.url.absoluteString.lowercased() == "about:blank" else {
                return .block(.prohibitedScheme(scheme))
            }
            return opensNewSurface
                ? .openInNewPane(request.url)
                : .allowInCurrentPane
        case "chrome-extension":
            // SPIKE(rabby-extension): side-loaded wallet UIs navigate like
            // ordinary pages in the current pane. Extension-initiated new
            // surfaces (notification windows, welcome tabs) stay blocked.
            return opensNewSurface
                ? .block(.prohibitedScheme(scheme))
                : .allowInCurrentPane
        default:
            guard externalSchemes.contains(scheme) else {
                return .block(.prohibitedScheme(scheme))
            }
            guard request.hasTrustedUserGesture else {
                return .block(.externalSchemeWithoutUserGesture(scheme))
            }
            return .requestUserConfirmedExternalOpen(request.url)
        }
    }
}

struct ChromiumOrigin: Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int?

    init?(url: URL) {
        guard let rawScheme = url.scheme?.lowercased(),
              rawScheme == "http" || rawScheme == "https",
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty else {
            return nil
        }
        scheme = rawScheme
        host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch (scheme, url.port) {
        case ("http", 80), ("https", 443):
            port = nil
        default:
            port = url.port
        }
    }

    var serialized: String {
        let displayedHost = host.contains(":") ? "[\(host)]" : host
        if let port {
            return "\(scheme)://\(displayedHost):\(port)"
        }
        return "\(scheme)://\(displayedHost)"
    }

    var isPotentiallyTrustworthy: Bool {
        scheme == "https" || (scheme == "http" && isLoopbackHost)
    }

    private var isLoopbackHost: Bool {
        host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "::1"
            || host.hasPrefix("127.")
    }
}

enum ChromiumPermissionKind: String, CaseIterable, Hashable, Sendable {
    case camera
    case microphone
    case geolocation
    case notifications
    case clipboardRead
    case clipboardWrite
    case midi
    case usb
    case serial
    case bluetooth
    case fileSystemAccess
}

enum ChromiumPermissionBridge {
    static func policyKinds(
        for kinds: ChromiumKit.ChromiumPermissionKind
    ) -> [ChromiumPermissionKind]? {
        guard !kinds.contains(.other) else { return nil }

        var permissions: [ChromiumPermissionKind] = []
        if kinds.contains(.audioCapture) {
            permissions.append(.microphone)
        }
        if kinds.contains(.videoCapture) {
            permissions.append(.camera)
        }
        if kinds.contains(.geolocation) {
            permissions.append(.geolocation)
        }
        if kinds.contains(.notifications) {
            permissions.append(.notifications)
        }
        if kinds.contains(.clipboard) {
            permissions.append(contentsOf: [
                .clipboardRead,
                .clipboardWrite,
            ])
        }
        if kinds.contains(.midiSystemExclusive) {
            permissions.append(.midi)
        }
        if kinds.contains(.fileSystemAccess) {
            permissions.append(.fileSystemAccess)
        }
        return permissions.isEmpty ? nil : permissions
    }
}

enum ChromiumPermissionDecision: Hashable, Sendable {
    case allow
    case deny
}

enum ChromiumUserInteractionPolicy {
    static func allowsDownload(
        url: URL,
        suggestedFilename: String,
        isActiveAndSelected: Bool
    ) -> Bool {
        guard isActiveAndSelected,
              isCredentialFreeWebURL(url) else {
            return false
        }
        let filename = suggestedFilename.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return !filename.isEmpty
            && filename != "."
            && filename != ".."
            && filename.utf8.count <= 255
            && filename.rangeOfCharacter(
                from: .controlCharacters
            ) == nil
            && (filename as NSString).lastPathComponent == filename
    }

    static func allowsFileChooser(
        isActiveAndSelected: Bool
    ) -> Bool {
        isActiveAndSelected
    }

    static func allowsContextMenu(
        isActiveAndSelected: Bool
    ) -> Bool {
        isActiveAndSelected
    }

    static func allowsPrint(
        isActiveAndSelected: Bool
    ) -> Bool {
        isActiveAndSelected
    }

    static func allowsSavePage(
        url: URL,
        isActiveAndSelected: Bool
    ) -> Bool {
        isActiveAndSelected && isCredentialFreeWebURL(url)
    }

    private static func isCredentialFreeWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return false
        }
        return url.user == nil && url.password == nil
    }
}

/// Decisions are scoped to the exact canonical origin and permission. Missing
/// entries, invalid origins, and insecure non-loopback origins resolve to deny.
struct ChromiumOriginPermissionPolicy: Sendable {
    private struct Key: Hashable, Sendable {
        let origin: ChromiumOrigin
        let permission: ChromiumPermissionKind
    }

    private var decisions: [Key: ChromiumPermissionDecision] = [:]

    init() {}

    func decision(
        for permission: ChromiumPermissionKind,
        origin: ChromiumOrigin
    ) -> ChromiumPermissionDecision {
        decisions[Key(origin: origin, permission: permission)] ?? .deny
    }

    func decision(
        for permission: ChromiumPermissionKind,
        originURL: URL
    ) -> ChromiumPermissionDecision {
        guard let origin = ChromiumOrigin(url: originURL) else { return .deny }
        return decision(for: permission, origin: origin)
    }

    func recordedDecision(
        for permission: ChromiumPermissionKind,
        origin: ChromiumOrigin
    ) -> ChromiumPermissionDecision? {
        decisions[Key(origin: origin, permission: permission)]
    }

    @discardableResult
    mutating func recordUserDecision(
        _ decision: ChromiumPermissionDecision,
        for permission: ChromiumPermissionKind,
        origin: ChromiumOrigin
    ) -> Bool {
        let key = Key(origin: origin, permission: permission)
        guard decision == .deny || origin.isPotentiallyTrustworthy else {
            decisions[key] = .deny
            return false
        }
        decisions[key] = decision
        return true
    }

    mutating func removeDecisions(for origin: ChromiumOrigin) {
        let keys = decisions.keys.filter { $0.origin == origin }
        for key in keys {
            decisions.removeValue(forKey: key)
        }
    }

    mutating func removeAllDecisions() {
        decisions.removeAll()
    }
}

enum ChromiumDevToolsRequestSource: Hashable, Sendable {
    case trustedUserAction
    case page
    case startup
    case automation
}

enum ChromiumDevToolsDisposition: Hashable, Sendable {
    case openManagedLocalInspector
    case deny
}

struct ChromiumDevToolsPolicy: Equatable, Sendable {
    static let productionDefault = ChromiumDevToolsPolicy()

    let allowsManagedLocalInspector: Bool
    let exposesRemoteDebuggingEndpoint: Bool

    init() {
        allowsManagedLocalInspector = true
        exposesRemoteDebuggingEndpoint = false
    }

    func disposition(for source: ChromiumDevToolsRequestSource) -> ChromiumDevToolsDisposition {
        guard allowsManagedLocalInspector, source == .trustedUserAction else {
            return .deny
        }
        return .openManagedLocalInspector
    }
}

struct ChromiumSwitchViolation: Equatable, Sendable {
    enum Reason: String, Hashable, Sendable {
        case sandboxBypass
        case certificateBypass
        case remoteDebugging
        case profileEscape
        case webSecurityBypass
    }

    let argumentIndex: Int
    let name: String
    let reason: Reason
}

enum ChromiumSwitchValidationError: Error, Equatable {
    case prohibited([ChromiumSwitchViolation])
}

enum ChromiumSwitchPolicy {
    private static let prohibited: [String: ChromiumSwitchViolation.Reason] = [
        "allow-insecure-localhost": .certificateBypass,
        "allow-running-insecure-content": .webSecurityBypass,
        "disable-gpu-sandbox": .sandboxBypass,
        "disable-namespace-sandbox": .sandboxBypass,
        "disable-sandbox": .sandboxBypass,
        "disable-seccomp-filter-sandbox": .sandboxBypass,
        "disable-setuid-sandbox": .sandboxBypass,
        "disable-site-isolation-trials": .webSecurityBypass,
        "disable-web-security": .webSecurityBypass,
        "disk-cache-dir": .profileEscape,
        "ignore-certificate-errors": .certificateBypass,
        "ignore-certificate-errors-spki-list": .certificateBypass,
        "no-sandbox": .sandboxBypass,
        "profile-directory": .profileEscape,
        "remote-allow-origins": .remoteDebugging,
        "remote-debugging-address": .remoteDebugging,
        "remote-debugging-pipe": .remoteDebugging,
        "remote-debugging-port": .remoteDebugging,
        "unsafely-treat-insecure-origin-as-secure": .webSecurityBypass,
        "user-data-dir": .profileEscape,
    ]

    static func violations(in arguments: [String]) -> [ChromiumSwitchViolation] {
        arguments.enumerated().compactMap { index, argument in
            guard let name = normalizedSwitchName(argument),
                  let reason = prohibited[name] else {
                return nil
            }
            return ChromiumSwitchViolation(argumentIndex: index, name: name, reason: reason)
        }
    }

    static func validate(_ arguments: [String]) throws {
        let found = violations(in: arguments)
        guard found.isEmpty else {
            throw ChromiumSwitchValidationError.prohibited(found)
        }
    }

    private static func normalizedSwitchName(_ argument: String) -> String? {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("-") else { return nil }
        let switchBody = trimmed.drop(while: { $0 == "-" })
        guard !switchBody.isEmpty else { return nil }
        let end = switchBody.firstIndex(where: { $0 == "=" || $0.isWhitespace })
            ?? switchBody.endIndex
        return switchBody[..<end].lowercased()
    }
}
