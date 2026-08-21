import AppKit
import SwiftUI

/// Turns key-down events into `ShortcutAction`s, and does nothing else.
///
/// It owns no application state: `context` is asked afresh at every keystroke
/// and `perform` is handed whatever resolved. `ViewerView` supplies both,
/// because that is where the overlay flags and the panel toggles actually live.
@MainActor
final class ShortcutMonitor {
    private let context: () -> KeyContext
    private let perform: (ShortcutAction) -> Void
    private var monitor: Any?

    init(context: @escaping () -> KeyContext, perform: @escaping (ShortcutAction) -> Void) {
        self.context = context
        self.perform = perform
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Not `self?.handle(event) ?? event`: optional chaining flattens, so
            // that spelling turns "consumed" into "passed on" and nothing is ever
            // swallowed. tools/test-key-delivery.swift is what noticed.
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Returning `nil` swallows the event; returning it passes it on.
    ///
    /// Which of the two a keystroke gets is entirely `Shortcuts.disposition`'s
    /// decision — the policy lives next to the table, not in here.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let stroke = ShortcutMonitor.stroke(for: event) else { return event }
        switch Shortcuts.disposition(
            key: stroke.key, modifiers: stroke.modifiers, context: context())
        {
        case .perform(let action):
            perform(action)
            return nil
        case .swallow:
            return nil
        case .passThrough:
            return event
        }
    }

    /// The one place an AppKit event becomes the table's vocabulary.
    ///
    /// `charactersIgnoringModifiers` drops command and option but keeps shift, so
    /// it already *is* the character `Shortcut.Key` stores — `"G"` for shift-g,
    /// `"?"` for shift-slash, on whatever layout the reader has. Function keys
    /// and the numeric pad are left in the flags and ignored: a keystroke we
    /// cannot name must not be claimed.
    ///
    /// Caps Lock is the exception, because it is not in the part AppKit strips —
    /// it changes the character itself. With it on, `j` arrives as `"J"`, so
    /// `j k h l` matched nothing and were swallowed in silence while `g` and `n`
    /// arrived as `G` and `N` and did the opposite of what was pressed (bottom of
    /// the document; backwards a heading). Shift is what the table means by an
    /// uppercase letter, so with Caps Lock on the case is taken from the shift
    /// flag and the lock is ignored.
    static func stroke(for event: NSEvent) -> Shortcut.Stroke? {
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
            let character = characters.first
        else { return nil }
        var modifiers: Shortcut.Modifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        let pressed = unlocked(character, flags: event.modifierFlags)
        return Shortcut.Stroke(
            key: pressed == "\u{1b}" ? .escape : .char(pressed), modifiers: modifiers)
    }

    /// The letter as the reader's fingers typed it, Caps Lock discounted.
    ///
    /// Only letters, and only while the lock is on: everything else — digits,
    /// punctuation, whichever character a non-Latin layout produces — is left
    /// exactly as AppKit reported it. A case change that is not a single
    /// character (Turkish dotless i, German ß) is left alone too, since it can no
    /// longer be a key.
    private static func unlocked(_ character: Character, flags: NSEvent.ModifierFlags) -> Character
    {
        guard flags.contains(.capsLock), character.isLetter else { return character }
        let wanted =
            flags.contains(.shift)
            ? String(character).uppercased() : String(character).lowercased()
        guard wanted.count == 1, let single = wanted.first else { return character }
        return single
    }
}

extension KeyContext {
    /// True while `window` is taking text — the sidebar's search field, which
    /// edits through the window's field editor, an `NSTextView`.
    ///
    /// Read from the responder chain rather than tracked in SwiftUI because an
    /// `NSTextField` starts editing before it says anything:
    /// `controlTextDidBeginEditing` fires on the *first keystroke*, which is
    /// exactly the one that must not be swallowed.
    static func isEditingText(in window: NSWindow?) -> Bool {
        switch window?.firstResponder {
        case is NSTextView, is NSTextField: return true
        default: return false
        }
    }
}

/// Keeps the monitor alive for as long as the view is on screen, and hands it
/// fresh closures on every SwiftUI update so it can never read a stale flag.
///
/// A representable rather than `.onAppear`, for the same reason `WindowChrome`
/// is one: `updateNSView` runs on every pass, which is precisely when the
/// closures need replacing. It also supplies the one thing `ViewerView` cannot
/// know — which window it ended up in.
private struct ShortcutKeys: NSViewRepresentable {
    let keyContext: (NSWindow?) -> KeyContext
    let perform: (ShortcutAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(in: view, keyContext: keyContext, perform: perform)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.install(in: view, keyContext: keyContext, perform: perform)
    }

    @MainActor
    final class Coordinator {
        private var monitor: ShortcutMonitor?
        private var keyContext: (NSWindow?) -> KeyContext = { _ in KeyContext() }
        private var perform: (ShortcutAction) -> Void = { _ in }

        /// Replaces the closures, and installs the monitor the first time. The
        /// monitor goes away with this coordinator, which goes away with the view.
        func install(
            in view: NSView,
            keyContext: @escaping (NSWindow?) -> KeyContext,
            perform: @escaping (ShortcutAction) -> Void
        ) {
            self.keyContext = keyContext
            self.perform = perform
            guard monitor == nil else { return }
            monitor = ShortcutMonitor(
                context: { [weak self, weak view] in
                    self?.keyContext(view?.window) ?? KeyContext()
                },
                perform: { [weak self] action in self?.perform(action) })
        }
    }
}

extension View {
    /// Installs the app's key monitor for as long as this view is on screen.
    ///
    /// `keyContext` is called at the moment of the keystroke and given the window
    /// this view is in, so nothing it reports can be out of date.
    func shortcutKeys(
        keyContext: @escaping (NSWindow?) -> KeyContext,
        perform: @escaping (ShortcutAction) -> Void
    ) -> some View {
        background(ShortcutKeys(keyContext: keyContext, perform: perform))
    }
}
