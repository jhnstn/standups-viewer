import SwiftUI
import WebKit

/// Renders markdown with a bundled marked.js inside a WKWebView, styled to follow the system appearance.
struct MarkdownView: NSViewRepresentable {
    let markdown: String
    /// Called when the reader ticks the Nth task-list checkbox (document order).
    /// Returns the markdown after the change, or nil if it could not be saved.
    var onToggleTask: (Int, Bool) -> String? = { _, _ in nil }

    static let markedJS: String = {
        guard let url = Bundle.main.url(forResource: "marked.min", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }()

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Clicks on links are reported by the page itself (see the script in html(for:)); the
        // navigation delegate below is a fallback for anything that slips past that.
        config.userContentController.add(context.coordinator, name: "openLink")
        config.userContentController.add(context.coordinator, name: "toggleTask")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onToggleTask = onToggleTask
        guard context.coordinator.lastMarkdown != markdown else { return }
        context.coordinator.lastMarkdown = markdown
        view.loadHTMLString(Self.html(for: markdown), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var lastMarkdown: String?
        var onToggleTask: (Int, Bool) -> String? = { _, _ in nil }

        private func openExternally(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return }
            NSWorkspace.shared.open(url)
        }

        // Primary path: the page posts the href of any clicked link.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "openLink", let href = message.body as? String, let url = URL(string: href) {
                openExternally(url)
            } else if message.name == "toggleTask", let body = message.body as? [String: Any],
                      let index = body["index"] as? Int, let checked = body["checked"] as? Bool {
                if let updated = onToggleTask(index, checked) {
                    // The page already shows the new state; record it so the file-change
                    // reload does not re-render (and lose the scroll position).
                    lastMarkdown = updated
                } else {
                    message.webView?.evaluateJavaScript(
                        "document.querySelectorAll('li input[type=checkbox]')[\(index)].checked = \(!checked)")
                }
            }
        }

        // Fallback: any navigation away from the rendered document goes to the browser instead.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) {
                openExternally(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)   // the loadHTMLString document itself (about:blank)
            }
        }

        // target=_blank links ask for a new web view; send them to the browser too.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { openExternally(url) }
            return nil
        }
    }

    static func html(for markdown: String) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: [markdown]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body { font: 14px/1.55 -apple-system, system-ui, sans-serif; color: -apple-system-label;
                 margin: 0; padding: 22px 32px 48px; max-width: 760px; -webkit-user-select: text; }
          h1 { font-size: 21px; margin: 0 0 18px; letter-spacing: -0.01em; }
          h2 { font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; color: -apple-system-secondary-label;
               margin: 26px 0 8px; padding-bottom: 5px; border-bottom: 1px solid color-mix(in srgb, currentColor 14%, transparent); }
          h3 { font-size: 14px; margin: 18px 0 6px; }
          ul { padding-left: 20px; margin: 0; }
          li { margin: 5px 0; }
          li:has(> input[type=checkbox]) { list-style: none; margin-left: -20px; }
          input[type=checkbox] { margin-right: 7px; vertical-align: -1px; cursor: pointer; }
          li:has(> input:checked) { color: -apple-system-secondary-label; text-decoration: line-through; }
          a { color: -apple-system-blue; text-decoration: none; } a:hover { text-decoration: underline; }
          code { font: 12.5px ui-monospace, Menlo, monospace; background: color-mix(in srgb, currentColor 8%, transparent);
                 padding: 1px 5px; border-radius: 4px; }
          pre { background: color-mix(in srgb, currentColor 6%, transparent); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
          pre code { background: none; padding: 0; }
          em { color: -apple-system-secondary-label; }
          hr { border: 0; border-top: 1px solid color-mix(in srgb, currentColor 14%, transparent); }
          .empty { color: -apple-system-tertiary-label; text-align: center; margin-top: 30vh; }
        </style></head><body>
        <div id="c"><p class="empty">No standup selected</p></div>
        <script>\(markedJS)</script>
        <script>
          const md = \(json)[0];
          if (md.trim()) {
            marked.use({ gfm: true, breaks: false });
            document.getElementById('c').innerHTML = marked.parse(md);
          }
          const boxes = document.querySelectorAll('li input[type=checkbox]');
          boxes.forEach((box, index) => {
            box.disabled = false;
            box.addEventListener('change', () =>
              window.webkit.messageHandlers.toggleTask.postMessage({ index, checked: box.checked }));
          });
          document.addEventListener('click', (e) => {
            const a = e.target.closest('a[href]');
            if (!a) return;
            e.preventDefault();
            window.webkit.messageHandlers.openLink.postMessage(a.href);
          });
        </script></body></html>
        """
    }
}
