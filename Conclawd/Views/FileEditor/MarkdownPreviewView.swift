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
    let content: String
    let baseURL: URL?
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

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = surfaceNSColor.cgColor
        webView.navigationDelegate = context.coordinator
        loadHTML(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        webView.layer?.backgroundColor = surfaceNSColor.cgColor

        // Skip reload work while the preview is hidden behind the editor.
        guard isVisible else { return }

        if coord.lastContent != content || coord.lastIsDark != isDark {
            loadHTML(into: webView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastContent: String?
        var lastIsDark: Bool?

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
    }

    // MARK: - HTML loading

    private func loadHTML(into webView: WKWebView) {
        let html = makeHTML(markdown: content, dark: isDark)
        webView.loadHTMLString(html, baseURL: baseURL)
        let coord = webView.navigationDelegate as? Coordinator
        coord?.lastContent = content
        coord?.lastIsDark = isDark
    }

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
