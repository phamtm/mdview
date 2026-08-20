import AppKit
import Foundation

/// One entry in the sidebar tree — a folder or a file.
///
/// Children are read from disk the first time a folder is expanded, and kept
/// afterwards. While a folder is expanded it also watches itself, so files
/// added or deleted elsewhere show up without a manual refresh.
@MainActor
final class FileNode: ObservableObject, Identifiable {
    let url: URL
    let isDirectory: Bool
    let isRoot: Bool
    /// Resolved once: comparing raw paths misses files reached through a symlink.
    let canonicalPath: String

    @Published private(set) var children: [FileNode] = []
    @Published var isExpanded = false { didSet { expansionChanged() } }

    private var loaded = false
    private var watcher: FileWatcher?
    private weak var workspace: WorkspaceModel?

    nonisolated var id: String { url.path }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool, isRoot: Bool = false, workspace: WorkspaceModel?) {
        self.url = url
        self.canonicalPath = url.resolvingSymlinksInPath().path
        self.isDirectory = isDirectory
        self.isRoot = isRoot
        self.workspace = workspace
    }

    func toggle() {
        guard isDirectory else { return }
        isExpanded.toggle()
    }

    /// Reads children without expanding, so search can look inside closed folders.
    func loadForSearch() {
        guard isDirectory, !loaded else { return }
        load()
    }

    func reloadIfLoaded() {
        guard loaded else { return }
        load()
        for child in children where child.isDirectory { child.reloadIfLoaded() }
    }

    private func expansionChanged() {
        guard isDirectory else { return }
        if isExpanded {
            if !loaded { load() }
            startWatching()
        } else {
            watcher = nil
        }
        workspace?.treeChanged()
    }

    private func startWatching() {
        guard watcher == nil else { return }
        watcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.load() }
        }
    }

    /// Re-read the folder, reusing existing nodes so expanded subtrees survive.
    private func load() {
        loaded = true
        let showAll = workspace?.showAllFiles ?? false
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []

        let existing = Dictionary(
            children.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [FileNode] = []
        for item in contents {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir, !showAll, !Viewer.isTextLike(item) { continue }
            next.append(
                existing[item.path]
                    ?? FileNode(url: item, isDirectory: isDir, workspace: workspace))
        }
        next.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        children = next
        workspace?.treeChanged()
    }
}

/// One visible line in the sidebar: a node plus how deep it sits.
struct SidebarRow: Identifiable {
    let node: FileNode
    let depth: Int
    /// Identity is where the row *appears*, not what it points at.
    ///
    /// Depth is included because adding two folders where one contains the other
    /// puts the same file on screen twice. The listed path is used rather than the
    /// symlink-resolved one because a symlink beside its target — `AGENTS.md ->
    /// CLAUDE.md` — otherwise gives both rows the same id, and SwiftUI drops one.
    var id: String { "\(depth)/\(node.url.path)" }
}

/// The folders the user has added to the sidebar.
@MainActor
final class WorkspaceModel: ObservableObject {
    static let shared = WorkspaceModel()

    @Published private(set) var roots: [FileNode] = []
    /// The tree flattened to what's actually on screen, rebuilt on every change.
    @Published private(set) var rows: [SidebarRow] = []
    /// The sidebar's search box. While it holds text, folders expand to show
    /// their matches and folders with none drop out of the list.
    @Published var query = "" { didSet { flattenRows() } }

    @Published var showAllFiles: Bool {
        didSet {
            UserDefaults.standard.set(showAllFiles, forKey: showAllKey)
            refresh()
        }
    }

    private var flattenPending = false
    private let rootsKey = "sidebarFolders"
    private let showAllKey = "sidebarShowAllFiles"

    private init() {
        showAllFiles = UserDefaults.standard.bool(forKey: showAllKey)
        let saved = UserDefaults.standard.stringArray(forKey: rootsKey) ?? []
        roots =
            saved
            .filter { isDirectory(URL(fileURLWithPath: $0)) }
            .map { makeRoot(URL(fileURLWithPath: $0)) }
        roots.forEach { $0.isExpanded = true }
        flattenRows()
    }

    /// Called by nodes when they expand, collapse, or reload their children.
    ///
    /// Coalesced to one rebuild per turn: a refresh re-reads every folder ever
    /// loaded, and each one used to trigger a full tree walk and a SwiftUI
    /// invalidation — dozens of them, synchronously, on every app activation.
    func treeChanged() {
        guard !flattenPending else { return }
        flattenPending = true
        Task { @MainActor in
            flattenPending = false
            flattenRows()
        }
    }

    /// Immediate rebuild, for actions whose result is read straight away.
    func flattenRows() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var flattened: [SidebarRow] = []

        /// While searching, a folder earns its row only if something under it
        /// matches — and it is shown open, so the matches are visible.
        func matches(_ node: FileNode) -> Bool {
            if needle.isEmpty { return true }
            if node.name.lowercased().contains(needle) { return true }
            guard node.isDirectory else { return false }
            if !node.isExpanded { node.loadForSearch() }
            return node.children.contains(where: matches)
        }

        func walk(_ node: FileNode, depth: Int) {
            flattened.append(SidebarRow(node: node, depth: depth))
            guard node.isDirectory, node.isExpanded || !needle.isEmpty else { return }
            for child in node.children where matches(child) { walk(child, depth: depth + 1) }
        }

        for root in roots where matches(root) { walk(root, depth: 0) }
        rows = flattened
    }

    /// "3 folders · 7 files", as the design's footer shows.
    var libraryMeta: String {
        var folders = 0
        var files = 0
        for row in rows {
            if row.node.isDirectory { folders += 1 } else { files += 1 }
        }
        let f = "\(folders) folder" + (folders == 1 ? "" : "s")
        let d = "\(files) file" + (files == 1 ? "" : "s")
        return "\(f) · \(d)"
    }

    func addFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to show in the sidebar"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(add)
    }

    func add(_ url: URL) {
        let target = url.standardizedFileURL
        guard isDirectory(target), !roots.contains(where: { $0.url.path == target.path }) else {
            return
        }
        let root = makeRoot(target)
        roots.append(root)
        root.isExpanded = true
        persist()
        flattenRows()
    }

    func remove(_ node: FileNode) {
        roots.removeAll { $0.url.path == node.url.path }
        persist()
        flattenRows()
    }

    func refresh() {
        roots.forEach { $0.reloadIfLoaded() }
    }

    /// Expand the tree down to a file and return true if it was found, so the
    /// sidebar can follow along when a document is opened from elsewhere.
    func reveal(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        for root in roots where path.hasPrefix(root.canonicalPath + "/") {
            expand(root, towards: path)
        }
    }

    private func expand(_ node: FileNode, towards path: String) {
        node.isExpanded = true
        for child in node.children
        where child.isDirectory && path.hasPrefix(child.canonicalPath + "/") {
            expand(child, towards: path)
        }
    }

    private func makeRoot(_ url: URL) -> FileNode {
        FileNode(url: url, isDirectory: true, isRoot: true, workspace: self)
    }

    private func persist() {
        UserDefaults.standard.set(roots.map(\.url.path), forKey: rootsKey)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
