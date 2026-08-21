import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// WKWebView that accepts dropped markdown files instead of letting WebKit
/// navigate to them.
final class DroppableWebView: WKWebView {
    var onDroppedFile: ((URL) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFile(sender) != nil ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFile(sender) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        droppedFile(sender) != nil ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let url = droppedMarkdown(sender) {
            onDroppedFile?(url)
            return true
        }
        // Hand other files to whichever app owns them. Falling through to WebKit
        // would navigate the viewer away from its own page.
        if let other = droppedFile(sender) {
            NSWorkspace.shared.open(other)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Mermaid draws its own colours, so it needs a nudge on a light/dark switch.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        evaluateJavaScript("window.mdview && window.mdview.refreshDiagrams()")
    }

    private func droppedMarkdown(_ sender: NSDraggingInfo) -> URL? {
        droppedFiles(sender).first { Viewer.isTextLike($0) }
    }

    private func droppedFile(_ sender: NSDraggingInfo) -> URL? {
        droppedFiles(sender).first
    }

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

/// Which parser the page should use for a document's contents. A string here
/// would let a typo fall back to markdown silently, which for an HTML file is
/// exactly the bug this exists to prevent.
enum DocumentFormat: String {
    case markdown
    case html
}

enum Viewer {
    /// Markdown proper, as opposed to the HTML and plain-text files we also open.
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mdx", "markdn", "rmd", "qmd",
    ]

    static let htmlExtensions: Set<String> = ["html", "htm"]

    /// Read as markdown — which is what they have always been read as — but with
    /// no source of their own to hand back, since the file *is* what is on screen.
    static let plainTextExtensions: Set<String> = ["txt", "text"]

    /// Everything we will open, derived rather than written out again. Kept by
    /// hand, adding an extension to one set above and forgetting this one would
    /// make a file that counts as markdown but cannot be dropped on the window,
    /// linked to, or shown in the sidebar.
    static let textExtensions: Set<String> =
        markdownExtensions.union(htmlExtensions).union(plainTextExtensions)

    static func isTextLike(_ url: URL) -> Bool {
        textExtensions.contains(url.pathExtension.lowercased())
    }

    static func isMarkdown(_ url: URL?) -> Bool {
        guard let url else { return false }
        return markdownExtensions.contains(url.pathExtension.lowercased())
    }

    static func isHTML(_ url: URL?) -> Bool {
        guard let url else { return false }
        return htmlExtensions.contains(url.pathExtension.lowercased())
    }

    /// An HTML file already *is* the markup, and markdown damages what it is
    /// handed: HTML is indented, and four spaces of indent is a markdown code
    /// block, so nested elements come out as `<pre><code>&lt;p&gt;…`. Text
    /// between HTML blocks is parsed as markdown too, so a `~~a~~` there becomes
    /// a strikethrough. Everything that is not HTML stays markdown, .txt included.
    static func format(for url: URL?) -> DocumentFormat {
        isHTML(url) ? .html : .markdown
    }

    /// Copy Document hands back the file's own source. Plain text is left out,
    /// and has been since before there was a format to distinguish — nothing here
    /// is a reason to change that.
    ///
    /// Not because a .txt has no source of its own to hand back: it goes through
    /// the markdown parser like anything else, so what is rendered differs from
    /// the file just as much as an HTML document's does. Two earlier versions of
    /// this comment claimed otherwise.
    static func hasCopyableSource(_ url: URL?) -> Bool {
        guard let url else { return false }
        return isTextLike(url) && !plainTextExtensions.contains(url.pathExtension.lowercased())
    }
}

struct ViewerWebView: NSViewRepresentable {
    @ObservedObject var doc: DocumentModel
    /// WebKit paints this behind the page — which is what shows when you
    /// rubber-band past either end. A system colour here reads as a black band
    /// in the dark theme.
    var background: Color

    /// Inside the app this comes from the bundle; the design/snapshot tools run
    /// outside one and read the working copy instead.
    static var pageURL: URL {
        Bundle.main.url(forResource: "viewer", withExtension: "html")
            ?? URL(fileURLWithPath: "Resources/viewer.html")
    }

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeNSView(context: Context) -> DroppableWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "mdview")

