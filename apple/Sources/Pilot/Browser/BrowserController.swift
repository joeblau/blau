import Foundation

/// Engine-neutral commands issued by Pilot's browser chrome.
///
/// Browser implementations keep their native WebKit/CEF objects private and
/// translate these commands at the presentation boundary.
enum BrowserControllerCommand: Equatable, Sendable {
    case navigate(URL)
    case back
    case forward
    case reload
    case stop
    case setZoom(Double)
    case focus
    case setDeveloperToolsVisible(Bool)
    case openExternally(URL)
    case close
}

@MainActor
protocol BrowserControlling: AnyObject {
    func performBrowserCommand(_ command: BrowserControllerCommand)
}

enum BrowserControllerCommandRouter {
    /// Converts the persisted/transient URL channel into a typed command.
    /// Only exact `blau://` command URLs are privileged; every other URL is a
    /// normal navigation, including lookalike hosts and paths.
    static func command(for pendingURL: URL) -> BrowserControllerCommand {
        switch pendingURL.absoluteString {
        case "blau://back":
            .back
        case "blau://forward":
            .forward
        case "blau://reload":
            .reload
        case "blau://stop":
            .stop
        default:
            .navigate(pendingURL)
        }
    }

    @MainActor
    static func route(
        _ pendingURL: URL,
        to controller: any BrowserControlling
    ) {
        controller.performBrowserCommand(command(for: pendingURL))
    }
}

enum BrowserZoomConversion {
    /// Chromium zoom levels use powers of 1.2, while Pilot and WebKit use a
    /// linear content scale where 1.0 is 100%.
    static func chromiumLevel(forLinearScale scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return 0 }
        return log(scale) / log(1.2)
    }

    static func linearScale(forChromiumLevel level: Double) -> Double {
        guard level.isFinite else { return 1 }
        return pow(1.2, level)
    }
}
