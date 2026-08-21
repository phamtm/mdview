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
/// Which checks this render runs.
///
/// Most of them do not depend on the theme — the frontmatter parser, the word
/// count, page focus, the heading clamp, the selection gutter — and running them
/// once per theme was ~3.5s a render for the same answer five times over.
/// `MDVIEW_BATTERY=theme` runs the two phases that do vary: the diagnostics
/// probe, which carries the palette, and the second render, which switches
/// theme and so exercises this one as both a starting point and a destination.
///
/// Full is the default deliberately. A render added without thinking about this
/// then costs time rather than coverage, and tools/check-render.py insists that
/// exactly one file ran the full battery, so dropping it everywhere fails loudly
/// instead of quietly passing with nothing checked.
let fullBattery = (ProcessInfo.processInfo.environment["MDVIEW_BATTERY"] ?? "full") != "theme"
/// The PNGs are for looking at — no test has ever read one. Writing one means
/// holding the page still for 1.2s, which was the most expensive moment in the
/// run, so it happens only when asked: MDVIEW_SHOTS=1, or tools/shots.sh.
let wantShots = ProcessInfo.processInfo.environment["MDVIEW_SHOTS"] != nil
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

// Printed before anything can go wrong, so the checker knows what this file was
// meant to contain even if the render dies half way.
print("BATTERY \(fullBattery ? "full" : "theme")")

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
    /// Every `pageFocus` the page reported, in order. This is what tells Swift
    /// whether the app's plain keys are allowed to act, so a report that never
    /// arrives leaves j/k/n dead — see tools/check-render.py.
    private(set) var focusReports: [Bool] = []

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
        if action == "pageFocus" {
            focusReports.append(body["focused"] as? Bool ?? false)
        }
    }
}

