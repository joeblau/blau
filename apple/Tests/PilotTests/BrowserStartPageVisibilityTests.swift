import Foundation
import Testing
import WebKit
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

@Suite("Browser lasso state and script contracts")
struct BrowserLassoTests {

    @Test
    func settingAndTogglingLassoPublishesOnlyRealStateChanges() {
        let state = BrowserState()
        let initialRequestID = state.annotateToggleRequestID

        state.setAnnotateMode(true)
        #expect(state.annotateMode)
        #expect(state.annotateToggleRequestID == initialRequestID + 1)

        state.setAnnotateMode(true)
        #expect(state.annotateMode)
        #expect(state.annotateToggleRequestID == initialRequestID + 1)

        state.toggleAnnotateMode()
        #expect(!state.annotateMode)
        #expect(state.annotateToggleRequestID == initialRequestID + 2)

        state.setAnnotateMode(false)
        #expect(!state.annotateMode)
        #expect(state.annotateToggleRequestID == initialRequestID + 2)
    }

    @Test
    func enableScriptsPersistDesiredStateBeforeTouchingInjectedController() {
        let enable = BrowserAnnotate.setEnabledScript(true).filter { !$0.isWhitespace }
        let disable = BrowserAnnotate.setEnabledScript(false).filter { !$0.isWhitespace }

        let enableDesired = enable.range(of: "__pilotAnnotateDesiredEnabled=true")
        let enableController = enable.range(of: "__pilotAnnotate.setEnabled(true)")
        let disableDesired = disable.range(of: "__pilotAnnotateDesiredEnabled=false")
        let disableController = disable.range(of: "__pilotAnnotate.setEnabled(false)")

        #expect(enableDesired != nil)
        #expect(enableController != nil)
        #expect(disableDesired != nil)
        #expect(disableController != nil)
        if let enableDesired, let enableController {
            #expect(enableDesired.lowerBound < enableController.lowerBound)
        }
        if let disableDesired, let disableController {
            #expect(disableDesired.lowerBound < disableController.lowerBound)
        }
    }

    @Test
    func injectedScriptExposesStableSelectionLockAndOverlayMarkers() {
        let script = BrowserAnnotate.userScript

        #expect(script.contains("data-pilot-annotate-highlight"))
        #expect(script.contains("data-pilot-annotate-box"))
        #expect(script.contains("hovered"))
        #expect(script.contains("selected"))
        #expect(script.contains("finishSend"))
    }

    @Test
    func finishScriptUsesTheInjectedControllerLifecycleHook() {
        let script = BrowserAnnotate.finishSendScript(selectionID: 42)

        #expect(script.contains("__pilotAnnotate"))
        #expect(script.contains("finishSend(42)"))
        #expect(BrowserAnnotate.userScript.contains("completedSelectionID !== sendingID"))
    }

    @Test
    func shiftedCommandAIsReservedForLasso() {
        #expect(BrowserWebShortcutPolicy.keepsNativeEditingShortcut(
            characters: "a",
            hasShift: false
        ))
        #expect(!BrowserWebShortcutPolicy.keepsNativeEditingShortcut(
            characters: "a",
            hasShift: true
        ))
        #expect(BrowserWebShortcutPolicy.keepsNativeEditingShortcut(
            characters: "z",
            hasShift: true
        ))
    }

    @Test
    @MainActor
    func injectedLassoLocksAndClearsTheSelectedElement() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserAnnotate.userScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            configuration: configuration
        )
        let loader = BrowserLassoTestLoader()
        webView.navigationDelegate = loader
        let loaded = await loader.load(
            """
            <!doctype html><html><head><style>
            html,body { margin:0; width:400px; height:300px; }
            #a,#b { position:absolute; top:20px; width:100px; height:50px; }
            #a { left:10px; } #b { left:200px; }
            </style></head><body><div id="a">A</div><div id="b">B</div></body></html>
            """,
            in: webView
        )
        #expect(loaded)
        guard loaded else { return }

        _ = try await webView.evaluateJavaScript(BrowserAnnotate.setEnabledScript(true))
        let hoverA = try await evaluateString(in: webView, script: """
        var a = document.getElementById('a');
        a.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:20, clientY:30}));
        document.querySelector('[data-pilot-annotate-highlight]').style.left;
        """)
        let selectedA = try await evaluateString(in: webView, script: """
        a.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, composed:true, clientX:20, clientY:30}));
        a.dispatchEvent(new MouseEvent('click', {bubbles:true, composed:true, clientX:20, clientY:30}));
        JSON.stringify({left:document.querySelector('[data-pilot-annotate-highlight]').style.left, box:!!document.querySelector('[data-pilot-annotate-box]')});
        """)
        let lockedAfterMovingToB = try await evaluateString(in: webView, script: """
        var b = document.getElementById('b');
        b.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:220, clientY:30}));
        document.querySelector('[data-pilot-annotate-highlight]').style.left;
        """)

        _ = try await webView.evaluateJavaScript(BrowserAnnotate.setEnabledScript(false))
        let disabled = try await evaluateString(in: webView, script: """
        JSON.stringify({display:document.querySelector('[data-pilot-annotate-highlight]').style.display, box:!!document.querySelector('[data-pilot-annotate-box]')});
        """)

        // Re-enable and click B without a preceding mousemove. A stale hover
        // from before the toggle must never select A again.
        _ = try await webView.evaluateJavaScript(BrowserAnnotate.setEnabledScript(true))
        let selectedB = try await evaluateString(in: webView, script: """
        b.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, composed:true, clientX:220, clientY:30}));
        b.dispatchEvent(new MouseEvent('click', {bubbles:true, composed:true, clientX:220, clientY:30}));
        JSON.stringify({left:document.querySelector('[data-pilot-annotate-highlight]').style.left, box:!!document.querySelector('[data-pilot-annotate-box]')});
        """)
        _ = try await webView.evaluateJavaScript(BrowserAnnotate.finishSendScript(selectionID: 1))
        let afterStaleFinish = try await evaluateString(in: webView, script: """
        JSON.stringify({left:document.querySelector('[data-pilot-annotate-highlight]').style.left, box:!!document.querySelector('[data-pilot-annotate-box]')});
        """)

        #expect(hoverA == "10px")
        #expect(selectedA.contains("\"left\":\"10px\""))
        #expect(selectedA.contains("\"box\":true"))
        #expect(lockedAfterMovingToB == "10px")
        #expect(disabled.contains("\"display\":\"none\""))
        #expect(disabled.contains("\"box\":false"))
        #expect(selectedB.contains("\"left\":\"200px\""))
        #expect(selectedB.contains("\"box\":true"))
        #expect(afterStaleFinish.contains("\"left\":\"200px\""))
        #expect(afterStaleFinish.contains("\"box\":true"))
    }

    @MainActor
    private func evaluateString(in webView: WKWebView, script: String) async throws -> String {
        try await webView.evaluateJavaScript(script) as? String ?? ""
    }
}

@MainActor
private final class BrowserLassoTestLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?

    func load(_ html: String, in webView: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(false)
    }

    private func finish(_ loaded: Bool) {
        continuation?.resume(returning: loaded)
        continuation = nil
    }
}
