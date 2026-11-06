import SwiftUI
import WebKit
import AppKit

struct HTMLMessageView: NSViewRepresentable {
    let html: String
    let allowRemoteImages: Bool
    let onOpenLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpenLink: onOpenLink) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.load(html, allowRemoteImages: allowRemoteImages, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.load(html, allowRemoteImages: allowRemoteImages, into: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onOpenLink: (URL) -> Void
        private var lastDocument: String?

        init(onOpenLink: @escaping (URL) -> Void) {
            self.onOpenLink = onOpenLink
        }

        func load(_ source: String, allowRemoteImages: Bool, into webView: WKWebView) {
            let document = Self.document(for: source, allowRemoteImages: allowRemoteImages)
            guard lastDocument != document else { return }
            lastDocument = document
            webView.loadHTMLString(document, baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            preferences.allowsContentJavaScript = false
            // The in-memory document may load, but links must not navigate the app to the web.
            if navigationAction.request.url?.scheme == "about" || navigationAction.request.url == nil {
                return (.allow, preferences)
            }
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                onOpenLink(url)
            }
            return (.cancel, preferences)
        }

        private static func document(for source: String, allowRemoteImages: Bool) -> String {
            EmailHTMLSanitizer.forWebView(source, allowRemoteImages: allowRemoteImages)
        }
    }
}
