// Renders the whole window offscreen — sidebar, header and the real rendered
// document — so the layout can be checked without screen-recording permission.
// Usage: <out.png> [light|dark]
import AppKit
import SwiftUI
import WebKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "window.png"
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "light"

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)

/// The capture excludes window decorations, so these stand in for the real
/// traffic lights and keep the top-left spacing honest.
struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 9) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34),
                     Color(red: 1, green: 0.74, blue: 0.18),
                     Color(red: 0.15, green: 0.78, blue: 0.25)], id: \.self) { colour in
                Circle().fill(colour).frame(width: 14, height: 14)
            }
        }
        .padding(.leading, 9)
        .padding(.top, 9)
    }
}

MainActor.assumeIsolated {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mdview-window-demo")
    try? FileManager.default.removeItem(at: base)
    let notes = base.appendingPathComponent("notes")
    let docs = notes.appendingPathComponent("docs")
    try! FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    for name in ["ideas.md", "journal.md"] {
        try! "# \(name)\n".write(to: notes.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try! "# api.md\n".write(to: docs.appendingPathComponent("api.md"), atomically: true, encoding: .utf8)

    let readme = notes.appendingPathComponent("onboarding.md")
    try! """
    ---
    title: Onboarding
    date: 2026-08-18
    tags: [setup, macos]
    ---

    Getting a new machine ready takes about twenty minutes. Work through the
    sections in order — each one assumes the previous is done.

    ## Getting set up

    > [!NOTE]
    > You will need admin rights for the first two steps.

    Install the command line tools, then check the version:

    ```bash
    xcode-select --install
    swiftc --version
    ```

    | Step | Owner | Done |
    | --- | --- | --: |
    | Tools | you | yes |
    | Access | IT | no |
    """.write(to: readme, atomically: true, encoding: .utf8)

    let workspace = WorkspaceModel.shared
    workspace.roots.forEach { workspace.remove($0) }
    let reference = base.appendingPathComponent("reference")
    try! FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
    for name in ["style-guide.md", "glossary.md"] {
        try! "# \(name)\n".write(to: reference.appendingPathComponent(name),
                                  atomically: true, encoding: .utf8)
    }
    workspace.add(notes)
    workspace.add(reference)
    DocumentModel.shared.open(readme)

    let root = ViewerView()
        .environmentObject(DocumentModel.shared)
        .environmentObject(WorkspaceModel.shared)
        .overlay(alignment: .topLeading) { TrafficLights() }

    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 1040, height: 700)
    // Borderless on purpose: in a titled window, cacheDisplay() silently drops
    // the sidebar's scroll subtree and it captures as empty black. This harness
    // is for layout and styling; the real window's titlebar state is checked by
    // tools/check-window-chrome.sh, which asks the running app directly.
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.appearance = NSApp.appearance
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderBack(nil)

    /// WebKit renders out of process, so cacheDisplay() captures the chrome but
    /// leaves the document area empty. The web view is snapshotted separately
    /// and composited into place.
    func findWebView(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews {
            if let found = findWebView(sub) { return found }
        }
        return nil
    }

    func write(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: out))
        print("wrote \(out) (\(mode))")
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
        hosting.layoutSubtreeIfNeeded()
        let frameView = hosting
        print("sidebar rows: \(WorkspaceModel.shared.rows.count), roots: \(WorkspaceModel.shared.roots.map(\.name))")
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            print("no bitmap"); app.terminate(nil); return
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let composed = NSImage(size: frameView.bounds.size)
        composed.addRepresentation(rep)

        guard let web = findWebView(frameView) else {
            print("warning: no web view found, chrome only")
            write(composed)
            app.terminate(nil)
            return
        }
        // hosting is flipped (top-left origin), NSImage drawing is not.
        let inHosting = web.convert(web.bounds, to: frameView)
        let target = NSRect(x: inHosting.minX,
                            y: frameView.bounds.height - inHosting.maxY,
                            width: inHosting.width,
                            height: inHosting.height)
        let config = WKSnapshotConfiguration()
        config.rect = web.bounds
        config.snapshotWidth = NSNumber(value: Double(web.bounds.width))
        web.takeSnapshot(with: config) { image, error in
            if let error { print("web snapshot failed: \(error)") }
            if let image {
                composed.lockFocus()
                image.draw(in: target)
                composed.unlockFocus()
            }
            write(composed)
            app.terminate(nil)
        }
    }
}

app.run()
