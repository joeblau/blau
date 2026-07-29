import Foundation
import Testing
@testable import Pilot

@Suite("Browser controller routing")
@MainActor
struct BrowserControllerTests {
    @Test("Transient browser command URLs route to typed controller commands")
    func routesTypedCommands() throws {
        let controller = FakeBrowserController()
        let inputs = [
            "blau://back",
            "blau://forward",
            "blau://reload",
            "blau://stop",
        ]

        for input in inputs {
            BrowserControllerCommandRouter.route(
                try #require(URL(string: input)),
                to: controller
            )
        }

        #expect(controller.commands == [.back, .forward, .reload, .stop])
    }

    @Test("Ordinary and command-lookalike URLs remain navigations")
    func preservesNavigations() throws {
        let controller = FakeBrowserController()
        let ordinaryURL = try #require(URL(string: "https://example.test/path"))
        let lookalikeURL = try #require(URL(string: "blau://reload/extra"))

        BrowserControllerCommandRouter.route(ordinaryURL, to: controller)
        BrowserControllerCommandRouter.route(lookalikeURL, to: controller)

        #expect(controller.commands == [
            .navigate(ordinaryURL),
            .navigate(lookalikeURL),
        ])
    }

    @Test("Commands reach only the selected pane controller")
    func keepsControllersIndependent() throws {
        let selected = FakeBrowserController()
        let background = FakeBrowserController()
        let target = try #require(URL(string: "http://127.0.0.1:8080/"))

        BrowserControllerCommandRouter.route(target, to: selected)
        selected.performBrowserCommand(.setZoom(1.25))
        selected.performBrowserCommand(.focus)
        selected.performBrowserCommand(.setDeveloperToolsVisible(true))
        selected.performBrowserCommand(.close)

        #expect(selected.commands == [
            .navigate(target),
            .setZoom(1.25),
            .focus,
            .setDeveloperToolsVisible(true),
            .close,
        ])
        #expect(background.commands.isEmpty)
    }

    @Test("Chromium zoom conversion preserves Pilot's linear scale")
    func convertsChromiumZoomLevels() {
        #expect(
            abs(
                BrowserZoomConversion.chromiumLevel(forLinearScale: 1)
            ) < 0.000_001
        )
        #expect(
            abs(
                BrowserZoomConversion.chromiumLevel(forLinearScale: 1.2) - 1
            ) < 0.000_001
        )
        #expect(
            abs(
                BrowserZoomConversion.linearScale(forChromiumLevel: -1)
                    - (1 / 1.2)
            ) < 0.000_001
        )
        #expect(
            BrowserZoomConversion.chromiumLevel(forLinearScale: 0) == 0
        )
        #expect(
            BrowserZoomConversion.linearScale(
                forChromiumLevel: .infinity
            ) == 1
        )
    }
}

@MainActor
private final class FakeBrowserController: BrowserControlling {
    private(set) var commands: [BrowserControllerCommand] = []

    func performBrowserCommand(_ command: BrowserControllerCommand) {
        commands.append(command)
    }
}
