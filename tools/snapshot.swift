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

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)

/// Records what the page posts to the app, so a test can assert on it.
final class MessageRecorder: NSObject, WKScriptMessageHandler {
    static let shared = MessageRecorder()
    private(set) var actions: [String] = []
    private(set) var outlineCount = -1

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
            let action = body["action"] as? String
        else { return }
        actions.append(action)
        if action == "outline" {
            outlineCount = (body["headings"] as? [[String: Any]])?.count ?? 0
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
            theme: ProcessInfo.processInfo.environment["MDVIEW_THEME"] ?? "paper",
            size: "regular",
            alignment: ProcessInfo.processInfo.environment["MDVIEW_ALIGN"] ?? "justify",
            measure: Double(ProcessInfo.processInfo.environment["MDVIEW_MEASURE"] ?? "")
                ?? RenderPayload.defaultMeasure
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
              bodyHeight: document.body.scrollHeight,
              appliedTheme: document.documentElement.dataset.theme || 'system',
              railTicks: document.querySelectorAll('.rail-ticks .rail-tick').length,
              railRows: document.querySelectorAll('.rail-panel .rail-row').length,
              railHidden: !!document.querySelector('.rail-zone').hidden,
              asciiBlocks: document.querySelectorAll('#doc figure.code.ascii').length,
              appliedAlign: getComputedStyle(document.querySelector('#doc')).textAlign,
              appliedMeasure: getComputedStyle(document.documentElement)
                .getPropertyValue('--measure').trim(),
              proseTextWidth: (function () {
                var doc = document.getElementById('doc');
                var style = getComputedStyle(doc);
                return Math.round(
                  doc.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight));
              })(),
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
              frontmatterFields: document.querySelectorAll('#doc .fm-fields dt').length,
              frontmatterSubtitle: (document.querySelector('#doc .fm-subtitle') || {}).textContent || 'none',
              frontmatterPills: document.querySelectorAll('#doc .fm-pill').length,
              rawFrontmatterLeaked: /status: draft/.test(document.getElementById('doc').textContent),
              alerts: document.querySelectorAll('#doc blockquote.alert').length,
              alertKinds: Array.from(document.querySelectorAll('#doc blockquote.alert'))
                .map(function (a) { return a.className.replace('alert alert-', ''); }).join(','),
              alertMarkerLeaked: /\\[!NOTE\\]/.test(document.getElementById('doc').textContent),
              footnoteRefs: document.querySelectorAll('#doc .footnote-ref, #doc sup a[href^="#footnote"]').length,
              footnoteItems: document.querySelectorAll('#doc section.footnotes li, #doc .footnotes li').length,
              autolinks: Array.from(document.querySelectorAll('#doc a'))
                .filter(function (a) { return /github\\.com|example\\.com/.test(a.href); }).length,
              strikethrough: document.querySelectorAll('#doc del').length,
              footnoteRefMarkup: (document.querySelector('#doc sup, #doc .footnote-ref') || {}).outerHTML || 'none',
              footnoteSectionHead: (function () {
                var s = document.querySelector('#doc section.footnotes, #doc .footnotes');
                return s ? s.outerHTML.slice(0, 220) : 'none';
              })(),
              cssBgSoft: getComputedStyle(document.body).getPropertyValue('--bg-soft'),
              cssFg: getComputedStyle(document.body).getPropertyValue('--fg'),
              nodeStyle: (function(){
                var r = document.querySelector('#doc .mermaid .node rect, #doc .mermaid .node circle, #doc .mermaid rect');
                if (!r) return 'none';
                var cs = getComputedStyle(r);
                return 'fill=' + cs.fill + ' stroke=' + cs.stroke + ' attr=' + (r.getAttribute('style')||'');
              })()
            })
            """
        webView.evaluateJavaScript(probe) { value, error in
            if let error { print("probe error: \(error)") }
            if let s = value as? String { print("DIAGNOSTICS \(s)") }
            print(
                "POSTED actions=\(Set(MessageRecorder.shared.actions).sorted().joined(separator: ",")) "
                    + "outlineHeadings=\(MessageRecorder.shared.outlineCount)")
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
        let enterZone = """
            (function () {
              const zone = document.querySelector('.rail-zone');
              if (!zone) return 'no zone';
              zone.dispatchEvent(new MouseEvent('mouseenter'));
              return 'entered';
            })()
            """
        let hoverTick = """
            (function () {
              const ticks = document.querySelectorAll('.rail-ticks .rail-tick');
              const tick = ticks[Math.min(3, ticks.length - 1)];
              if (!tick) return 'no tick';
              tick.dispatchEvent(new MouseEvent('mouseenter'));
              return 'hovered';
            })()
            """
        webView.evaluateJavaScript(enterZone) { _, _ in
            // The panel opens only after dwelling in the zone.
            if mode == "hover" {
                self.webView.evaluateJavaScript(hoverTick) { _, _ in }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.diagnose() }
        }
    }

    /// The frontmatter parser is easier to check directly than through pixels.
    func runFrontmatterTests() {
        let script =
            (try? String(
                contentsOf: URL(fileURLWithPath: "tools/frontmatter-tests.js"),
                encoding: .utf8)) ?? ""
        guard !script.isEmpty else {
            print("FRONTMATTER {\"failures\":[\"test file missing\"]}"); shoot(); return
        }
        webView.evaluateJavaScript(script) { value, error in
            if let error {
                print("FRONTMATTER {\"failures\":[\"\(error)\"]}")
            } else if let s = value as? String {
                print("FRONTMATTER \(s)")
            }
            self.shoot()
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
                    app.terminate(nil)
                }
            }
        }
    }
}

let runner = Runner()
runner.start()
app.run()
