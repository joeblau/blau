import AppKit
@preconcurrency import WebKit

@MainActor
extension WKWebView: BrowserControlling {
    func performBrowserCommand(_ command: BrowserControllerCommand) {
        switch command {
        case let .navigate(url):
            load(URLRequest(url: url))
        case .back:
            goBack()
        case .forward:
            goForward()
        case .reload:
            reload()
        case .stop:
            stopLoading()
        case let .setZoom(zoom):
            pageZoom = zoom
        case .focus:
            window?.makeFirstResponder(self)
        case let .setDeveloperToolsVisible(isVisible):
            InspectorHelper.toggleInspector(for: self, show: isVisible)
        case let .openExternally(url):
            NSWorkspace.shared.open(url)
        case .close:
            stopLoading()
            navigationDelegate = nil
            removeFromSuperview()
        }
    }
}