        let webView = DroppableWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = NSColor(background)
        webView.allowsMagnification = true
        webView.onDroppedFile = { url in
            Task { @MainActor in DocumentModel.shared.open(url) }
        }
        context.coordinator.webView = webView
        context.coordinator.observeMenuCommands()

        webView.loadFileURL(ViewerWebView.pageURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))

        // Start with focus in the document, so page keys work straight away and
        // no control in the chrome takes focus at launch.
        DispatchQueue.main.async { webView.window?.makeFirstResponder(webView) }
        return webView
    }

    func updateNSView(_ webView: DroppableWebView, context: Context) {
        context.coordinator.doc = doc
        let colour = NSColor(background)
        if webView.underPageBackgroundColor != colour { webView.underPageBackgroundColor = colour }
        context.coordinator.renderIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var doc: DocumentModel
        weak var webView: DroppableWebView?
        private var pageReady = false
        private var renderedRevision = -1
        private var zoom: CGFloat = 1

        init(doc: DocumentModel) { self.doc = doc }

        // MARK: Rendering

        func renderIfNeeded() {
            guard pageReady, let webView, renderedRevision != doc.revision else { return }
            renderedRevision = doc.revision
            let settings = RenderPayload.settings()
            let payload = RenderPayload(
                markdown: doc.markdown,
                path: doc.url?.path ?? "",
                dir: doc.url?.deletingLastPathComponent().path ?? "",
                error: doc.loadError ?? "",
                format: Viewer.format(for: doc.url),
                showFrontmatter: settings.showFrontmatter,
                theme: settings.theme,
                size: settings.size,
                alignment: settings.alignment,
                measure: settings.measure
            )
            guard let call = payload.renderCall else { return }
            webView.evaluateJavaScript(call)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            // A fresh page has no document in it, whatever we rendered before.
            renderedRevision = -1
            renderIfNeeded()
        }

        // MARK: Links

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = action.request.url else {
                decisionHandler(.allow)
                return
            }

            // The viewer page itself: the initial load, and every in-page #fragment
            // jump. WebKit reports those as link activations pointing at
            // viewer.html#id, so cancelling them breaks heading anchors and
            // footnotes and sends the viewer page to the browser.
            if url.isFileURL, url.path == ViewerWebView.pageURL.path {
                decisionHandler(.allow)
                return
            }

            // Nothing else may navigate: leaving viewer.html destroys
            // window.mdview, and every later render call would fail silently.
            decisionHandler(.cancel)
            guard action.navigationType == .linkActivated else { return }
            if url.isFileURL, Viewer.isTextLike(url) {
                doc.open(url)  // follow links between local markdown files
            } else {
                NSWorkspace.shared.open(url)
            }
        }

        // MARK: Messages from the page

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                let action = body["action"] as? String
            else { return }
            switch action {
            case "openPanel":
                doc.openPanel()
            case "frontmatter":
                let fields = (body["fields"] as? [[String: Any]] ?? []).compactMap {
                    entry -> Frontmatter.Field? in
                    guard let name = entry["name"] as? String else { return nil }
                    return Frontmatter.Field(
                        name: name,
                        values: entry["values"] as? [String] ?? [],
                        isList: entry["isList"] as? Bool ?? false
                    )
                }
                doc.frontmatter = Frontmatter(fields: fields)
                // Part of the same message: the page is where frontmatter is
                // split off, so it is also where the body's words are counted.
                doc.wordCount = body["words"] as? Int
            case "outline":
                let headings = (body["headings"] as? [[String: Any]] ?? []).enumerated()
                    .compactMap { index, entry -> Outline.Heading? in
                        guard let title = entry["title"] as? String else { return nil }
                        return Outline.Heading(
                            level: entry["level"] as? Int ?? 2, title: title, index: index)
                    }
                doc.outline = Outline(headings: headings, current: doc.outline.current)
            case "outlinePosition":
                doc.outline.current = body["index"] as? Int ?? -1
            case "pageFocus":
                // Which is how `KeyContext.pageInputFocused` is real rather than
                // guessed: Swift cannot see into the page, so the page says so.
                NotificationCenter.default.post(
                    name: .mdvPageInputFocus,
                    object: NSNumber(value: body["focused"] as? Bool ?? false))
            case "copyText":
                if let text = body["text"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            default:
                break
            }
        }

        // MARK: Menu commands

        func observeMenuCommands() {
            NotificationCenter.default.addObserver(
                forName: .mdvScrollToHeading, object: nil, queue: .main
            ) { [weak self] note in
                guard let index = note.object as? NSNumber else { return }
                Task { @MainActor in
                    self?.run("window.mdview.scrollToHeading(\(index.intValue))")
                }
            }

            let center = NotificationCenter.default

            // The keyboard shortcuts that move the reader about. Each carries a
            // direction rather than nothing, so they read the notification's
            // object the way mdvScrollToHeading above does. The page owns
            // scrolling and the heading list; none of this is computed here.
            let directed: [(Notification.Name, String)] = [
                (.mdvScrollHalfPage, "scrollHalfPage"),
                (.mdvScrollToEdge, "scrollToEdge"),
                (.mdvStepHeading, "stepHeading"),
            ]
            for (name, function) in directed {
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let direction = (note.object as? NSNumber)?.intValue ?? 1
                    Task { @MainActor in
                        self?.run("window.mdview.\(function)(\(direction))")
                    }
                }
            }

            let map: [(Notification.Name, () -> Void)] = [
                (.mdvReload, { [weak self] in self?.doc.reload() }),
                (.mdvZoomIn, { [weak self] in self?.setZoom(delta: 0.1) }),
                (.mdvZoomOut, { [weak self] in self?.setZoom(delta: -0.1) }),
                (.mdvZoomReset, { [weak self] in self?.resetZoom() }),
                (.mdvFind, { [weak self] in self?.run("window.mdview.openFind()") }),
                (.mdvDismissFind, { [weak self] in self?.run("window.mdview.dismissFind()") }),
                (.mdvPrint, { [weak self] in self?.printPage() }),
                (.mdvCopyPath, { [weak self] in self?.copyPath() }),
                (.mdvCopyDocument, { [weak self] in self?.copyDocument() }),
                (.mdvReloadPage, { [weak self] in self?.webView?.reloadFromOrigin() }),
                (.mdvDumpPage, { [weak self] in self?.dumpPage() }),
                (.mdvSettingsChanged, { [weak self] in self?.rerender() }),
            ]
            for (name, handler) in map {
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in handler() }
                }
            }
        }

        private func run(_ js: String) { webView?.evaluateJavaScript(js) }

        /// Reports what the page actually rendered, so a test can check the real
        /// app rather than a harness that builds its own payload.
        private func dumpPage() {
            let pageBackground =
                webView?.underPageBackgroundColor.usingColorSpace(.sRGB).map {
                    String(
                        format: "#%02x%02x%02x", Int($0.redComponent * 255),
                        Int($0.greenComponent * 255), Int($0.blueComponent * 255))
                } ?? "none"
            print("PAGEBG \(pageBackground)")
            let probe =
                "JSON.stringify({theme: document.documentElement.dataset.theme || 'system', "
                + "size: document.documentElement.dataset.size || 'regular', "
                + "headings: document.querySelectorAll('#doc h1, #doc h2').length})"
            webView?.evaluateJavaScript(probe) { value, error in
                if let error {
                    print("PAGE error=\(error)")
                } else {
                    print("PAGE \((value as? String) ?? "no value")")
                }
            }
        }

        /// Re-render the document unchanged, after a display setting changed.
        private func rerender() {
            renderedRevision = -1
            renderIfNeeded()
        }

        private func setZoom(delta: CGFloat) {
            zoom = min(max(zoom + delta, 0.5), 3.0)
            webView?.pageZoom = zoom
        }

        private func resetZoom() {
            zoom = 1
            webView?.pageZoom = 1
            // pageZoom and magnification are independent; a pinch survives otherwise.
            webView?.magnification = 1
        }

        private func printPage() {
            guard let webView else { return }
            let info = NSPrintInfo.shared
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            let operation = webView.printOperation(with: info)
            operation.view?.frame = webView.bounds
            operation.runModal(
                for: webView.window ?? NSWindow(),
                delegate: nil, didRun: nil, contextInfo: nil)
        }

        /// The file's own source, not the rendered text.
        private func copyDocument() {
            guard Viewer.hasCopyableSource(doc.url), !doc.markdown.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(doc.markdown, forType: .string)
        }

        private func copyPath() {
            guard let path = doc.url?.path else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }
}
