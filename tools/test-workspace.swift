// Checks the sidebar tree model: what it shows, in what order, that it can
// reveal a nested file, and that an expanded folder notices new files.
import AppKit

var failures = 0
func check(_ label: String, _ condition: Bool) {
    print(condition ? "  ok   \(label)" : "  FAIL \(label)")
    if !condition { failures += 1 }
}

/// Spin the run loop until `condition` holds, so watcher callbacks can land.
func waitUntil(_ timeout: TimeInterval = 3.0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return condition()
}

MainActor.assumeIsolated {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mdview-workspace-test-\(UUID().uuidString)")
    let root = base.appendingPathComponent("project")
    for path in ["README.md", "docs/guide.md", "docs/deep/nested.md", "src/main.swift", "zebra.md"]
    {
        let url = root.appendingPathComponent(path)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try! "# x\n".write(to: url, atomically: true, encoding: .utf8)
    }

    let workspace = WorkspaceModel.shared
    // Copying the source is offered for markdown, not for every readable file.
    check("md is markdown", Viewer.isMarkdown(URL(fileURLWithPath: "/tmp/a.md")))
    check("markdown is markdown", Viewer.isMarkdown(URL(fileURLWithPath: "/tmp/a.markdown")))
    check("mdx is markdown", Viewer.isMarkdown(URL(fileURLWithPath: "/tmp/a.mdx")))
    check("txt is not markdown", !Viewer.isMarkdown(URL(fileURLWithPath: "/tmp/a.txt")))
    check("png is not markdown", !Viewer.isMarkdown(URL(fileURLWithPath: "/tmp/a.png")))
    // HTML is opened and rendered, but it is not markdown: the format decides
    // which parser the page uses, and calling it markdown would run the wrong one.
    check("html is not markdown", !Viewer.isMarkdown(URL(fileURLWithPath: "/tmp/a.html")))
    check("html is html", Viewer.isHTML(URL(fileURLWithPath: "/tmp/a.html")))
    check("htm is html", Viewer.isHTML(URL(fileURLWithPath: "/tmp/a.HTM")))
    check("md is not html", !Viewer.isHTML(URL(fileURLWithPath: "/tmp/a.md")))
    check("html is text-like", Viewer.isTextLike(URL(fileURLWithPath: "/tmp/a.html")))
    check("html formats as html", Viewer.format(for: URL(fileURLWithPath: "/tmp/a.html")) == .html)
    check(
        "md formats as markdown",
        Viewer.format(for: URL(fileURLWithPath: "/tmp/a.md")) == .markdown)
    // A .txt has always been treated as markdown, and still is.
    check(
        "txt formats as markdown",
        Viewer.format(for: URL(fileURLWithPath: "/tmp/a.txt")) == .markdown)
    check("nothing open formats as markdown", Viewer.format(for: nil) == .markdown)
    // The rawValue is what crosses to the page, so a renamed case would change
    // the wire format without changing anything the compiler can see.
    check("html goes over the wire as \"html\"", DocumentFormat.html.rawValue == "html")
    check(
        "markdown goes over the wire as \"markdown\"",
        DocumentFormat.markdown.rawValue == "markdown")
    // textExtensions is derived from the other two sets now. This is the
    // invariant that used to be kept by hand: a file cannot count as markdown or
    // html while being un-openable.
    check(
        "every markdown and html extension is openable",
        Viewer.markdownExtensions.union(Viewer.htmlExtensions)
            .isSubset(of: Viewer.textExtensions))
    check(
        "html source can be copied", Viewer.hasCopyableSource(URL(fileURLWithPath: "/tmp/a.html")))
    check("txt source is not copied", !Viewer.hasCopyableSource(URL(fileURLWithPath: "/tmp/a.txt")))
    check("nothing open is not markdown", !Viewer.isMarkdown(nil))

    workspace.roots.forEach { workspace.remove($0) }
    workspace.showAllFiles = false
    workspace.add(root)

    check("adding a folder creates one root", workspace.roots.count == 1)
    check(
        "adding the same folder twice is ignored",
        {
            workspace.add(root); return workspace.roots.count == 1
        }())

    guard let node = workspace.roots.first else { print("WORKSPACE TESTS FAILED"); exit(1) }
    let names = node.children.map(\.name)
    check("folders sort before files: \(names)", names == ["docs", "src", "README.md", "zebra.md"])
    check("non-markdown files hidden by default", !names.contains("main.swift"))

    // main.swift lives in src/, so expand that folder to see the filter at work
    guard let src = node.children.first(where: { $0.name == "src" }) else {
        print("WORKSPACE TESTS FAILED (no src folder)"); exit(1)
    }
    src.isExpanded = true
    check("expanded folder hides non-markdown files", src.children.isEmpty)
    workspace.showAllFiles = true
    check(
        "show-all reaches already-expanded subfolders", src.children.map(\.name) == ["main.swift"])
    workspace.showAllFiles = false
    check("turning show-all off hides them again", src.children.isEmpty)

    // reveal() should open every folder down to the file
    let deep = root.appendingPathComponent("docs/deep/nested.md")
    workspace.reveal(deep)
    let docs = node.children.first { $0.name == "docs" }
    let deepDir = docs?.children.first { $0.name == "deep" }
    check("reveal expands the root", node.isExpanded)
    check(
        "reveal expands intermediate folders",
        docs?.isExpanded == true && deepDir?.isExpanded == true)
    check("revealed file is present", deepDir?.children.contains { $0.name == "nested.md" } == true)

    // an expanded folder should notice a file appearing on disk
    let added = root.appendingPathComponent("docs/brand-new.md")
    try! "# new\n".write(to: added, atomically: true, encoding: .utf8)
    let sawNewFile = waitUntil { docs?.children.contains { $0.name == "brand-new.md" } == true }
    check("expanded folder picks up a new file", sawNewFile)

    // and a file disappearing
    try! FileManager.default.removeItem(at: added)
    let sawRemoval = waitUntil { docs?.children.contains { $0.name == "brand-new.md" } == false }
    check("expanded folder drops a deleted file", sawRemoval)

    // A symlink beside its target lists twice; both rows must survive, which
    // means identity cannot be the resolved path.
    let link = root.appendingPathComponent("AGENTS.md")
    try? FileManager.default.createSymbolicLink(
        at: link, withDestinationURL: root.appendingPathComponent("README.md"))
    workspace.refresh()  // re-reads the folder; toggling expansion alone does not
    workspace.flattenRows()
    let listed = workspace.rows.map { $0.node.name }
    check(
        "a symlink is listed alongside its target: \(listed)",
        listed.contains("AGENTS.md") && listed.contains("README.md"))
    let linkIds = workspace.rows.map(\.id)
    check("symlink and target have distinct row ids", Set(linkIds).count == linkIds.count)

    // The rendered rows are what SwiftUI iterates; ids must be unique even when
    // one added folder contains another, which puts the same file on screen twice.
    workspace.add(root.appendingPathComponent("docs"))
    let ids = workspace.rows.map(\.id)
    check(
        "row ids stay unique with overlapping roots (\(ids.count) rows)",
        Set(ids).count == ids.count)
    check("overlapping root is listed", workspace.roots.count == 2)

    workspace.roots.forEach { workspace.remove($0) }
    check("removing roots empties the sidebar", workspace.roots.isEmpty)
    check("removing roots empties the rows", workspace.rows.isEmpty)

    try? FileManager.default.removeItem(at: base)
}

print(failures == 0 ? "WORKSPACE TESTS PASSED" : "WORKSPACE TESTS FAILED")
exit(failures == 0 ? 0 : 1)
