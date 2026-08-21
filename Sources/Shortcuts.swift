import Foundation

/// One case per distinct thing a key can do.
///
/// Deliberately without associated values: the table below is the only place a
/// key is tied to a meaning, so an action stays a plain comparable token that
/// `ViewerView` can switch over exhaustively and `tools/test-shortcuts.swift`
/// can assert on.
enum ShortcutAction: String, CaseIterable {
    // Reading.
    case scrollHalfPageDown, scrollHalfPageUp
    case jumpToTop, jumpToBottom
    case nextHeading, previousHeading
    // Finding.
    case find
    // Panels and overlays.
    case toggleSidebar, toggleContents, toggleFrontMatter
    case toggleShortcutsHelp, dismissOverlay
    // File.
    case openFile, addFolder, reload, reloadRenderer, revealInFinder, copyDocument
    case printDocument
    // View.
    case zoomIn, zoomOut, zoomReset
    // App.
    case openSettings
}

/// One binding: a key, what it does, how to describe it, and who handles it.
struct Shortcut {
    /// A key as the reader presses it.
    ///
    /// The character is what the keystroke *produces* — `"G"`, not `"g"` plus a
    /// shift flag, and `"?"`, not shift-slash. Shift is the thing that turns one
    /// into the other, so recording it separately would record it twice; worse,
    /// it would break these bindings on every layout that does not put `?` and
    /// `/` where a US keyboard does.
    enum Key: Hashable {
        case char(Character)
        case escape
    }

    /// Command, option and control — the modifiers that leave the character
    /// alone. Shift changes it, so it lives in `Key` instead.
    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
    }

    /// A key plus its modifiers: what a keystroke reduces to, and what has to be
    /// unique across the whole table.
    struct Stroke: Hashable {
        let key: Key
        let modifiers: Modifiers
    }

    /// Who turns the keystroke into the action.
    enum Handler {
        /// `ShortcutMonitor`, from a local key-down monitor.
        case monitor
        /// A SwiftUI menu item, through its own `.keyboardShortcut`. Listed here
        /// so the help overlay can show it and so no binding exists outside this
        /// table; the monitor must leave it alone or it would fire twice.
        case menu
    }

    /// A section of the help overlay. The raw value is the heading.
    ///
    /// A binding that has a menu item is grouped by the menu it is in, so a
    /// reader who went looking in the menu bar first finds it under the same
    /// name here. `reading`, `finding` and `panels` are for the plain keys, which
    /// are in no menu; `finding` keeps ⌘F beside `/` because they are one action
    /// and an action has one group.
    enum Group: String, CaseIterable {
        case reading = "Reading"
        case finding = "Finding"
        case panels = "Panels"
        case file = "File"
        case edit = "Edit"
        case view = "View"
        case app = "App"
    }

    let key: Key
    let modifiers: Modifiers
    let action: ShortcutAction
    /// One short line for the help overlay. Every binding of the same action
    /// carries the same one — `tools/test-shortcuts.swift` pins that, because the
    /// overlay shows one row per action with all its keys on it.
    let title: String
    let group: Group
    let handledBy: Handler

    init(
        key: Key,
        modifiers: Modifiers = [],
        action: ShortcutAction,
        title: String,
        group: Group,
        handledBy: Handler
    ) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
        self.title = title
        self.group = group
        self.handledBy = handledBy
    }

    var stroke: Stroke { Stroke(key: key, modifiers: modifiers) }

    /// How the help overlay labels this binding — one key cap's worth of text.
    ///
    /// A modifier cannot be typed, so a combo has to spell itself out: `⇧⌘O`.
    /// A plain key is simply the character — "press G", "press ?" — which is how
    /// a reader thinks of it, and how vim has always written it down.
    var keyLabel: String {
        guard !modifiers.isEmpty else { return key.label }
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if key.isShifted { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        return label + key.label.uppercased()
    }
}

extension Shortcut.Key {
    var label: String {
        switch self {
        case .escape: return "esc"
        case .char(let character): return String(character)
        }
    }

    /// An uppercase letter is a letter with shift held down.
    var isShifted: Bool {
        guard case .char(let character) = self else { return false }
        return character.isLetter && character.isUppercase
    }
}

/// Everything a keystroke's meaning depends on, other than the keystroke.
///
/// A value rather than a set of lookups, so `Shortcuts.resolve` can be pure and
/// `tools/test-shortcuts.swift` can cover every combination without a window.
/// `ViewerView` builds it; `ShortcutMonitor` only passes it along.
struct KeyContext: Equatable {
    /// What is covering the document, if anything.
    enum Overlay: Equatable {
        case none, settings, frontMatter, help
    }

    /// The document window is where this keystroke landed. An open or print
    /// panel is a window of ours too, and typing a letter there is type-select.
    var windowIsKey = true
    /// A text field in the chrome has focus — the sidebar's search box. Its
    /// keystrokes are its own.
    var editingChromeText = false
    /// An input inside the page has focus — the find bar. The page reports this;
    /// see the `pageFocus` message in `web/src/viewer.js`.
    var pageInputFocused = false
    var overlay: Overlay = .none
}

