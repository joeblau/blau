import Foundation

/// A path-safe profile identifier. Native Chromium code receives profile URLs
/// produced by `ChromiumProfileLocation`, never an arbitrary workspace or
/// system Chrome path.
struct ChromiumProfileIdentifier: RawRepresentable, Hashable, Sendable {
    static let defaultProfile = ChromiumProfileIdentifier(uncheckedRawValue: "default")
    static let maximumUTF8Length = 64

    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= Self.maximumUTF8Length,
              rawValue.unicodeScalars.allSatisfy(Self.isAllowed) else {
            return nil
        }
        self.rawValue = rawValue
    }

    init?(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    private init(uncheckedRawValue: String) {
        self.rawValue = uncheckedRawValue
    }

    private static func isAllowed(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 45, 48...57, 65...90, 95, 97...122:
            true
        default:
            false
        }
    }
}

/// Constructs the only persistent profile locations Pilot permits.
struct ChromiumProfileLocation: Equatable, Sendable {
    let applicationSupportDirectory: URL

    init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    var profilesRootURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("Pilot", isDirectory: true)
            .appendingPathComponent("Chromium", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    var defaultProfileURL: URL {
        directory(for: .defaultProfile)
    }

    func directory(for identifier: ChromiumProfileIdentifier) -> URL {
        profilesRootURL.appendingPathComponent(identifier.rawValue, isDirectory: true)
    }

    func isManagedProfileDirectory(_ candidate: URL) -> Bool {
        guard let (rootComponents, candidateComponents) = containedComponents(
            for: candidate
        ) else {
            return false
        }
        guard candidateComponents.count == rootComponents.count + 1,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            return false
        }
        return ChromiumProfileIdentifier(rawValue: candidateComponents.last ?? "") != nil
    }

    func ownsData(at candidate: URL) -> Bool {
        guard let (rootComponents, candidateComponents) = containedComponents(
            for: candidate
        ) else {
            return false
        }
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// Reject every symlink in the managed root or candidate path. Lexical
    /// prefix checks alone would allow `Profiles/default` to target a workspace
    /// or a system Chrome profile.
    private func containedComponents(
        for candidate: URL
    ) -> (root: [String], candidate: [String])? {
        let root = profilesRootURL.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard resolvedRoot == root else { return nil }

        let standardizedCandidate = candidate.standardizedFileURL
        guard standardizedCandidate.resolvingSymlinksInPath()
                == standardizedCandidate else {
            return nil
        }
        return (root.pathComponents, standardizedCandidate.pathComponents)
    }
}

enum ChromiumProfileSecurityError: Error {
    case unmanagedProfileDirectory
    case profileClearInProgress
}
