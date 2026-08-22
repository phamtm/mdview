// Checks that the key monitor is actually *placed* right, which the pure
// resolver cannot: that a keystroke meant for a text field still reaches it,
// that one meant for us never reaches the responder chain, and that anything we
// do not know passes straight through (an event we swallow gets no beep, but it
// also gets no typing).
//
// No accessibility permission needed: the window is our own, offscreen and
// borderless, and events go in through NSApp.sendEvent — which is where local
// monitors run.
import AppKit

var failures = 0
func check(_ label: String, _ condition: Bool) {
    print(condition ? "  ok   \(label)" : "  FAIL \(label)")
    if !condition { failures += 1 }
}

/// A borderless window will not take focus without this, and without focus the
/// text field never installs its field editor and never takes a letter.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Stands in for the document: something focusable that is not a text field, and
/// that says what reached it.
final class Recorder: NSView {
    var keys: [String] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        keys.append(event.charactersIgnoringModifiers ?? "?")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)  // no Dock icon for a test

    let window = KeyableWindow(
        contentRect: NSRect(x: -9000, y: -9000, width: 320, height: 90),
        styleMask: [.borderless], backing: .buffered, defer: false)
    let field = NSTextField(frame: NSRect(x: 10, y: 50, width: 300, height: 24))
    let recorder = Recorder(frame: NSRect(x: 10, y: 10, width: 300, height: 24))
    window.contentView?.addSubview(field)
    window.contentView?.addSubview(recorder)
    window.makeKeyAndOrderFront(nil)

    var fired: [ShortcutAction] = []
    // The same context ViewerView builds, minus the flags a window cannot answer
    // for. `isEditingText` is the shipping helper, not a copy of it.
    let monitor = ShortcutMonitor(
        context: { KeyContext(editingChromeText: KeyContext.isEditingText(in: window)) },
        perform: { fired.append($0) })

    func send(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)
        else {
            print("  FAIL could not synthesise a key event")
            failures += 1
            return
        }
        NSApp.sendEvent(event)
    }

    // MARK: With the search field focused, j is a letter

    check("the text field took focus", window.makeFirstResponder(field))
    check("focus reads as chrome text editing", KeyContext.isEditingText(in: window))
    send("j", keyCode: 38)
    check("j reached the text field (got \"\(field.stringValue)\")", field.stringValue == "j")
    check("j fired no action while typing (fired \(fired))", fired.isEmpty)

    // A combo cannot be typed, so it still belongs to us.
    send("]", keyCode: 30, flags: .command)
    check("⌘] still fired while typing", fired == [.goForward])
    check("⌘] left the text field alone", field.stringValue == "j")

    // An unbound letter is swallowed elsewhere, to stop the beep — but never
    // here, or the search field would drop half the alphabet.
    send("q", keyCode: 12)
    check("q reached the text field too (got \"\(field.stringValue)\")", field.stringValue == "jq")

    // MARK: With focus anywhere else, j is a shortcut

    fired = []
    check("the recorder took focus", window.makeFirstResponder(recorder))
    check("focus no longer reads as text editing", !KeyContext.isEditingText(in: window))
    send("j", keyCode: 38)
    check("j fired half-a-page-down (fired \(fired))", fired == [.scrollHalfPageDown])
    check(
        "j was consumed rather than passed on (chain saw \(recorder.keys))",
        recorder.keys.isEmpty)

    // MARK: An unbound bare key is dropped quietly rather than beeped at

    fired = []
    recorder.keys = []
    send("q", keyCode: 12)
    check("q fired nothing", fired.isEmpty)
    check(
        "q was swallowed, so nothing beeps at it (chain saw \(recorder.keys))",
        recorder.keys.isEmpty)

    // MARK: But the keys the app and the page navigate with still get through

    recorder.keys = []
    send(" ", keyCode: 49)
    check("space fired nothing", fired.isEmpty)
    check(
        "space reached the responder chain — it is how the page turns (saw \(recorder.keys))",
        recorder.keys == [" "])

    _ = monitor  // keep it installed for the whole run
}

print(failures == 0 ? "KEY DELIVERY TESTS PASSED" : "KEY DELIVERY TESTS FAILED")
exit(failures == 0 ? 0 : 1)
