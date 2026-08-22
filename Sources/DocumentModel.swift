import AppKit
import Foundation
import UniformTypeIdentifiers

/// Holds the markdown file currently on screen, reloads it when it changes on
/// disk, and remembers the files opened recently.
/// A document's frontmatter, as the page parsed it.
struct Frontmatter {
    struct Field: Identifiable {
        let name: String
        let values: [String]
        let isList: Bool
        var id: String { name }
    }

    var fields: [Field] = []

    var isEmpty: Bool { fields.isEmpty }
    /// Tag-like lists are shown as pills below the rows, per the design.
    var rows: [Field] { fields.filter { !$0.isList } }
    var pills: [Field] { fields.filter(\.isList) }
}

@MainActor
final class DocumentModel: ObservableObject {
    static let shared = DocumentModel()

    @Published private(set) var url: URL?
    /// Symlinks resolved, so the sidebar can match a file it reached by another path.
    @Published private(set) var canonicalPath: String?
    @Published private(set) var markdown = ""
    @Published private(set) var loadError: String?
    @Published private(set) var recents: [URL] = []
    /// Parsed by the page and sent back, so there is only one parser.
    @Published var frontmatter = Frontmatter()
    /// Words in the body, counted by the page and sent back on the same message.
    /// Counting here would mean stripping frontmatter here, and a second
    /// frontmatter parser is a second thing to keep in step. nil only until the
    /// page's first report; `open()` leaves it alone deliberately — see there.
    /// A load error hides it either way: the titlebar shows the error instead.
    @Published var wordCount: Int?
    /// Read from the rendered document by the page; the contents panel shows it.
    @Published var outline = Outline()
    /// Bumped on every content change so the web view knows to re-render.
    @Published private(set) var revision = 0
    /// Whether the reader has somewhere behind or ahead to go. Drives the menu
    /// items' enabled state; the stacks themselves stay private so every path
    /// through `open` records itself the same way.
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// A reading position to hand back to the page on the next render, for a
    /// document reopened after a launch (or after enough other files that the
    /// page's own session memory dropped it). Consumed by the web view.
    var pendingResumeY: Double?

    private var watcher: FileWatcher?
    private let recentsKey = "recentDocuments"
    private let lastDocumentKey = "lastDocument"
    private let maxRecents = 12

    // Reading positions, by canonical path, kept across launches. The page
    // reports a position as the reader settles and remembers its own within a
    // session; this map is what makes reopening tomorrow land where today left
    // off. `scrollOrder` is the same keys, most recently touched last, so the
    // cap evicts the stalest rather than an arbitrary one.
    private var scrollMemory: [String: Double] = [:]
    private var scrollOrder: [String] = []
    private var scrollPersistTask: Task<Void, Never>?
    private let scrollMemoryKey = "readingPositions"
    private let maxRememberedPositions = 64

    // Where the reader has been, for ⌘[ / ⌘]. Following a link between notes
    // is only pleasant if getting back is one keystroke away.
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    private init() {
        recents = (UserDefaults.standard.stringArray(forKey: recentsKey) ?? [])
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if let saved = UserDefaults.standard.dictionary(forKey: scrollMemoryKey)
            as? [String: Double]
        {
            scrollMemory = saved.filter { $0.value.isFinite && $0.value >= 0 }
        }
    }

    var lastDocument: URL? {
        guard let path = UserDefaults.standard.string(forKey: lastDocumentKey),
            FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// `remember: false` keeps a diagnostic run out of the recents list.
    /// Navigation-passing false keeps ⌘[ from pushing the document it is
    /// leaving back onto its own stack.
    func open(_ target: URL, remember: Bool = true) {
        open(target, remember: remember, recordHistory: true)
    }

    private func open(_ target: URL, remember: Bool, recordHistory: Bool) {
        let resolved = target.standardizedFileURL
        if recordHistory, let current = url, current != resolved {
            // A fresh forward journey abandons the old one, as in every browser.
            backStack.append(current)
            if backStack.count > maxRecents { backStack.removeFirst() }
            forwardStack.removeAll()
        }
        url = resolved
        canonicalPath = resolved.resolvingSymlinksInPath().path
        frontmatter = Frontmatter()
        // The position to land at. The page's own session memory is checked
        // first by the page itself; this only fills in when it has none — a
        // relaunch, mostly.
        pendingResumeY = canonicalPath.flatMap { scrollMemory[$0] }
        // wordCount is deliberately *not* cleared: the page reports the new one
        // within a frame (it posts before it renders), so clearing here would
        // empty the titlebar's second row and back again on every open, every
        // ⌘R and every save the watcher picks up. Switching documents replaces
        // one count with another instead.
        outline = Outline()
        load()
        if remember { self.remember(resolved) }
        // Watch after loading so an editor's atomic save can't slip past us.
        watcher = FileWatcher(url: resolved) { [weak self] in
            Task { @MainActor in self?.load() }
        }
    }

    // MARK: Back / forward

    /// Where the reader came from. Opening the file again re-enters the normal
    /// flow: this push lands on the stack we just came home to, so toggling
    /// between two files works and nothing grows unbounded.
    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = url { forwardStack.append(current) }
        open(previous, remember: true, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = url { backStack.append(current) }
        open(next, remember: true, recordHistory: false)
    }

    /// The page reports where the reader settled; kept per canonical path and
    /// persisted (coalesced), so tomorrow's reopen resumes today's place.
    func rememberScroll(path: String, y: Double) {
        let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard y.isFinite, y >= 0 else { return }
        scrollMemory[key] = y
        scrollOrder.removeAll { $0 == key }
        scrollOrder.append(key)
        while scrollOrder.count > maxRememberedPositions {
            scrollMemory.removeValue(forKey: scrollOrder.removeFirst())
        }
        scrollPersistTask?.cancel()
        scrollPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            UserDefaults.standard.set(self.scrollMemory, forKey: self.scrollMemoryKey)
        }
    }

    func reload() { load() }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = DocumentModel.contentTypes
        panel.message = "Choose a Markdown, HTML or text file"
        if panel.runModal() == .OK, let picked = panel.url { open(picked) }
    }

    func revealInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: recentsKey)
    }

    static let contentTypes = [
        "net.daringfireball.markdown", "public.plain-text", "public.text", "public.html",
    ]
    .compactMap(UTType.init(_:))

    // MARK: - Private

    private func load() {
        guard let url else { return }
        do {
            let data = try Data(contentsOf: url)
            markdown = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            loadError = nil
        } catch {
            markdown = ""
            loadError = error.localizedDescription
        }
        revision += 1
    }

    private func remember(_ url: URL) {
        recents.removeAll { $0.path == url.path }
        recents.insert(url, at: 0)
        if recents.count > maxRecents { recents.removeLast(recents.count - maxRecents) }
        UserDefaults.standard.set(recents.map(\.path), forKey: recentsKey)
        UserDefaults.standard.set(url.path, forKey: lastDocumentKey)
    }
}
