// Headless render check: loads the real viewer page in a WKWebView, renders a
// markdown file, prints diagnostics, and writes full-page PNGs.
// Usage: swift tools/snapshot.swift <resources-dir> <markdown-file> <out-prefix>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count > 3 else {
    fatalError("usage: snapshot <resources> <md> <out-prefix> [light|dark]")
}
let resources = URL(fileURLWithPath: args[1])
let mdURL = URL(fileURLWithPath: args[2])
let prefix = args[3]
let mode = args.count > 4 ? args[4] : "light"
// Pass "nofm" as a 6th argument to render with the frontmatter header switched off.
let showFrontmatter = !(args.count > 5 && args[5] == "nofm")
let firstTheme = ProcessInfo.processInfo.environment["MDVIEW_THEME"] ?? "paper"
/// The theme the *second* render asks for. Always a different one, whichever the
/// run started in, so "the theme changed" cannot pass by accident.
let secondTheme = firstTheme == "night" ? "vellum" : "night"
let alignment = ProcessInfo.processInfo.environment["MDVIEW_ALIGN"] ?? "justify"
let measure =
    Double(ProcessInfo.processInfo.environment["MDVIEW_MEASURE"] ?? "")
    ?? RenderPayload.defaultMeasure

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)

/// Records what the page posts to the app, so a test can assert on it.
final class MessageRecorder: NSObject, WKScriptMessageHandler {
    static let shared = MessageRecorder()
    private(set) var actions: [String] = []
    private(set) var outlineCount = -1
    /// The headings of the *latest* outline, in order. A second render that adds
    /// to the outline instead of replacing it shows up here as both documents.
    private(set) var outlineTitles = ""
    /// The titlebar's word count, which the page reports with the frontmatter.
    private(set) var wordCount = -1

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
            let action = body["action"] as? String
        else { return }
        actions.append(action)
        if action == "outline" {
            let headings = body["headings"] as? [[String: Any]] ?? []
            outlineCount = headings.count
            outlineTitles = headings.compactMap { $0["title"] as? String }.joined(separator: ",")
        }
        if action == "frontmatter" {
            wordCount = body["words"] as? Int ?? -1
        }
    }
}

