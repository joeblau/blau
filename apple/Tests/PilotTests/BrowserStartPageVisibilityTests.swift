import Foundation
import Testing
@testable import Pilot

@Suite("Browser start page visibility")
struct BrowserStartPageVisibilityTests {

    @Test
    func blankBrowserKeepsStartPageWhileAddressBarTextIsDrafted() {
        #expect(BrowserStartPageVisibility.shouldShow(
            hasLoadedAnyURL: false,
            openedWithBlankURL: true,
            urlText: "g",
            hasPendingPageNavigation: false
        ))
    }

    @Test
    func submittedDraftHidesStartPageForNavigation() {
        #expect(!BrowserStartPageVisibility.shouldShow(
            hasLoadedAnyURL: false,
            openedWithBlankURL: true,
            urlText: "google.com",
            hasPendingPageNavigation: true
        ))
    }

    @Test
    func browserCommandDoesNotHideBlankStartPage() {
        #expect(BrowserStartPageVisibility.shouldShow(
            hasLoadedAnyURL: false,
            openedWithBlankURL: true,
            urlText: "",
            hasPendingPageNavigation: false
        ))
    }

    @Test
    func restoredURLSkipsStartPage() {
        #expect(!BrowserStartPageVisibility.shouldShow(
            hasLoadedAnyURL: false,
            openedWithBlankURL: nil,
            urlText: "https://example.com",
            hasPendingPageNavigation: false
        ))
    }
}