/// The one table of every key binding in the app, and the rule for reading it.
enum Shortcuts {
    /// What the monitor should do with a keystroke.
    enum Disposition: Equatable {
        /// Run this, and consume the event.
        case perform(ShortcutAction)
        /// Consume the event and do nothing. Nothing is bound to it, and this is
        /// a reading window, so it should be ignored quietly.
        case swallow
        /// Leave it to the responder chain, untouched.
        case passThrough
    }

    /// Every binding there is. Menu items are here too: the help overlay renders
    /// from this list, so a binding missing from it is a binding nobody can find.
    static let all: [Shortcut] = [
        // Reading. Plain keys, borrowed from vim, and the reason this table exists.
        Shortcut(
            key: .char("j"), action: .scrollHalfPageDown,
            title: "Half a page down", group: .reading, handledBy: .monitor),
        Shortcut(
            key: .char("k"), action: .scrollHalfPageUp,
            title: "Half a page up", group: .reading, handledBy: .monitor),
        Shortcut(
            key: .char("g"), action: .jumpToTop,
            title: "Top of the document", group: .reading, handledBy: .monitor),
        Shortcut(
            key: .char("G"), action: .jumpToBottom,
            title: "End of the document", group: .reading, handledBy: .monitor),
        Shortcut(
            key: .char("n"), action: .nextHeading,
            title: "Next heading", group: .reading, handledBy: .monitor),
        Shortcut(
            key: .char("N"), action: .previousHeading,
            title: "Previous heading", group: .reading, handledBy: .monitor),

        // Finding.
        Shortcut(
            key: .char("/"), action: .find,
            title: "Find in document", group: .finding, handledBy: .monitor),
        Shortcut(
            key: .char("f"), modifiers: .command, action: .find,
            title: "Find in document", group: .finding, handledBy: .menu),

        // Panels. Each toggle gets a plain key, a bracket combo, and the menu
        // item it has always had.
        Shortcut(
            key: .char("h"), action: .toggleSidebar,
            title: "Toggle the sidebar", group: .panels, handledBy: .monitor),
        Shortcut(
            key: .char("["), modifiers: .command, action: .toggleSidebar,
            title: "Toggle the sidebar", group: .panels, handledBy: .monitor),
        Shortcut(
            key: .char("b"), modifiers: .command, action: .toggleSidebar,
            title: "Toggle the sidebar", group: .panels, handledBy: .menu),
        Shortcut(
            key: .char("l"), action: .toggleContents,
            title: "Toggle the contents panel", group: .panels, handledBy: .monitor),
        Shortcut(
            key: .char("]"), modifiers: .command, action: .toggleContents,
            title: "Toggle the contents panel", group: .panels, handledBy: .monitor),
        Shortcut(
            key: .char("o"), modifiers: [.command, .option], action: .toggleContents,
            title: "Toggle the contents panel", group: .panels, handledBy: .menu),

        // Edit — where the menu item for it actually is.
        Shortcut(
            key: .char("i"), modifiers: .command, action: .toggleFrontMatter,
            title: "Front matter", group: .edit, handledBy: .menu),

        // File.
        Shortcut(
            key: .char("o"), modifiers: .command, action: .openFile,
            title: "Open a file", group: .file, handledBy: .menu),
        Shortcut(
            key: .char("O"), modifiers: .command, action: .addFolder,
            title: "Add a folder to the sidebar", group: .file, handledBy: .menu),
        Shortcut(
            key: .char("r"), modifiers: .command, action: .reload,
            title: "Reload the document", group: .file, handledBy: .menu),
        Shortcut(
            key: .char("R"), modifiers: .command, action: .revealInFinder,
            title: "Reveal in Finder", group: .file, handledBy: .menu),
        Shortcut(
            key: .char("c"), modifiers: [.command, .option], action: .copyDocument,
            title: "Copy the document source", group: .file, handledBy: .menu),
        Shortcut(
            key: .char("p"), modifiers: .command, action: .printDocument,
            title: "Print", group: .file, handledBy: .menu),

        // View.
        Shortcut(
            key: .char("r"), modifiers: [.command, .option], action: .reloadRenderer,
            title: "Reload the renderer", group: .view, handledBy: .menu),
        Shortcut(
            key: .char("="), modifiers: .command, action: .zoomIn,
            title: "Zoom in", group: .view, handledBy: .menu),
        Shortcut(
            key: .char("-"), modifiers: .command, action: .zoomOut,
            title: "Zoom out", group: .view, handledBy: .menu),
        Shortcut(
            key: .char("0"), modifiers: .command, action: .zoomReset,
            title: "Actual size", group: .view, handledBy: .menu),

        // App.
        Shortcut(
            key: .char(","), modifiers: .command, action: .openSettings,
            title: "Settings", group: .app, handledBy: .menu),
        Shortcut(
            key: .char("?"), action: .toggleShortcutsHelp,
            title: "Keyboard shortcuts", group: .app, handledBy: .monitor),
        Shortcut(
            key: .escape, action: .dismissOverlay,
            title: "Close this overlay, or the find bar", group: .app, handledBy: .monitor),
    ]