final class Runner: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    let markdown: String

    override init() {
        let config = WKWebViewConfiguration()
        // The app registers this handler, so without it every post() from the
        // page is silently dropped and the harness tests a lookalike.
        config.userContentController.add(MessageRecorder.shared, name: "mdview")
        // MDVIEW_WIDTH widens the page, for layout that depends on the measure
        // fitting inside the viewport.
        let pageWidth = Double(ProcessInfo.processInfo.environment["MDVIEW_WIDTH"] ?? "") ?? 900
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: pageWidth, height: 1200), configuration: config)
        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: pageWidth, height: 1200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        markdown = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
        super.init()
        webView.appearance = NSApp.appearance
        window.appearance = NSApp.appearance
        window.contentView = webView
        window.orderBack(nil)
        webView.navigationDelegate = self
    }

    func start() {
        let page = resources.appendingPathComponent("viewer.html")
        webView.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let payload = RenderPayload(
            markdown: markdown,
            path: mdURL.path,
            dir: mdURL.deletingLastPathComponent().path,
            name: mdURL.lastPathComponent,
            error: "",
            showFrontmatter: showFrontmatter,
            theme: firstTheme,
            size: "regular",
            alignment: alignment,
            measure: measure
        )
        guard let call = payload.renderCall else { print("payload encode failed"); return }
        webView.evaluateJavaScript(call + " 'ok'") { _, error in
            if let error { print("render error: \(error)") }
            // Give lazily-loaded mermaid time to draw.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self.driveRail() }
        }
    }

    func diagnose() {
        let probe = """
            JSON.stringify({
              headings: document.querySelectorAll('#doc h2').length,
              headingIds: document.querySelectorAll('#doc h2[id]').length,
              codeFigures: document.querySelectorAll('#doc figure.code').length,
              highlighted: document.querySelectorAll('#doc figure.code code .hljs-keyword, #doc figure.code code .hljs-string').length,
              copyButtons: document.querySelectorAll('#doc figure.code .copy').length,
              tables: document.querySelectorAll('#doc .table-wrap table').length,
              tasks: document.querySelectorAll('#doc li.task').length,
              tasksDone: document.querySelectorAll('#doc li.task.done').length,
              mermaidSvg: document.querySelectorAll('#doc .mermaid svg').length,
              details: document.querySelectorAll('#doc details').length,
              imgSrc: (document.querySelector('#doc img') || {}).src || 'none',
              imgLoaded: (function(i){ return i ? i.naturalWidth : 0; })(document.querySelector('#doc img')),
              mdLinkHref: (function(){
                var a = Array.from(document.querySelectorAll('#doc a')).find(function(x){ return /README/.test(x.href); });
                return a ? a.href : 'none';
              })(),
              scriptTagsInDoc: document.querySelectorAll('#doc script').length,
              onerrorAttrs: document.querySelectorAll('#doc [onerror]').length,
              pwned: !!window.__pwned,
              appliedTheme: document.documentElement.dataset.theme || 'system',
              railTicks: document.querySelectorAll('.rail-ticks .rail-tick').length,
              railHidden: !!document.querySelector('.rail-zone').hidden,
              asciiBlocks: document.querySelectorAll('#doc figure.code.ascii').length,
              appliedAlign: getComputedStyle(document.querySelector('#doc')).textAlign,
              appliedMeasure: getComputedStyle(document.documentElement)
                .getPropertyValue('--measure').trim(),
              asciiLeading: (function () {
                var pre = document.querySelector('#doc figure.code.ascii pre');
                if (!pre) return 'none';
                var style = getComputedStyle(pre);
                return style.lineHeight + ' / ' + style.fontSize;
              })(),
              railCardCentre: (function () {
                var c = document.querySelector('.rail-card');
                if (!c || c.hidden) return -1;
                var b = c.getBoundingClientRect();
                return Math.round(b.top + b.height / 2);
              })(),
              railTickCentre: (function () {
                var ticks = document.querySelectorAll('.rail-ticks .rail-tick');
                var t = ticks[Math.min(3, ticks.length - 1)];
                if (!t) return -1;
                var b = t.getBoundingClientRect();
                return Math.round(b.top + b.height / 2);
              })(),
              frontmatterTitle: (document.querySelector('#doc .fm-title') || {}).textContent || 'none',
              frontmatterSubtitle: (document.querySelector('#doc .fm-subtitle') || {}).textContent || 'none',
              rawFrontmatterLeaked: /status: draft/.test(document.getElementById('doc').textContent),
              alerts: document.querySelectorAll('#doc blockquote.alert').length,
              alertKinds: Array.from(document.querySelectorAll('#doc blockquote.alert'))
                .map(function (a) { return a.className.replace('alert alert-', ''); }).join(','),
              alertMarkerLeaked: /\\[!NOTE\\]/.test(document.getElementById('doc').textContent),
              // The colour the alert label is actually painted in, per kind.
              // Resolved rather than read as --alert, because the 10px label is
              // text: this is the number contrast is measured on.
              alertLabelColors: (function () {
                var out = {};
                document.querySelectorAll('#doc blockquote.alert').forEach(function (a) {
                  var kind = a.className.replace('alert alert-', '');
                  var label = a.querySelector('.alert-label');
                  out[kind] = label ? getComputedStyle(label).color : 'none';
                });
                return out;
              })(),
              // The column's left padding, which the design sets to 68px so the
              // text clears the contents rail. It once lived in a duplicate
              // .prose rule 840 lines further down and won by being last.
              proseLeftPadding: getComputedStyle(document.getElementById('doc')).paddingLeft,
              footnoteRefs: document.querySelectorAll('#doc .footnote-ref, #doc sup a[href^="#footnote"]').length,
              footnoteItems: document.querySelectorAll('#doc section.footnotes li, #doc .footnotes li').length,
              autolinks: Array.from(document.querySelectorAll('#doc a'))
                .filter(function (a) { return /github\\.com|example\\.com/.test(a.href); }).length,
              strikethrough: document.querySelectorAll('#doc del').length
            })
            """
        webView.evaluateJavaScript(probe) { value, error in
            if let error { print("probe error: \(error)") }
            if let s = value as? String { print("DIAGNOSTICS \(s)") }
            // rawWords is the whole file counted the way the titlebar used to
            // count it. postedWords is the page's count of the body alone, so
            // the two must differ for a document that has frontmatter.
            let rawWords = self.markdown.split(whereSeparator: { $0 == " " || $0.isNewline }).count
            print(
                "POSTED actions=\(Set(MessageRecorder.shared.actions).sorted().joined(separator: ",")) "
                    + "outlineHeadings=\(MessageRecorder.shared.outlineCount) "
                    + "postedWords=\(MessageRecorder.shared.wordCount) rawWords=\(rawWords)")
            self.runFrontmatterTests()
        }
    }

    /// MDVIEW_RAIL=hover hovers a tick, which a still render cannot otherwise
    /// reach. The rail no longer expands — the outline is a panel in the chrome.
    func driveRail() {
        guard let mode = ProcessInfo.processInfo.environment["MDVIEW_RAIL"] else {
            diagnose()
            return
        }
        let hoverTick = """
            (function () {
              const ticks = document.querySelectorAll('.rail-ticks .rail-tick');
              const tick = ticks[Math.min(3, ticks.length - 1)];
              if (!tick) return 'no tick';
              tick.dispatchEvent(new MouseEvent('mouseenter'));
              return 'hovered';
            })()
            """
        // Hovering a tick is all there is to drive: the zone has no mouseenter
        // handler, so there is nothing to open first. The delay lets the card
        // land and settle before the probe measures it.
        guard mode == "hover" else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.diagnose() }
            return
        }
        webView.evaluateJavaScript(hoverTick) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.diagnose() }
        }
    }

    /// The frontmatter parser and the word count are easier to check directly
    /// than through pixels.
    func runFrontmatterTests() {
        runPageTests("tools/frontmatter-tests.js", label: "FRONTMATTER") {
            self.runWordCountTests()
        }
    }

    func runWordCountTests() {
        runPageTests("tools/wordcount-tests.js", label: "WORDCOUNT") { self.shoot() }
    }

    /// Evaluates one of the test files in `tools/` against the loaded page and
    /// prints its `{"failures":[…]}` under `label`, for tools/check-render.py.
    private func runPageTests(_ path: String, label: String, then next: @escaping () -> Void) {
        let script =
            (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)) ?? ""
        guard !script.isEmpty else {
            print("\(label) {\"failures\":[\"test file missing\"]}")
            next()
            return
        }
        webView.evaluateJavaScript(script) { value, error in
            if let error {
                print("\(label) {\"failures\":[\"\(error)\"]}")
            } else if let s = value as? String {
                print("\(label) \(s)")
            }
            next()
        }
    }

    func shoot() {
        webView.evaluateJavaScript("document.body.scrollHeight") { value, _ in
            let height = (value as? CGFloat) ?? 1200
            self.window.setContentSize(NSSize(width: 900, height: min(height + 40, 12000)))
            self.webView.frame = NSRect(x: 0, y: 0, width: 900, height: min(height + 40, 12000))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let config = WKSnapshotConfiguration()
                config.rect = self.webView.bounds
                config.snapshotWidth = NSNumber(value: Int(self.webView.bounds.width))
                self.webView.takeSnapshot(with: config) { image, error in
                    if let error { print("snapshot error \(mode): \(error)") }
                    if let image, let tiff = image.tiffRepresentation,
                        let rep = NSBitmapImageRep(data: tiff),
                        let png = rep.representation(using: .png, properties: [:])
                    {
                        let out = URL(fileURLWithPath: "\(prefix)-\(mode).png")
                        try? png.write(to: out)
                        print(
                            "wrote \(out.path) \(Int(image.size.width))x\(Int(image.size.height))")
                    }
                    self.renderAgain()
                }
            }
        }
    }

    /// A different document, chosen so its counts cannot be confused with
    /// sample.md's: one h1 and three h2s, so four rail ticks and four outline
    /// rows.
    static let secondMarkdown = """
        # Second Render

        ## Alpha

        Body text for alpha.

        ## Beta

        Body text for beta.

        ## Gamma

        Body text for gamma.
        """

    /// Renders a *second* document into the same page.
    ///
    /// Nothing else covers this: every other check renders once and then
    /// snapshots or exits, so a first render that works and a later one that
    /// silently does nothing look exactly alike. What this asserts is the
    /// page-side half — a second render into the same page replaces the first.
    /// The navigation policy in ViewerWebView.swift is *not* covered: this
    /// harness installs its own navigation delegate and has no
    /// decidePolicyFor of its own.
    ///
    /// Deliberately after the PNG is written, so the design snapshots still show
    /// sample.md.
    func renderAgain() {
        let dir = mdURL.deletingLastPathComponent()
        let payload = RenderPayload(
            markdown: Runner.secondMarkdown,
            // A different path, so the page cannot treat this as a reload of the
            // file it already has and keep anything from it.
            path: dir.appendingPathComponent("second-render.md").path,
            dir: dir.path,
            name: "second-render.md",
            error: "",
            showFrontmatter: showFrontmatter,
            theme: secondTheme,
            size: "regular",
            alignment: alignment,
            measure: measure
        )
        guard let call = payload.renderCall else {
            print("RERENDER payload encode failed")
            app.terminate(nil)
            return
        }
        webView.evaluateJavaScript(call + " 'ok'") { _, error in
            if let error { print("RERENDER render error: \(error)") }
            // Waited for the same way as the first render — its completion, then
            // a pause. Shorter, because this document has no diagrams: the pause
            // is only for the page's posts to arrive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.probeAgain() }
        }
    }

    func probeAgain() {
        let titles =
            MessageRecorder.shared.outlineTitles
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // The counts the page posted are folded in here so the whole result is
        // one JSON line for tools/check-render.py.
        let probe = """
            JSON.stringify({
              firstTheme: "\(firstTheme)",
              asked: "\(secondTheme)",
              appliedTheme: document.documentElement.dataset.theme || 'system',
              h1: document.querySelectorAll('#doc h1').length,
              h2: document.querySelectorAll('#doc h2').length,
              railTicks: document.querySelectorAll('.rail-ticks .rail-tick').length,
              railHidden: !!document.querySelector('.rail-zone').hidden,
              outlineHeadings: \(MessageRecorder.shared.outlineCount),
              outlineTitles: "\(titles)"
            })
            """
        webView.evaluateJavaScript(probe) { value, error in
            if let error { print("RERENDER probe error: \(error)") }
            if let s = value as? String { print("RERENDER \(s)") }
            app.terminate(nil)
        }
    }
}

let runner = Runner()
runner.start()
app.run()
