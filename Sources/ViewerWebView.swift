import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Actions the menu bar sends to the web view.
extension Notification.Name {
    static let mdvReload = Notification.Name("mdv.reload")
    static let mdvZoomIn = Notification.Name("mdv.zoomIn")
    static let mdvZoomOut = Notification.Name("mdv.zoomOut")
    static let mdvZoomReset = Notification.Name("mdv.zoomReset")
    static let mdvFind = Notification.Name("mdv.find")
    static let mdvPrint = Notification.Name("mdv.print")
    static let mdvCopyPath = Notification.Name("mdv.copyPath")
    static let mdvSettingsChanged = Notification.Name("mdv.settingsChanged")
    static let mdvToggleSidebar = Notification.Name("mdv.toggleSidebar")
    static let mdvReloadPage = Notification.Name("mdv.reloadPage")
    static let mdvOpenSettings = Notification.Name("mdv.openSettings")
    /// Asks the page to report what it actually rendered; see tools/check-theme.sh.
    static let mdvDumpPage = Notification.Name("mdv.dumpPage")
    static let mdvToggleFrontmatter = Notification.Name("mdv.toggleFrontmatter")
    static let mdvCopyDocument = Notification.Name("mdv.copyDocument")
}

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

enum Viewer {
    static let textExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mdx", "markdn", "txt", "text", "rmd", "qmd",
    ]

    /// Markdown proper, as opposed to the plain-text files we will also open.
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mdx", "markdn", "rmd", "qmd",
    ]

    static func isTextLike(_ url: URL) -> Bool {
        textExtensions.contains(url.pathExtension.lowercased())
    }

    static func isMarkdown(_ url: URL?) -> Bool {
        guard let url else { return false }
        return markdownExtensions.contains(url.pathExtension.lowercased())
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
                name: doc.url?.lastPathComponent ?? "",
                error: doc.loadError ?? "",
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
            let center = NotificationCenter.default
            let map: [(Notification.Name, () -> Void)] = [
                (.mdvReload, { [weak self] in self?.doc.reload() }),
                (.mdvZoomIn, { [weak self] in self?.setZoom(delta: 0.1) }),
                (.mdvZoomOut, { [weak self] in self?.setZoom(delta: -0.1) }),
                (.mdvZoomReset, { [weak self] in self?.resetZoom() }),
                (.mdvFind, { [weak self] in self?.run("window.mdview.openFind()") }),
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

        /// The file's own markdown, not the rendered text.
        private func copyDocument() {
            guard Viewer.isMarkdown(doc.url), !doc.markdown.isEmpty else { return }
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
