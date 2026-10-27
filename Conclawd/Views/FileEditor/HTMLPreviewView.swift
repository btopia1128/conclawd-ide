import AppKit
import SwiftUI
import WebKit

/// Renders an HTML file from disk in a WKWebView so relative CSS, scripts and
/// images next to it load as they would in a browser. Reloads when the file's
/// content changes (the open-file watcher refreshes `content` on disk writes).
/// Links that leave the page (http/https/mailto) open in the default browser.
struct HTMLPreviewView: NSViewRepresentable {
    let fileURL: URL
    let content: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(fileURL, content: content, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(fileURL, content: content, in: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loadedURL: URL?
        private var loadedContent: String?

        func load(_ url: URL, content: String, in webView: WKWebView) {
            guard url != loadedURL || content != loadedContent else { return }
            let isReload = url == loadedURL
            loadedURL = url
            loadedContent = content
            if isReload {
                webView.reloadFromOrigin()
            } else {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