/// A borderless window refuses to become key, and WebKit paints no selection
/// highlight in a window that is not — see checkSelectionGutter().
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class Runner: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: KeyableWindow
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
        window = KeyableWindow(
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
            // mermaid is loaded lazily, so its diagrams appear some time after
            // the render call returns. This used to be a flat 3s wait, which was
            // 30x longer than it takes: ask the page instead, every 50ms.
            self.waitForDiagrams(start: Date())
        }
    }

    /// Polls until every ```mermaid fence in the document has drawn an svg, then
    /// carries on. The deadline is the old flat wait: if the diagrams never
    /// arrive we continue anyway and let the diagnostics report the shortfall,
    /// rather than hanging.
    func waitForDiagrams(start: Date) {
        let wanted = markdown.components(separatedBy: "```mermaid").count - 1
        guard wanted > 0 else {
            driveRail()
            return
        }
        webView.evaluateJavaScript("document.querySelectorAll('#doc .mermaid svg').length") {
            value, _ in
            let drawn = (value as? Int) ?? 0
            if drawn >= wanted || Date().timeIntervalSince(start) > 3.0 {
                self.driveRail()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.waitForDiagrams(start: start)
                }
            }
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
              strikethrough: document.querySelectorAll('#doc del').length,
              // The one decision about keyboard motion, read straight off the
              // page. It cannot be checked by watching a scroll here: this
              // window is offscreen, so requestAnimationFrame never fires and
              // every scroll is instant whatever was asked for. See
              // web/src/motion.js.
              keyboardScrollBehavior: window.mdview._internals.keyboardScrollBehavior
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
            self.afterDiagnostics()
        }
    }

    /// A `theme` run does the diagnostics probe and the second render, and stops
    /// there. The second render stays in because it is nearly free and it is the
    /// one phase below here with a per-theme half: it asks for a *different*
    /// theme and checks the switch took, so keeping it means every palette is
    /// still exercised as both a starting point and a destination. The rest —
    /// the frontmatter parser, the word count, page focus, the heading clamp,
    /// the selection gutter — reaches the same verdict whichever palette is
    /// loaded. See `fullBattery`.
    func afterDiagnostics() {
        guard fullBattery else {
            capturePNG { self.renderAgain() }
            return
        }
        runFrontmatterTests()
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
        runPageTests("tools/wordcount-tests.js", label: "WORDCOUNT") {
            self.capturePNG { self.checkFocusReporting() }
        }
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

    /// Grows the window to the whole document, then writes the PNG if one was
    /// asked for.
    ///
    /// The resize is not optional, even when no PNG is wanted: the phases after
    /// this one measure scrolling, and their expected numbers were established
    /// with a viewport this tall. Only the settle-and-capture is skipped — the
    /// 1.2s wait for the page to hold still, for an image nothing reads.
    func capturePNG(then next: @escaping () -> Void) {
        webView.evaluateJavaScript("document.body.scrollHeight") { value, _ in
            let height = (value as? CGFloat) ?? 1200
            self.window.setContentSize(NSSize(width: 900, height: min(height + 40, 12000)))
            self.webView.frame = NSRect(x: 0, y: 0, width: 900, height: min(height + 40, 12000))
            guard wantShots else {
                next()
                return
            }
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
                    next()
                }
            }
        }
    }

    /// What the page told the app about its own focus, which is what decides
    /// whether the app's plain keys act at all.
    ///
    /// Two things are checked, and only the second is synthesised. The startup
    /// report is real: the page sends it as it loads, which is what re-syncs
    /// Swift after ⌥⌘R (`reloadFromOrigin` sends no message of its own). The
    /// window blur is dispatched by hand, because this window is offscreen and
    /// never key, so WebKit has no real focus change to give us — what that half
    /// covers is the listener being wired up at all, which is precisely what was
    /// missing: without it, moving first responder out of the web view left the
    /// flag stuck true and every plain key silently dead.
    ///
    /// Deliberately after the PNG: openFind() shows the find bar.
    func checkFocusReporting() {
        let startup = MessageRecorder.shared.focusReports
        webView.evaluateJavaScript("window.mdview.openFind(); 'ok'") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let afterFocus = MessageRecorder.shared.focusReports
                self.webView.evaluateJavaScript("window.dispatchEvent(new Event('blur')); 'ok'") {
                    _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let afterBlur = MessageRecorder.shared.focusReports
                        func list(_ values: [Bool]) -> String {
                            "[" + values.map { $0 ? "true" : "false" }.joined(separator: ",") + "]"
                        }
                        print(
                            "PAGEFOCUS {\"startup\":\(list(startup)),"
                                + "\"afterOpenFind\":\(list(afterFocus)),"
                                + "\"afterBlur\":\(list(afterBlur))}")
                        self.webView.evaluateJavaScript("window.mdview.dismissFind(); 'ok'") {
                            _, _ in self.renderAgain()
                        }
                    }
                }
            }
        }
    }

    /// `n` at the end of the document and `N` at the start: neither may move.
    ///
    /// The clamp used to aim at the last (or first) heading instead of standing
    /// still, and past the final heading that is a jump *backwards*: 329px in a
    /// document with a tail after its last heading, and the whole document —
    /// 7043px down to 16 — in one with a single heading.
    ///
    /// Neither case is in sample.md, whose last heading is close enough to the
    /// bottom that the bad jump is swallowed by the scroll clamp, so this renders
    /// two documents of its own. It runs last, after the PNG and after the
    /// re-render checks, because it leaves its own document on the page; and it
    /// shrinks the window first, since `shoot()` grew it to the whole document's
    /// height and a page that cannot scroll cannot show this bug at all.
    ///
    /// Every scroll here asks for "instant" itself, so what is measured is the
    /// clamp and not the behaviour the page chose.
    static let tailMarkdown: String = {
        // Long enough that a jump to the last heading is visibly backwards
        // rather than swallowed by the scroll clamp; check-render.py asserts the
        // headroom so this cannot quietly stop being true.
        let filler = (0..<30).map { "Tail paragraph \($0), well below the last heading." }
            .joined(separator: "\n\n")
        return """
            # Clamp Document

            ## Alpha

            Body text for alpha.

            ## Beta

            Body text for beta.

            ## Gamma

            \(filler)
            """
    }()

    static let oneHeadingMarkdown: String = {
        let filler = (0..<40).map { "Paragraph \($0) of a document with a single heading." }
            .joined(separator: "\n\n")
        return "# Only Heading\n\n\(filler)"
    }()

    func checkHeadingClamp() {
        window.setContentSize(NSSize(width: 900, height: 700))
        webView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        measureClamp(Runner.tailMarkdown, name: "clamp-tail.md") { tail in
            self.measureClamp(Runner.oneHeadingMarkdown, name: "clamp-one.md") { one in
                print("STEPCLAMP {\"tail\":\(tail),\"oneHeading\":\(one)}")
                self.checkFindTyping()
            }
        }
    }

    // MARK: - Typing a whole query into the find bar

    /// Three matches for one word: two in view, and a third far below the fold
    /// so that stepping to it has to scroll.
    ///
    /// Plus the two cases the flat text index exists to get right, searched
    /// separately by `checkFindAcrossMarkup`:
    ///
    ///   * `mark**down**` renders as `mark<strong>down</strong>` — two text
    ///     nodes, and "markdown" only matches if the search crosses them.
    ///   * two adjacent blocks that would read as "there" if their text were
    ///     simply concatenated. They are written as bare `<div>`s on purpose:
    ///     marked puts a newline between every pair of blocks it emits, so a
    ///     pair with real whitespace between them would pass whether the block
    ///     separator is there or not, and the check would prove nothing.
    static let findMarkdown: String = {
        let filler = (0..<40).map { "Filler paragraph \($0), with nothing to find in it." }
            .joined(separator: "\n\n")
        return """
            # Find

            The find bar paints a highlight over every match it can see.

            Highlight the current one differently and the two can be told apart.

            Inline markup splits a phrase in two: mark**down** is one word in
            two text nodes, and matching it has to cross them.

            <div>Blocks do not join. This one ends with the</div><div>re begins \
            the next, so a naive concatenation would find a word that is not on \
            the page.</div>

            \(filler)

            A third highlight, far enough down that stepping to it has to scroll.
            """
    }()

    /// The split phrase, and the word two blocks must not make between them.
    static let findAcrossQuery = "markdown"
    static let findJoinQuery = "there"

    /// Typed one character at a time, and chosen for its letters: `h`, `g` and
    /// `l` are all bound to plain reading keys, so a run where the app stops
    /// standing them down does not just lose characters — it toggles panels.
    static let findQuery = "highlight"

    private static let findKeyCodes: [Character: UInt16] = [
        "h": 4, "i": 34, "g": 5, "l": 37, "t": 17,
    ]

    /// Typing a multi-character query into the find bar, with real key events.
    ///
    /// The bug this exists for: a match used to be shown by moving the document
    /// selection (`window.find`). A page has one selection and WebKit types into
    /// *it*, not into `document.activeElement` — so the first character searched,
    /// the insertion point left the field with the selection, and every character
    /// after it went nowhere. The field still reported focus, so the app rightly
    /// kept its plain keys stood down and passed the keystroke on, and it fell
    /// through a web view with nothing editable in it, which is the beep.
    ///
    /// None of that is reachable by setting `.value` and firing an `input` event:
    /// script would be doing the typing WebKit refused to do. The characters have
    /// to arrive as key events, which is also why this lives here and not in a
    /// page-side test file.
    func checkFindTyping() {
        window.setContentSize(NSSize(width: 900, height: 700))
        webView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let dir = mdURL.deletingLastPathComponent()
        let payload = RenderPayload(
            markdown: Runner.findMarkdown,
            path: dir.appendingPathComponent("find.md").path, dir: dir.path,
            error: "", showFrontmatter: showFrontmatter,
            theme: firstTheme, size: "regular", alignment: alignment, measure: measure)
        guard let call = payload.renderCall else {
            print("FINDTYPING {\"error\":\"payload encode failed\"}")
            checkSelectionGutter()
            return
        }
        webView.evaluateJavaScript(call + " 'ok'") { _, error in
            if let error { print("FINDTYPING render error: \(error)") }
            // A key event only reaches the page if the web view is first
            // responder. It can never reach it because the window is *key*: this
            // harness runs with an activation policy of .prohibited, so no window
            // of ours ever becomes key — which is why the disposition recorded
            // below supplies `windowIsKey` rather than reading it.
            let responder = self.window.makeFirstResponder(self.webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.webView.evaluateJavaScript(
                    "window.scrollTo({ top: 0, behavior: 'instant' });"
                        + " window.mdview.openFind(); 'ok'"
                ) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.typeFindQuery(
                            Array(Runner.findQuery), at: 0, responder: responder,
                            dispositions: [])
                    }
                }
            }
        }
    }

    /// Sends one key event to the window, and reports what the app's own table
    /// would have done with it — with the focus flag the page actually posted.
    private func sendKey(
        _ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []
    ) -> String {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode),
            let stroke = ShortcutMonitor.stroke(for: event)
        else { return "couldNotSynthesise" }
        let disposition = Shortcuts.disposition(
            key: stroke.key, modifiers: stroke.modifiers,
            context: KeyContext(
                windowIsKey: true, editingChromeText: false,
                pageInputFocused: MessageRecorder.shared.focusReports.last ?? false))
        NSApp.sendEvent(event)
        if let up = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode)
        {
            NSApp.sendEvent(up)
        }
        return "\(disposition)"
    }

    /// The find bar's own account of itself: the matches, which one is current,
    /// and how many ranges are painted. A custom highlight is in neither
    /// computed style nor the selection, so nothing else can see it.
    private func findState(_ then: @escaping (String) -> Void) {
        webView.evaluateJavaScript("JSON.stringify(window.mdview._internals.findState())") {
            value, error in
            if let error { print("FINDTYPING state error: \(error)") }
            then((value as? String) ?? "{\"error\":\"no find state\"}")
        }
    }

    private func typeFindQuery(
        _ characters: [Character], at: Int, responder: Bool, dispositions: [String]
    ) {
        guard at < characters.count else {
            let focused = MessageRecorder.shared.focusReports.last ?? false
            findState { typed in
                self.stepFindMatches(
                    responder: responder, dispositions: dispositions, focused: focused,
                    typed: typed)
            }
            return
        }
        let character = characters[at]
        let disposition = sendKey(
            String(character), keyCode: Runner.findKeyCodes[character] ?? 0)
        // A pause between keystrokes, because that is how a query is typed: the
        // bug needs the *previous* character's search to have run.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.typeFindQuery(
                characters, at: at + 1, responder: responder,
                dispositions: dispositions + [disposition])
        }
    }

    /// Return, Return, ⇧Return, then Escape.
    /// Sends one key, gives the page a moment, and reads the bar's state back.
    private func sendAndRead(
        _ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [],
        then: @escaping (String) -> Void
    ) {
        _ = sendKey(characters, keyCode: keyCode, flags: flags)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.findState(then) }
    }

    /// ⏎, ⏎, ⇧⏎ — then a character that makes the query miss, and Esc.
    private func stepFindMatches(
        responder: Bool, dispositions: [String], focused: Bool, typed: String
    ) {
        sendAndRead("\r", keyCode: 36) { next in
            self.sendAndRead("\r", keyCode: 36) { twice in
                self.sendAndRead("\r", keyCode: 36, flags: .shift) { back in
                    // A tenth character, and one nothing matches: the bar has to
                    // say so, and it still has to be *taking* characters by now.
                    self.sendAndRead("z", keyCode: 6) { miss in
                        self.sendAndRead("\u{1b}", keyCode: 53) { closed in
                            let quoted = dispositions.map { "\"\($0)\"" }
                                .joined(separator: ",")
                            print(
                                "FINDTYPING {\"query\":\"\(Runner.findQuery)\","
                                    + "\"firstResponder\":\(responder),"
                                    + "\"dispositions\":[\(quoted)],"
                                    + "\"focusAfterTyping\":\(focused),"
                                    + "\"focusAfterEscape\":"
                                    + "\(MessageRecorder.shared.focusReports.last ?? true),"
                                    + "\"afterTyping\":\(typed),"
                                    + "\"afterNext\":\(next),"
                                    + "\"afterNextTwice\":\(twice),"
                                    + "\"afterPrevious\":\(back),"
                                    + "\"afterMiss\":\(miss),"
                                    + "\"afterEscape\":\(closed)}")
                            self.checkFindAcrossMarkup()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Matching across inline markup, but never across two blocks

    /// The two things the flat text index exists for, on the document the typed
    /// query above just used.
    ///
    /// Driven by setting the field's value from script rather than by key
    /// events. What is under test is which ranges the search builds, and the
    /// typed path — the one WebKit used to break — is covered above; doing it
    /// again would cost nine more keystrokes to learn nothing.
    private func checkFindAcrossMarkup() {
        runFindQuery(Runner.findAcrossQuery) { across in
            self.runFindQuery(Runner.findJoinQuery) { joined in
                self.webView.evaluateJavaScript("window.mdview.dismissFind(); 'ok'") { _, _ in
                    print(
                        "FINDMARKUP {\"acrossQuery\":\"\(Runner.findAcrossQuery)\","
                            + "\"joinQuery\":\"\(Runner.findJoinQuery)\","
                            + "\"across\":\(across),\"joined\":\(joined)}")
                    self.checkSelectionGutter()
                }
            }
        }
    }

    /// Puts one query in the field, lets the bar search for it, and reads back
    /// what it found. Scrolls to the top first, so `nearestToView` picks the
    /// first match rather than whichever one the previous step left on screen.
    private func runFindQuery(_ query: String, then: @escaping (String) -> Void) {
        let script = """
            (function () {
              window.scrollTo({ top: 0, behavior: 'instant' });
              const field = document.getElementById('findinput');
              field.value = '\(query)';
              window.mdview.openFind();
              field.dispatchEvent(new Event('input'));
              return 'ok';
            })()
            """
        webView.evaluateJavaScript(script) { _, error in
            if let error { print("FINDMARKUP script error: \(error)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.findState(then) }
        }
    }

    // MARK: - Selection tint stays inside the column

    /// Four paragraphs, each long enough to wrap, so a selection across them has
    /// real gaps between blocks — which is the only thing that paints the bug.
    static let selectionMarkdown: String = {
        let body = (0..<5).map {
            "Paragraph \($0) of the selection document, written long enough that it "
                + "wraps onto a second line, so the space between its line boxes and the "
                + "space between it and the next block are both real."
        }.joined(separator: "\n\n")
        return "# Selection\n\n\(body)"
    }()

    /// The selection tint must not spill out of the text column.
    ///
    /// The only *paint* check in the suite, and it has to be: nothing about this
    /// artefact reaches computed style or geometry. `Range.getClientRects()`
    /// stays inside the column even while the tint bands across the whole
    /// window, because what paints those bands is WebKit's selection gap
    /// filling — the gaps between a selection root's children, filled out to
    /// that root's content box. `body` is a selection root and `.prose` is not,
    /// so the bands ran the full viewport: 208px past the column on the left and
    /// 177px on the right. `body { display: flex }` in style.css is what removes
    /// them, a flex container having no block gaps to fill.
    ///
    /// So: snapshot the page, select across four blocks, snapshot again, and
    /// count the pixels that changed outside the column's content box.
    ///
    /// Three ways this could pass while seeing nothing, each guarded:
    ///   * with no highlight painted at all the diff is trivially empty, so the
    ///     window is asked to become key and the web view made first responder
    ///     before anything is shot — and both flags are reported, because a `windowKey` of false
    ///     is the first thing to look at if the diff ever comes back empty. What
    ///     actually makes that failure loud rather than silent is
    ///     `insidePixels`, which check-render.py requires to be positive;
    ///   * nothing here may move the document selection. The find bar used to,
    ///     through `window.find`, and this check had to be kept away from it;
    ///     it no longer does — matches are custom highlights now — but a probe
    ///     that selects something of its own would still wipe this one out;
    ///   * `takeSnapshot` hands back stale frames — measured here as the
    ///     pre-selection image coming back twice in a row, in two runs out of
    ///     three — so each shot is repeated until the page settles, and the
    ///     selected frame has to actually differ from the baseline.
    ///
    /// Runs last. It makes the window key, which posts another pageFocus, and it
    /// renders a document of its own — both of which earlier checks read.
    func checkSelectionGutter() {
        window.setContentSize(NSSize(width: 900, height: 700))
        webView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let dir = mdURL.deletingLastPathComponent()
        let payload = RenderPayload(
            markdown: Runner.selectionMarkdown,
            path: dir.appendingPathComponent("selection.md").path, dir: dir.path,
            error: "", showFrontmatter: showFrontmatter,
            theme: firstTheme, size: "regular", alignment: alignment, measure: measure)
        guard let call = payload.renderCall else {
            print("SELECTION {\"error\":\"payload encode failed\"}")
            app.terminate(nil)
            return
        }
        webView.evaluateJavaScript(call + " 'ok'") { _, error in
            if let error { print("SELECTION render error: \(error)") }
            // Without focus WebKit paints no highlight, and the diff below would
            // be empty for the wrong reason.
            self.window.makeKeyAndOrderFront(nil)
            let responder = self.window.makeFirstResponder(self.webView)
            let key = self.window.isKeyWindow
            // Long enough for the column's fade-in to finish, or the baseline
            // shot differs from the second everywhere.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.webView.evaluateJavaScript(
                    "window.scrollTo({ top: 0, behavior: 'instant' }); 'ok'"
                ) { _, _ in
                    self.settledFrame(differingFrom: nil) { before, _ in
                        self.selectAcrossBlocks { info in
                            self.settledFrame(differingFrom: before) { after, tries in
                                self.reportSelectionGutter(
                                    info: info, before: before, after: after, shots: tries,
                                    windowKey: key, firstResponder: responder)
                            }
                        }
                    }
                }
            }
        }
    }

    /// One snapshot, in pixels of our own so nothing depends on the format
    /// WebKit handed back.
    private struct Frame: Equatable {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    /// Shoots until the page holds still — two identical shots in a row — and,
    /// when a `baseline` is given, until the result also differs from it.
    ///
    /// Both halves are needed. `takeSnapshot` will hand back the previous frame:
    /// without the second half a selection that painted perfectly reads as
    /// nothing painted at all, and without the first a baseline caught mid-paint
    /// reads as the whole page having changed.
    private func settledFrame(
        differingFrom baseline: Frame?, previous: Frame? = nil, shot: Int = 1,
        done: @escaping (Frame?, Int) -> Void
    ) {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.snapshotWidth = NSNumber(value: Int(webView.bounds.width))
        webView.takeSnapshot(with: config) { image, error in
            if let error { print("SELECTION snapshot error: \(error)") }
            let frame = self.frame(image)
            let settled = frame != nil && frame == previous
            let moved = baseline == nil || (frame != nil && frame != baseline)
            // 14 shots at 0.25s is 3.5s of patience. Past that, hand back what
            // we have: the counts then fail loudly rather than hanging here.
            if (settled && moved) || shot >= 14 {
                done(frame, shot)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.settledFrame(
                    differingFrom: baseline, previous: frame, shot: shot + 1, done: done)
            }
        }
    }

    /// Selects across four sibling blocks and reports the column's content box,
    /// measured live: the measure is a user setting, so the edges cannot be
    /// hardcoded. Nothing near this may set a selection of its own: there is one
    /// per page, and the artefact vanishes with it.
    private func selectAcrossBlocks(_ done: @escaping ([String: Any]) -> Void) {
        let script = """
            (function () {
              const doc = document.getElementById('doc');
              const blocks = doc.querySelectorAll(':scope > p');
              if (blocks.length < 4) {
                return JSON.stringify({ error: 'only ' + blocks.length + ' blocks to select' });
              }
              const last = blocks[3];
              const range = document.createRange();
              range.setStart(blocks[0], 0);
              range.setEnd(last, last.childNodes.length);
              const sel = window.getSelection();
              sel.removeAllRanges();
              sel.addRange(range);
              const box = doc.getBoundingClientRect();
              const style = getComputedStyle(doc);
              let rectsLeft = box.right, rectsRight = box.left;
              for (const rect of range.getClientRects()) {
                if (!rect.width || !rect.height) continue;
                rectsLeft = Math.min(rectsLeft, rect.left);
                rectsRight = Math.max(rectsRight, rect.right);
              }
              const round = (n) => Math.round(n * 100) / 100;
              return JSON.stringify({
                blocks: 4,
                chars: sel.toString().length,
                columnLeft: round(box.left + parseFloat(style.paddingLeft)),
                columnRight: round(box.right - parseFloat(style.paddingRight)),
                rectsLeft: round(rectsLeft),
                rectsRight: round(rectsRight),
                bodyDisplay: getComputedStyle(document.body).display,
              });
            })()
            """
        webView.evaluateJavaScript(script) { value, error in
            if let error { print("SELECTION probe error: \(error)") }
            let raw = (value as? String) ?? ""
            let object =
                (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            done(object ?? ["error": "no selection probe result"])
        }
    }

    private func frame(_ image: NSImage?) -> Frame? {
        var rect = CGRect(origin: .zero, size: image?.size ?? .zero)
        guard let image,
            let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        else { return nil }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Frame(width: width, height: height, bytes: bytes)
    }

    private func reportSelectionGutter(
        info: [String: Any], before: Frame?, after: Frame?, shots: Int, windowKey: Bool,
        firstResponder: Bool
    ) {
        func fail(_ message: String) {
            print("SELECTION {\"error\":\"\(message)\"}")
            app.terminate(nil)
        }
        if let error = info["error"] as? String { return fail(error) }
        guard let a = before, let b = after else {
            return fail("could not read the snapshots")
        }
        guard a.width == b.width, a.height == b.height, a.width > 0 else {
            return fail(
                "snapshots differ in size (\(a.width)x\(a.height) vs \(b.width)x\(b.height))")
        }
        guard let columnLeft = info["columnLeft"] as? Double,
            let columnRight = info["columnRight"] as? Double
        else { return fail("no column bounds") }
        // The snapshot is in device pixels and the column in CSS pixels.
        let scale = Double(a.width) / Double(webView.bounds.width)
        // Rounded outwards, so a single antialiased pixel on the column's own
        // edge is not read as a gutter — the bands this exists for are hundreds
        // of pixels wide.
        let leftEdge = Int((columnLeft * scale).rounded(.down))
        let rightEdge = Int((columnRight * scale).rounded(.up))
        var inside = 0, left = 0, right = 0
        var minX = a.width, maxX = -1
        for y in 0..<a.height {
            let row = y * a.width * 4
            for x in 0..<a.width {
                let i = row + x * 4
                if a.bytes[i] == b.bytes[i] && a.bytes[i + 1] == b.bytes[i + 1]
                    && a.bytes[i + 2] == b.bytes[i + 2]
                {
                    continue
                }
                if x < leftEdge {
                    left += 1
                } else if x >= rightEdge {
                    right += 1
                } else {
                    inside += 1
                }
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        let fields: [String] = [
            "\"blocks\":\(info["blocks"] as? Int ?? -1)",
            "\"chars\":\(info["chars"] as? Int ?? -1)",
            "\"bodyDisplay\":\"\(info["bodyDisplay"] as? String ?? "?")\"",
            "\"columnLeft\":\(columnLeft)", "\"columnRight\":\(columnRight)",
            "\"rectsLeft\":\(info["rectsLeft"] as? Double ?? -1)",
            "\"rectsRight\":\(info["rectsRight"] as? Double ?? -1)",
            "\"scale\":\(scale)", "\"shots\":\(shots)",
            "\"windowKey\":\(windowKey)", "\"firstResponder\":\(firstResponder)",
            "\"insidePixels\":\(inside)",
            "\"gutterLeftPixels\":\(left)", "\"gutterRightPixels\":\(right)",
            "\"selectionGutterPixels\":\(left + right)",
            // In CSS pixels, so a failure reads in the same units as the design.
            "\"gutterLeftPx\":\(minX <= maxX ? max(0, Int((Double(leftEdge - minX) / scale).rounded())) : 0)",
            "\"gutterRightPx\":\(minX <= maxX ? max(0, Int((Double(maxX - rightEdge + 1) / scale).rounded())) : 0)",
        ]
        print("SELECTION {\(fields.joined(separator: ","))}")
        app.terminate(nil)
    }

    /// Renders `markdown` and reports what `n` and `N` do at either end of it.
    private func measureClamp(
        _ markdown: String, name: String, then: @escaping (String) -> Void
    ) {
        let dir = mdURL.deletingLastPathComponent()
        let payload = RenderPayload(
            markdown: markdown, path: dir.appendingPathComponent(name).path, dir: dir.path,
            error: "", showFrontmatter: showFrontmatter, theme: firstTheme,
            size: "regular", alignment: alignment, measure: measure)
        guard let call = payload.renderCall else {
            then("{\"error\":\"payload encode failed\"}")
            return
        }
        let script = """
            (function () {
              const jump = (top) => window.scrollTo({ top, behavior: 'instant' });
              const at = () => Math.round(window.scrollY);
              const headings = document.querySelectorAll('#doc h1, #doc h2, #doc h3');
              const last = headings[headings.length - 1];
              const lastLanding = last
                ? Math.max(0, Math.round(last.getBoundingClientRect().top + window.scrollY - 56))
                : -1;
              jump(document.documentElement.scrollHeight);
              const atBottom = at();
              window.mdview.stepHeading(1);
              const afterNext = at();
              window.mdview.stepHeading(1);
              const afterNextTwice = at();
              jump(0);
              const atTop = at();
              window.mdview.stepHeading(-1);
              const afterPrevious = at();
              window.mdview.stepHeading(-1);
              const afterPreviousTwice = at();
              // The clamp must not have turned stepping off altogether.
              window.mdview.stepHeading(1);
              const afterOneStepFromTop = at();
              return JSON.stringify({
                headings: headings.length,
                // How far a jump to the last heading would take the reader back
                // up. Zero means this document cannot show the bug.
                bottomHeadroom: atBottom - lastLanding,
                atBottom, afterNext, afterNextTwice,
                atTop, afterPrevious, afterPreviousTwice, afterOneStepFromTop,
              });
            })()
            """
        webView.evaluateJavaScript(call + " 'ok'") { _, error in
            if let error { print("STEPCLAMP render error (\(name)): \(error)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.webView.evaluateJavaScript(script) { value, error in
                    if let error { print("STEPCLAMP probe error (\(name)): \(error)") }
                    then((value as? String) ?? "{\"error\":\"no value\"}")
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
            guard fullBattery else {
                app.terminate(nil)
                return
            }
            self.checkHeadingClamp()
        }
    }
}

let runner = Runner()
runner.start()
app.run()
