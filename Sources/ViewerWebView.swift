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

    static func isTextLike(_ url: URL) -> Bool {
        textExtensions.contains(url.pathExtension.lowercased())
    }
}

struct ViewerWebView: NSViewRepresentable {
    @ObservedObject var doc: DocumentModel

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
        // Avoid a white flash before the page paints its own background.
        webView.underPageBackgroundColor = .textBackgroundColor
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
            let payload: [String: Any] = [
                "markdown": doc.markdown,
                "path": doc.url?.path ?? "",
                "dir": doc.url?.deletingLastPathComponent().path ?? "",
                "name": doc.url?.lastPathComponent ?? "",
                "error": doc.loadError ?? "",
                // Explicit default: this must not depend on registration order.
                "showFrontmatter": UserDefaults.standard.object(forKey: "showFrontmatter") as? Bool
                    ?? true,
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: payload),
                let literal = String(data: json, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript("window.mdview.render(\(literal));")
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
                (.mdvReloadPage, { [weak self] in self?.webView?.reloadFromOrigin() }),
                (.mdvSettingsChanged, { [weak self] in self?.rerender() }),
            ]
            for (name, handler) in map {
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in handler() }
                }
            }
        }

        private func run(_ js: String) { webView?.evaluateJavaScript(js) }

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

        private func copyPath() {
            guard let path = doc.url?.path else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }
}
