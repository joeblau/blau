import WebKit

enum InspectorHelper {
    static func toggleInspector(for webView: WKWebView, show: Bool) {
        guard let inspector = webView.value(forKey: "_inspector") as? NSObject else { return }

        if show {
            inspector.perform(Selector(("show")))
        } else {
            inspector.perform(Selector(("close")))
        }
    }
}
