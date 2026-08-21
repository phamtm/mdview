// Samples a panel's *rendered* width while it opens and closes, once per path
// that can toggle it, and once for a drag of its seam.
//
// The point is to tell an animated toggle from an unanimated one in numbers: an
// animated one passes through intermediate widths, an unanimated one goes from
// 258 to 0 between two consecutive samples. This is what caught the titlebar
// buttons not sliding while the keys did — see the `.animation` modifiers in
// Sources/ViewerLayout.swift.
//
// Two of the three paths, deliberately. The key monitor only fires while the
// window is key, and a bare executable cannot activate itself, so `h` and `⌘[`
// cannot be driven from here. They were never the broken ones: the animation is
// now declared on the view, so it cannot differ by caller.
import AppKit
import SwiftUI
import WebKit

var failures = 0
func check(_ label: String, _ condition: Bool) {
    print(condition ? "  ok   \(label)" : "  FAIL \(label)")
    if !condition { failures += 1 }
}

/// A borderless window takes no clicks unless it can become key.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

let windowWidth = 1040.0
let windowHeight = 700.0

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    Typeface.register()
    UserDefaults.standard.set(true, forKey: "sidebarVisible")
    UserDefaults.standard.set(false, forKey: "outlineVisible")
    UserDefaults.standard.set(ViewerView.sidebarDefaultWidth, forKey: "sidebarWidth")
    UserDefaults.standard.set(ViewerView.outlineDefaultWidth, forKey: "outlineWidth")

    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mdview-anim")
    try? FileManager.default.removeItem(at: base)
    try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let doc = base.appendingPathComponent("notes.md")
    try! "# Notes\n\nSome text.\n\n## Second\n\nMore text.\n"
        .write(to: doc, atomically: true, encoding: .utf8)

    let workspace = WorkspaceModel.shared
    workspace.roots.forEach { workspace.remove($0) }
    workspace.add(base)
    DocumentModel.shared.open(doc)

    let root = ViewerView()
        .environmentObject(DocumentModel.shared)
        .environmentObject(WorkspaceModel.shared)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
    let window = KeyableWindow(
        contentRect: hosting.frame, styleMask: [.borderless],
        backing: .buffered, defer: false)
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderBack(nil)

    func pump(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func findWebView(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews {
            if let found = findWebView(sub) { return found }
        }
        return nil
    }

    pump(1.5)
    hosting.layoutSubtreeIfNeeded()
    guard let web = findWebView(hosting) else {
        print("  FAIL no web view in the hierarchy")
        exit(1)
    }

    /// The panels and the document share their seams, and the web view is a real
    /// NSView whose frame SwiftUI sets on every pass — so its own edges are the
    /// two panels' rendered widths.
    func documentFrame() -> NSRect { web.convert(web.bounds, to: hosting) }
    func sidebarWidth() -> Double { Double(documentFrame().minX) }
    func contentsWidth() -> Double { windowWidth - Double(documentFrame().maxX) }

    /// Samples every 10ms for 0.3s after `trigger`, which is longer than the 0.2s
    /// the toggle animates for.
    func trace(_ label: String, _ measure: () -> Double, _ trigger: () -> Void) -> [Double] {
        hosting.layoutSubtreeIfNeeded()
        var widths = [measure()]
        trigger()
        for _ in 0..<30 {
            pump(0.01)
            widths.append(measure())
        }
        let shown = widths.map { String(format: "%.0f", $0) }.joined(separator: " ")
        print("  \(label): \(shown)")
        return widths
    }

    /// How many samples sit strictly between the two ends — the evidence of an
    /// animation. Zero means the width jumped in a single frame.
    func intermediates(_ widths: [Double]) -> Int {
        guard let first = widths.first, let last = widths.last else { return 0 }
        let low = min(first, last) + 1, high = max(first, last) - 1
        return widths.filter { $0 > low && $0 < high }.count
    }

    func mouse(_ type: NSEvent.EventType, x: Double, y: Double) {
        guard
            let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        // Sent, not posted: nothing here runs NSApp's own event loop, so a posted
        // event would sit in the queue forever.
        NSApp.sendEvent(event)
    }

    func click(x: Double, y: Double) {
        mouse(.leftMouseDown, x: x, y: y)
        mouse(.leftMouseUp, x: x, y: y)
    }

    // Window coordinates are bottom-up; the band's buttons are centred at 26.
    let bandY = windowHeight - 26.0
    // The sidebar toggle sits at the inner edge of the left zone: the zone's
    // width, less its 13.8 inset, less half the 26pt square.
    func sidebarToggleX(zone: Double) -> Double { zone - 13.8 - IconButton.size / 2 }
    // The contents button is the middle of the three in the trailing cluster:
    // 13.8 to the window edge, the settings square, then --space-2.
    let contentsToggleX = windowWidth - 13.8 - IconButton.size - 9.2 - IconButton.size / 2

    print("==> sidebar width through a toggle (10ms samples, 258 open / 0 shut)")
    let sidebarButtonShut = trace(
        "button  close", sidebarWidth,
        { click(x: sidebarToggleX(zone: ViewerView.sidebarDefaultWidth), y: bandY) })
    check("the button shut the sidebar", sidebarButtonShut.last! < 1)
    let sidebarButtonOpen = trace(
        "button  open ", sidebarWidth,
        { click(x: sidebarToggleX(zone: ViewerView.collapsedZone), y: bandY) })
    check("the button opened it again", sidebarButtonOpen.last! > 200)

    func toggleSidebar() {
        NotificationCenter.default.post(name: .mdvToggleSidebar, object: nil)
    }
    let sidebarMenuShut = trace("menu ⌘B close", sidebarWidth, toggleSidebar)
    check("the menu path shut the sidebar", sidebarMenuShut.last! < 1)
    let sidebarMenuOpen = trace("menu ⌘B open ", sidebarWidth, toggleSidebar)
    check("the menu path opened it again", sidebarMenuOpen.last! > 200)

    print("==> contents panel width through a toggle (244 open / 0 shut)")
    let contentsButtonOpen = trace(
        "button  open ", contentsWidth, { click(x: contentsToggleX, y: bandY) })
    check("the button opened the contents panel", contentsButtonOpen.last! > 200)
    let contentsButtonShut = trace(
        "button  close", contentsWidth, { click(x: contentsToggleX, y: bandY) })
    check("the button shut it again", contentsButtonShut.last! < 1)

    func toggleContents() {
        NotificationCenter.default.post(name: .mdvToggleOutline, object: nil)
    }
    let contentsMenuOpen = trace("menu ⌥⌘O open ", contentsWidth, toggleContents)
    check("the menu path opened the contents panel", contentsMenuOpen.last! > 200)
    let contentsMenuShut = trace("menu ⌥⌘O close", contentsWidth, toggleContents)
    check("the menu path shut it again", contentsMenuShut.last! < 1)

    let toggles = [
        ("sidebar button close", sidebarButtonShut),
        ("sidebar button open", sidebarButtonOpen),
        ("sidebar menu close", sidebarMenuShut),
        ("sidebar menu open", sidebarMenuOpen),
        ("contents button open", contentsButtonOpen),
        ("contents button close", contentsButtonShut),
        ("contents menu open", contentsMenuOpen),
        ("contents menu close", contentsMenuShut),
    ]
    print("==> every path slides: intermediate samples (0 would be a jump)")
    for (label, widths) in toggles {
        check("\(label) slid through \(intermediates(widths)) widths", intermediates(widths) > 4)
    }

    // MARK: And a resize does not

    // The other half of the fix: the animation is keyed on the visibility flags
    // only. Keyed on the width as well — or reinstated as a blanket
    // `withAnimation` — the panel would chase the pointer a fifth of a second
    // behind it, which is the regression a reader notices first.
    print("==> resizing writes the width without animating it")
    // A synthesised event drives a SwiftUI `Button` but not a SwiftUI
    // `DragGesture` — measured: NSGestureRecognizer wants something
    // `NSEvent.mouseEvent` does not carry — so the drag itself cannot be played
    // back here. What can be is the write it makes: `ResizeHandle` is bound to
    // `sidebarWidth`, and setting that is the whole of its effect on the layout.
    //
    // This is the half of the fix that is easy to undo: key the `.animation` on
    // the width as well as the flags, or wrap the handle's write in
    // `withAnimation`, and the panel chases the pointer a fifth of a second
    // behind it.
    var tracked: [(Double, Double)] = []
    // 60pt at a time, so an eased 0.2s slide would be unmistakable: 20ms in it is
    // barely a fifth of the way, some 45pt short of where it was asked for.
    for width in stride(from: 318.0, through: 438.0, by: 60.0) {
        UserDefaults.standard.set(width, forKey: "sidebarWidth")
        pump(0.02)
        tracked.append((width, sidebarWidth()))
    }
    for (asked, drawn) in tracked {
        check(
            "width set to \(Int(asked)): drawn at \(Int(drawn)) 20ms later",
            abs(drawn - asked) < 2)
    }

    print(failures == 0 ? "PANEL ANIMATION TESTS PASSED" : "PANEL ANIMATION TESTS FAILED")
    exit(failures == 0 ? 0 : 1)
}
