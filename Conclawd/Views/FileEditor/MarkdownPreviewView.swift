import AppKit
import SwiftUI
import WebKit

private extension NSColor {
    /// Convert to a CSS hex string (#RRGGBB) using the sRGB color space.
    var hexString: String {
        let rgb = usingColorSpace(.sRGB) ?? self
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// Renders Markdown as HTML in a WKWebView using bundled marked.js + highlight.js.
/// Light/dark theme follows the app's `appearanceMode` setting.
struct MarkdownPreviewView: NSViewRepresentable {
    let fileURL: URL
    let content: String
    let baseURL: URL?
    @Binding var relativeScrollPosition: Double
    /// Whether the preview is currently the visible mode. When false we skip HTML
    /// reloads to avoid wasted work while the editor is on top.
    var isVisible: Bool = true

    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.dark.rawValue

    private var isDark: Bool {
        switch AppearanceMode(rawValue: appearanceMode) ?? .dark {
        case .dark: return true
        case .light, .claude: return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    /// Resolve the editor surface color (matches `Color.appSurface`) in sRGB.
    private var surfaceNSColor: NSColor {
        if NSColor.isClaudeTheme {
            return NSColor(srgbRed: 0xF5/255.0, green: 0xEF/255.0, blue: 0xE6/255.0, alpha: 1)
        }
        let appearance: NSAppearance =
            (NSAppearance(named: isDark ? .darkAqua : .aqua)) ?? NSApp.effectiveAppearance
        var resolved = NSColor.appUnifiedSurface
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.appUnifiedSurface.usingColorSpace(.sRGB) ?? NSColor.appUnifiedSurface
        }
        return resolved
    }

    /// CSS hex string of the surface color, for inline `<style>` injection.
    private var surfaceHex: String {
        surfaceNSColor.hexString
    }

    func makeNSView(context: Context) -> PreviewContainerView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = surfaceNSColor.cgColor
        webView.navigationDelegate = context.coordinator

        let container = PreviewContainerView(webView: webView)
        context.coordinator.update(
            container: container,
            request: .init(fileURL: fileURL, content: content, baseURL: baseURL, isDark: isDark),
            isVisible: isVisible,
            relativeScrollPosition: $relativeScrollPosition,
            surfaceColor: surfaceNSColor,
            makeHTML: { markdown, dark in
                makeHTML(markdown: markdown, dark: dark)
            }
        )
        return container
    }

    func updateNSView(_ container: PreviewContainerView, context: Context) {
        let coord = context.coordinator
        container.webView.layer?.backgroundColor = surfaceNSColor.cgColor
        coord.update(
            container: container,
            request: .init(fileURL: fileURL, content: content, baseURL: baseURL, isDark: isDark),
            isVisible: isVisible,
            relativeScrollPosition: $relativeScrollPosition,
            surfaceColor: surfaceNSColor,
            makeHTML: { markdown, dark in
                makeHTML(markdown: markdown, dark: dark)
            }
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        struct Request: Equatable {
            let fileURL: URL
            let content: String
            let baseURL: URL?
            let isDark: Bool
        }

        private var renderedRequest: Request?
        private var pendingRequest: Request?
        private weak var pendingNavigation: WKNavigation?
        private var currentRelativeScrollPosition: Binding<Double> = .constant(0)
        private var wasVisible = false

        func update(
            container: PreviewContainerView,
            request: Request,
            isVisible: Bool,
            relativeScrollPosition: Binding<Double>,
            surfaceColor: NSColor,
            makeHTML: @escaping (String, Bool) -> String
        ) {
            let wasVisibleBeforeUpdate = wasVisible
            defer { wasVisible = isVisible }
            currentRelativeScrollPosition = relativeScrollPosition

            if !isVisible {
                if wasVisibleBeforeUpdate {
                    persistScrollPosition(in: container.webView, relativeScrollPosition: relativeScrollPosition)
                }
                return
            }

            if !wasVisibleBeforeUpdate, renderedRequest == request {
                restoreScrollPosition(relativeScrollPosition.wrappedValue, in: container.webView)
                return
            }

            if pendingRequest == request || renderedRequest == request {
                return
            }

            if wasVisibleBeforeUpdate {
                persistScrollPosition(in: container.webView, relativeScrollPosition: relativeScrollPosition)
                container.showSnapshot(of: container.webView)
            } else if renderedRequest?.fileURL != request.fileURL {
                container.showPlaceholder(color: surfaceColor)
            }

            load(request, in: container.webView, makeHTML: makeHTML)
        }

        // Open external links in the default browser instead of navigating inside the WebView.
        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === pendingNavigation, let request = pendingRequest else { return }
            restoreScrollPosition(currentRelativeScrollPosition.wrappedValue, in: webView)
            renderedRequest = request
            pendingRequest = nil
            pendingNavigation = nil
            (webView.superview as? PreviewContainerView)?.fadeOutSnapshot()
        }

        @MainActor
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard navigation === pendingNavigation else { return }
            finishFailedTransition(in: webView)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard navigation === pendingNavigation else { return }
            finishFailedTransition(in: webView)
        }

        private func load(
            _ request: Request,
            in webView: WKWebView,
            makeHTML: (String, Bool) -> String
        ) {
            let html = makeHTML(request.content, request.isDark)
            pendingRequest = request
            pendingNavigation = webView.loadHTMLString(html, baseURL: request.baseURL)
        }

        private func persistScrollPosition(in webView: WKWebView, relativeScrollPosition: Binding<Double>) {
            relativeScrollPosition.wrappedValue = currentRelativeScrollPosition(in: webView)
        }

        private func restoreScrollPosition(_ relativeScrollPosition: Double, in webView: WKWebView) {
            let scrollY = scrollOffset(for: relativeScrollPosition, in: webView)
            let js = "window.scrollTo(0, \(scrollY));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        private func currentRelativeScrollPosition(in webView: WKWebView) -> Double {
            guard let scrollView = scrollView(in: webView) else { return 0 }
            let maxOffset = max(scrollView.documentViewHeight - scrollView.contentSize.height, 0)
            guard maxOffset > 0 else { return 0 }
            return min(max(Double(scrollView.contentView.bounds.origin.y / maxOffset), 0), 1)
        }

        private func scrollOffset(for relativeScrollPosition: Double, in webView: WKWebView) -> Double {
            guard let scrollView = scrollView(in: webView) else { return 0 }
            let maxOffset = max(scrollView.documentViewHeight - scrollView.contentSize.height, 0)
            guard maxOffset > 0 else { return 0 }
            return Double(maxOffset) * min(max(relativeScrollPosition, 0), 1)
        }

        private func finishFailedTransition(in webView: WKWebView) {
            pendingRequest = nil
            pendingNavigation = nil
            (webView.superview as? PreviewContainerView)?.hideSnapshot()
        }

        private func scrollView(in webView: WKWebView) -> NSScrollView? {
            findScrollView(in: webView)
        }

        private func findScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            for subview in view.subviews {
                if let scrollView = findScrollView(in: subview) {
                    return scrollView
                }
            }
            return nil
        }
    }