    /// The keys that always reach the responder chain, whatever else is going on.
    ///
    /// Written as what *passes* rather than what gets swallowed, because the
    /// allowlist is the half a future reader has to be able to check. Everything
    /// here is a key AppKit, WebKit or the page acts on itself:
    ///
    /// - **space**, with or without shift, is how the page turns today.
    /// - **tab** and shift-tab move focus. Shift-tab arrives as its own
    ///   character, `NSBackTabCharacter`, not as tab plus a flag.
    /// - **return**, **enter**, **delete** and **backspace** belong to whatever
    ///   is in front of the reader.
    /// - **Escape** is bound, but only sometimes — when it is suppressed the
    ///   settings sheet's `onExitCommand` and the page's own listener need it, so
    ///   it must never be eaten on the way past.
    private static let passThroughCharacters: Set<Character> = [
        " ",  // space, and shift-space
        "\t",  // tab
        "\u{19}",  // shift-tab (NSBackTabCharacter)
        "\r",  // return
        "\n",  // newline
        "\u{3}",  // enter, on the numeric pad
        "\u{8}",  // backspace
        "\u{7f}",  // delete
    ]

    /// Cocoa's function-key range. The four arrows, page up and down, home, end,
    /// insert, help and F1 upwards all arrive as characters in here, so one range
    /// covers every one of them and cannot fall behind a key we did not think of.
    private static let functionKeyScalars: ClosedRange<UInt32> = 0xF700...0xF8FF

    /// Whether this key must be left alone.
    static func passesThrough(_ key: Shortcut.Key) -> Bool {
        guard case .char(let character) = key else { return true }  // Escape
        if passThroughCharacters.contains(character) { return true }
        // A multi-scalar character is a dead key or an emoji, not a shortcut.
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first
        else { return true }
        return functionKeyScalars.contains(scalar.value)
    }

    /// What to do with a keystroke: run something, drop it quietly, or pass it on.
    ///
    /// The quiet drop is the point. Nothing in `Sources/` implements `keyDown`,
    /// so a bare letter falls all the way through the responder chain and macOS
    /// beeps at it — which, in a window whose whole job is reading, is a bubble
    /// noise for touching the keyboard. The cost is that a *mistyped* shortcut
    /// now gives no feedback at all, which is the intended trade for a reader and
    /// is exactly why `passThroughCharacters` has to stay honest.
    static func disposition(
        key: Shortcut.Key, modifiers: Shortcut.Modifiers, context: KeyContext
    ) -> Disposition {
        if let action = resolve(key: key, modifiers: modifiers, context: context) {
            return .perform(action)
        }
        // Command and control still belong to the menus, the system and WebKit.
        guard modifiers.isDisjoint(with: [.command, .control]) else { return .passThrough }
        // Typing always wins, and a keystroke in another window is not ours.
        guard context.windowIsKey, !context.editingChromeText, !context.pageInputFocused
        else { return .passThrough }
        return passesThrough(key) ? .passThrough : .swallow
    }

    /// What a keystroke means right now, or `nil` if it means nothing here and
    /// belongs to the responder chain.
    ///
    /// Pure on purpose: no events, no windows, no view state, no globals. Every
    /// input is an argument, which is what makes the rules below testable.
    static func resolve(
        key: Shortcut.Key, modifiers: Shortcut.Modifiers, context: KeyContext
    ) -> ShortcutAction? {
        guard context.windowIsKey else { return nil }
        // Menu items own their own key equivalents. They are in the table for the
        // help overlay's sake; acting on them here would fire them twice.
        guard let shortcut = byStroke[Shortcut.Stroke(key: key, modifiers: modifiers)],
            shortcut.handledBy == .monitor
        else { return nil }

        // A combo carries its own intent: it cannot be typed into a field, and it
        // means the same thing whatever is on screen.
        guard modifiers.isEmpty else { return shortcut.action }

        // A plain key is a character before it is a command. If anything is
        // taking characters, the keystroke is theirs — Escape included, because
        // the page closes its own find bar on it.
        if context.editingChromeText || context.pageInputFocused { return nil }

        switch context.overlay {
        case .none:
            return shortcut.action
        case .help:
            // Only the two keys that get rid of it.
            switch shortcut.action {
            case .dismissOverlay, .toggleShortcutsHelp: return shortcut.action
            default: return nil
            }
        case .settings, .frontMatter:
            // Both dismiss themselves, Escape included.
            return nil
        }
    }

    /// The table indexed for lookup. Duplicate strokes would lose an entry
    /// silently here, so `tools/test-shortcuts.swift` asserts there are none.
    private static let byStroke: [Shortcut.Stroke: Shortcut] = Dictionary(
        all.map { ($0.stroke, $0) }, uniquingKeysWith: { first, _ in first })
}
