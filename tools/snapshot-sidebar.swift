// Renders SidebarView offscreen against a throwaway folder tree, so the sidebar
// can be eyeballed without a screen recording permission.
// Usage: swift-compiled as main.swift; args: <out.png> [light|dark]
import AppKit
import SwiftUI

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "sidebar.png"
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "light"

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)

// A small demo tree: two roots, nesting, and a non-markdown file to prove filtering.
let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
    "mdview-sidebar-demo")
try? FileManager.default.removeItem(at: base)
let files = [
    "platform/README.md", "platform/CHANGELOG.md",
    "platform/docs/architecture.md", "platform/docs/onboarding.md",
    "platform/docs/api/endpoints.md", "platform/docs/api/errors.md",
    "platform/src/main.swift",
    "notes/journal.md", "notes/ideas.md", "notes/archive/2025.md",
]
for path in files {
    let url = base.appendingPathComponent(path)
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try! "# \(url.lastPathComponent)\n".write(to: url, atomically: true, encoding: .utf8)
}

// Top-level code isn't main-actor isolated, but we are on the main thread here.
MainActor.assumeIsolated {
    let workspace = WorkspaceModel.shared
    workspace.roots.forEach { workspace.remove($0) }
    workspace.add(base.appendingPathComponent("platform"))
    workspace.add(base.appendingPathComponent("notes"))

    // Expand a nested folder and open a file so nesting and selection both show.
    if let platform = workspace.roots.first,
        let docs = platform.children.first(where: { $0.name == "docs" })
    {
        docs.isExpanded = true
        if let api = docs.children.first(where: { $0.name == "api" }) { api.isExpanded = true }
    }
    DocumentModel.shared.open(base.appendingPathComponent("platform/docs/onboarding.md"))

    // Shown beside a mock document pane: the point of these styles is the boundary
    // between sidebar and content, which isn't visible in a sidebar-only capture.
    struct DocumentPaneMock: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 13) {
                Text("Onboarding")
                    .font(.system(size: 25, weight: .bold))
                    .padding(.bottom, 2)
                ForEach([0.95, 0.88, 0.93, 0.62], id: \.self) { width in
                    line(width)
                }
                Text("Getting set up")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 10)
                ForEach([0.9, 0.84, 0.5], id: \.self) { width in
                    line(width)
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(34)
            .background(Color(nsColor: .textBackgroundColor))
        }

        private func line(_ fraction: CGFloat) -> some View {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: geo.size.width * fraction, height: 9)
            }
            .frame(height: 9)
        }
    }

    let root = HStack(spacing: 0) {
        SidebarView(workspace: workspace, doc: DocumentModel.shared)
            .frame(width: 248)
        DocumentPaneMock()
    }
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 830, height: 430)

    let window = NSWindow(
        contentRect: hosting.frame, styleMask: [.borderless],
        backing: .buffered, defer: false)
    window.appearance = NSApp.appearance
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderBack(nil)

    // Let SwiftUI lay out and the list load its rows before capturing.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("could not make bitmap"); app.terminate(nil); return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: out))
            print("wrote \(out) — rows: \(workspace.rows.count)")
        }
        app.terminate(nil)
    }
}

app.run()