    // MARK: - HTML loading

    private func makeHTML(markdown: String, dark: Bool) -> String {
        let bundle = Bundle.main
        let markedURL = bundle.url(forResource: "marked.min", withExtension: "js")
        let hljsURL = bundle.url(forResource: "highlight.min", withExtension: "js")
        let cssURL = bundle.url(forResource: dark ? "github-dark.min" : "github.min", withExtension: "css")

        let markedScript = (try? String(contentsOf: markedURL ?? URL(fileURLWithPath: "/dev/null"), encoding: .utf8)) ?? ""
        let hljsScript = (try? String(contentsOf: hljsURL ?? URL(fileURLWithPath: "/dev/null"), encoding: .utf8)) ?? ""
        let hljsCSS = (try? String(contentsOf: cssURL ?? URL(fileURLWithPath: "/dev/null"), encoding: .utf8)) ?? ""

        let bg = surfaceHex
        let fg = dark ? "#e6e6e6" : "#1f1f1f"
        let muted = dark ? "#9a9a9a" : "#6a6a6a"
        let border = dark ? "#3a3a3a" : "#e1e4e8"
        let codeBg = dark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.05)"
        let linkColor = dark ? "#58a6ff" : "#0969da"

        // JSON-encode the markdown so we can safely inject as a JS string literal.
        let jsonData = (try? JSONSerialization.data(withJSONObject: [markdown], options: [])) ?? Data("[\"\"]".utf8)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "[\"\"]"

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(hljsCSS)
        html, body {
          margin: 0;
          padding: 0;
          background: \(bg);
          color: \(fg);
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
          font-size: 14px;
          line-height: 1.6;
          -webkit-font-smoothing: antialiased;
        }
        #content {
          padding: 24px 32px;
          max-width: 880px;
          margin: 0 auto;
        }
        h1, h2, h3, h4, h5, h6 { font-weight: 600; margin-top: 24px; margin-bottom: 12px; }
        h1 { font-size: 1.8em; border-bottom: 1px solid \(border); padding-bottom: 0.3em; }
        h2 { font-size: 1.4em; border-bottom: 1px solid \(border); padding-bottom: 0.3em; }
        h3 { font-size: 1.15em; }
        p { margin: 0 0 12px; }
        a { color: \(linkColor); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace; font-size: 0.9em; background: \(codeBg); padding: 2px 5px; border-radius: 4px; }
        pre { background: \(codeBg); padding: 12px 14px; border-radius: 6px; overflow-x: auto; }
        pre code { background: transparent; padding: 0; border-radius: 0; font-size: 0.875em; line-height: 1.5; }
        blockquote { margin: 0 0 12px; padding: 0 14px; color: \(muted); border-left: 3px solid \(border); }
        ul, ol { padding-left: 1.6em; margin: 0 0 12px; }
        li { margin: 4px 0; }
        table { border-collapse: collapse; margin: 0 0 12px; }
        th, td { border: 1px solid \(border); padding: 6px 12px; }
        th { background: \(codeBg); font-weight: 600; }
        img { max-width: 100%; }
        hr { border: 0; border-top: 1px solid \(border); margin: 20px 0; }
        input[type="checkbox"] { margin-right: 6px; }
        ::selection { background: rgba(88, 166, 255, 0.35); }
        </style>
        </head>
        <body>
        <div id="content"></div>
        <script>\(markedScript)</script>
        <script>\(hljsScript)</script>
        <script>
        (function () {
          var md = \(jsonString)[0];
          marked.setOptions({
            gfm: true,
            breaks: false,
            highlight: function (code, lang) {
              try {
                if (lang && hljs.getLanguage(lang)) {
                  return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
                }
                return hljs.highlightAuto(code).value;
              } catch (e) {
                return code;
              }
            }
          });
          document.getElementById('content').innerHTML = marked.parse(md);
          document.querySelectorAll('pre code').forEach(function (el) {
            try { hljs.highlightElement(el); } catch (e) {}
          });
        })();
        </script>
        </body>
        </html>
        """
    }
}

private extension NSScrollView {
    var documentViewHeight: CGFloat {
        documentView?.bounds.height ?? 0
    }
}

final class PreviewContainerView: NSView {
    let webView: WKWebView
    private let snapshotView = NSImageView()

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)

        wantsLayer = true

        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)

        snapshotView.frame = bounds
        snapshotView.autoresizingMask = [.width, .height]
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.wantsLayer = true
        snapshotView.isHidden = true
        addSubview(snapshotView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSnapshot(of webView: WKWebView) {
        guard let image = makeSnapshot(of: webView) else {
            hideSnapshot()
            return
        }

        snapshotView.alphaValue = 1
        snapshotView.image = image
        snapshotView.isHidden = false
    }

    func showPlaceholder(color: NSColor) {
        snapshotView.layer?.backgroundColor = color.cgColor
        snapshotView.alphaValue = 1
        snapshotView.image = nil
        snapshotView.isHidden = false
    }

    func fadeOutSnapshot() {
        guard !snapshotView.isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            snapshotView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.hideSnapshot()
        }
    }

    func hideSnapshot() {
        snapshotView.alphaValue = 1
        snapshotView.layer?.backgroundColor = nil
        snapshotView.image = nil
        snapshotView.isHidden = true
    }

    private func makeSnapshot(of view: NSView) -> NSImage? {
        let bounds = view.bounds.integral
        guard !bounds.isEmpty,
              let representation = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }

        view.cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}
