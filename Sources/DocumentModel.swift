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
    /// Read from the rendered document by the page; the contents panel shows it.
    @Published var outline = Outline()
    /// Bumped on every content change so the web view knows to re-render.
    @Published private(set) var revision = 0

    private var watcher: FileWatcher?
    private let recentsKey = "recentDocuments"
    private let lastDocumentKey = "lastDocument"
    private let maxRecents = 12

    private init() {
        recents = (UserDefaults.standard.stringArray(forKey: recentsKey) ?? [])
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var lastDocument: URL? {
        guard let path = UserDefaults.standard.string(forKey: lastDocumentKey),
            FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// `remember: false` keeps a diagnostic run out of the recents list.
    func open(_ target: URL, remember: Bool = true) {
        let resolved = target.standardizedFileURL
        url = resolved
        canonicalPath = resolved.resolvingSymlinksInPath().path
        frontmatter = Frontmatter()
        outline = Outline()
        load()
        if remember { self.remember(resolved) }
        // Watch after loading so an editor's atomic save can't slip past us.
        watcher = FileWatcher(url: resolved) { [weak self] in
            Task { @MainActor in self?.load() }
        }
    }

    func reload() { load() }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = DocumentModel.contentTypes
        panel.message = "Choose a Markdown file"
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

    static let contentTypes = ["net.daringfireball.markdown", "public.plain-text", "public.text"]
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
