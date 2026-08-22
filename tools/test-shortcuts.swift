// Checks the shortcut table and the pure resolver: what every key means, what
// nothing means while something else is taking the keystroke, and that the table
// itself stays a table — no duplicate strokes, no untitled rows, no bindings the
// help overlay cannot describe.
import AppKit

var failures = 0
func check(_ label: String, _ condition: Bool) {
    print(condition ? "  ok   \(label)" : "  FAIL \(label)")
    if !condition { failures += 1 }
}

/// Shorthand: what this stroke means in this context.
func resolve(
    _ key: Shortcut.Key,
    _ modifiers: Shortcut.Modifiers = [],
    _ context: KeyContext = KeyContext()
) -> ShortcutAction? {
    Shortcuts.resolve(key: key, modifiers: modifiers, context: context)
}

// MARK: Every plain key, in a neutral context

// Written out by hand rather than read from the table: a test that derives its
// expectations from the thing it is testing cannot fail.
let plainKeys: [(key: Shortcut.Key, action: ShortcutAction)] = [
    (.char("j"), .scrollHalfPageDown),
    (.char("k"), .scrollHalfPageUp),
    (.char("g"), .jumpToTop),
    (.char("G"), .jumpToBottom),
    (.char("n"), .nextHeading),
    (.char("N"), .previousHeading),
    (.char("/"), .find),
    (.char("?"), .toggleShortcutsHelp),
    (.char("h"), .toggleSidebar),
    (.char("l"), .toggleContents),
    (.escape, .dismissOverlay),
]

for (key, action) in plainKeys {
    check("\(key.label) → \(action.rawValue)", resolve(key) == action)
}

let monitorPlainKeys = Shortcuts.all.filter { $0.handledBy == .monitor && $0.modifiers.isEmpty }
check(
    "the table holds exactly these \(plainKeys.count) plain keys (\(monitorPlainKeys.count))",
    monitorPlainKeys.count == plainKeys.count)

// MARK: The two combos we handle ourselves

check("⌘[ → goBack", resolve(.char("["), .command) == .goBack)
check("⌘] → goForward", resolve(.char("]"), .command) == .goForward)

// MARK: Menu items keep their own key equivalents

// Returning these would fire them twice — once here, once from the menu.
let menuStrokes: [(String, Shortcut.Key, Shortcut.Modifiers)] = [
    ("⌘B", .char("b"), .command),
    ("⌘O", .char("o"), .command),
    ("⇧⌘O", .char("O"), .command),
    ("⌥⌘O", .char("o"), [.command, .option]),
    ("⌘F", .char("f"), .command),
    ("⌘I", .char("i"), .command),
    ("⌘R", .char("r"), .command),
    ("⌥⌘R", .char("r"), [.command, .option]),
    ("⇧⌘R", .char("R"), .command),
    ("⌥⌘C", .char("c"), [.command, .option]),
    ("⌘P (Quick Open)", .char("p"), .command),
    ("⇧⌘P (Print)", .char("P"), .command),
    ("⌘,", .char(","), .command),
    ("⌘=", .char("="), .command),
    ("⌘-", .char("-"), .command),
    ("⌘0", .char("0"), .command),
]
for (name, key, modifiers) in menuStrokes {
    check("\(name) is left to its menu item", resolve(key, modifiers) == nil)
}

// MARK: Unbound keystrokes are left alone

check("q does nothing", resolve(.char("q")) == nil)
check("⌘Q is not ours", resolve(.char("q"), .command) == nil)
check("⌃J is not j", resolve(.char("j"), .control) == nil)
check("⌥j is not j", resolve(.char("j"), .option) == nil)

// MARK: While the chrome is taking text

let searching = KeyContext(editingChromeText: true)
for (key, _) in plainKeys {
    check(
        "\(key.label) is the search field's while it is being typed in",
        resolve(key, [], searching) == nil)
}
check("⌘[ still works while searching", resolve(.char("["), .command, searching) == .goBack)
check("⌘] still works while searching", resolve(.char("]"), .command, searching) == .goForward)

// MARK: While an input in the page has focus

let finding = KeyContext(pageInputFocused: true)
for (key, _) in plainKeys {
    check("\(key.label) is the find bar's while it has focus", resolve(key, [], finding) == nil)
}
// Not merely "does nothing": the page's own listener closes the find bar on
// Escape, and it never sees the key if this consumes it.
check("esc is not consumed when a page input has focus", resolve(.escape, [], finding) == nil)
check("⌘[ still works from the find bar", resolve(.char("["), .command, finding) == .goBack)
check("⌘] still works from the find bar", resolve(.char("]"), .command, finding) == .goForward)

// MARK: While the help overlay is up

let helping = KeyContext(overlay: .help)
check("esc closes the help overlay", resolve(.escape, [], helping) == .dismissOverlay)
check("? closes the help overlay", resolve(.char("?"), [], helping) == .toggleShortcutsHelp)
for (key, _) in plainKeys where key != .escape && key != .char("?") {
    check(
        "\(key.label) does nothing while the help overlay is up", resolve(key, [], helping) == nil)
}

// MARK: While the settings sheet or the front matter panel is up

for (name, overlay) in [
    ("settings sheet", KeyContext.Overlay.settings), ("front matter panel", .frontMatter),
] {
    let context = KeyContext(overlay: overlay)
    var acted: [String] = []
    for (key, _) in plainKeys where resolve(key, [], context) != nil {
        acted.append(key.label)
    }
    // Both dismiss themselves, Escape included, so none of these may be taken.
    check(
        "no plain key acts while the \(name) is up\(acted.isEmpty ? "" : " (got \(acted))")",
        acted.isEmpty)
}

// MARK: While one of our own panels owns the keystroke

let elsewhere = KeyContext(windowIsKey: false)
check("j does nothing when an open panel is key", resolve(.char("j"), [], elsewhere) == nil)
check("⌘] does nothing when an open panel is key", resolve(.char("]"), .command, elsewhere) == nil)

// MARK: Bare keys nothing is bound to, and the keys that must always get through

/// Shorthand: what the monitor would do with this stroke.
func disposition(
    _ key: Shortcut.Key,
    _ modifiers: Shortcut.Modifiers = [],
    _ context: KeyContext = KeyContext()
) -> Shortcuts.Disposition {
    Shortcuts.disposition(key: key, modifiers: modifiers, context: context)
}

check("j is performed", disposition(.char("j")) == .perform(.scrollHalfPageDown))
// Nothing in Sources implements keyDown, so a bare key that reaches the end of
// the responder chain makes macOS beep. In a reading window it should be quiet.
check("an unbound letter is swallowed rather than beeped at", disposition(.char("q")) == .swallow)
check("an unbound digit is swallowed", disposition(.char("7")) == .swallow)
check("an unbound punctuation key is swallowed", disposition(.char(";")) == .swallow)
check("⌥ alone does not save a key", disposition(.char("q"), .option) == .swallow)

// These are how AppKit, WebKit and the page navigate and edit. Swallowing any of
// them is a regression, and space in particular is how the page turns today.
// Shift-space is the same character as space; shift-tab is its own.
let mustPassThrough: [(String, Shortcut.Key)] = [
    ("space (and shift-space)", .char(" ")),
    ("tab", .char("\t")),
    ("shift-tab", .char("\u{19}")),
    ("return", .char("\r")),
    ("enter", .char("\u{3}")),
    ("delete", .char("\u{7f}")),
    ("backspace", .char("\u{8}")),
    ("up arrow", .char("\u{F700}")),
    ("down arrow", .char("\u{F701}")),
    ("left arrow", .char("\u{F702}")),
    ("right arrow", .char("\u{F703}")),
    ("page up", .char("\u{F72C}")),
    ("page down", .char("\u{F72D}")),
    ("home", .char("\u{F729}")),
    ("end", .char("\u{F72B}")),
    ("F1", .char("\u{F704}")),
    ("F12", .char("\u{F70F}")),
]
for (name, key) in mustPassThrough {
    check("\(name) passes through", disposition(key) == .passThrough)
}

// Anything with command or control on it still belongs to the menus, the system
// and WebKit, bound here or not.
check("an unbound ⌘ combo passes through", disposition(.char("q"), .command) == .passThrough)
check("an unbound ⌃ combo passes through", disposition(.char("q"), .control) == .passThrough)
check(
    "⌘⌥ on an unbound key passes through",
    disposition(.char("q"), [.command, .option]) == .passThrough)

// Escape is bound, but only sometimes. When it is suppressed it has to reach the
// settings sheet's onExitCommand and the page's own listener.
check(
    "esc passes through when it is not ours",
    disposition(.escape, [], KeyContext(overlay: .settings)) == .passThrough)
check("esc passes through from a page input", disposition(.escape, [], finding) == .passThrough)

// Typing always wins: nothing at all is swallowed while a field has the keyboard.
for (name, context) in [("the search field", searching), ("a page input", finding)] {
    var swallowed: [String] = []
    for key in mustPassThrough.map(\.1) + [.char("q"), .char("j"), .char("?"), .escape] {
        if disposition(key, [], context) == .swallow { swallowed.append(key.label) }
    }
    check(
        "nothing is swallowed while \(name) has the keyboard\(swallowed.isEmpty ? "" : " (got \(swallowed))")",
        swallowed.isEmpty)
}

check(
    "nothing is swallowed when another window is key",
    disposition(.char("q"), [], elsewhere) == .passThrough)

// MARK: Caps Lock

// Caps Lock is not one of the modifiers AppKit strips out of
// charactersIgnoringModifiers — it changes the character itself. So with the lock
// on, `j` used to arrive as `"J"`, match nothing and be swallowed in silence,
// while `g` and `n` arrived as `G` and `N` and did the opposite of what was
// pressed. Shift is what the table means by an uppercase letter, so with the lock
// on the case has to come from the shift flag.
MainActor.assumeIsolated {
    /// What the monitor makes of this keystroke: the character AppKit would
    /// report with these flags, resolved through the real table.
    @MainActor
    func stroke(_ characters: String, _ flags: NSEvent.ModifierFlags) -> Shortcut.Stroke? {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 0)
        else { return nil }
        return ShortcutMonitor.stroke(for: event)
    }

    @MainActor
    func action(_ characters: String, _ flags: NSEvent.ModifierFlags) -> ShortcutAction? {
        guard let stroke = stroke(characters, flags) else { return nil }
        return Shortcuts.resolve(
            key: stroke.key, modifiers: stroke.modifiers, context: KeyContext())
    }

    // A key bound lowercase. With Caps Lock on the character arrives uppercased,
    // and it still has to be the lowercase binding.
    check("caps lock on, j → scrollHalfPageDown", action("J", [.capsLock]) == .scrollHalfPageDown)
    check("caps lock on, n → nextHeading", action("N", [.capsLock]) == .nextHeading)
    check("caps lock on, g → jumpToTop", action("G", [.capsLock]) == .jumpToTop)

    // A key bound uppercase. Shift is what makes it uppercase, lock or no lock:
    // with the lock on, shift-g arrives *lowercased* from AppKit.
    check(
        "caps lock on, shift-g → jumpToBottom", action("g", [.capsLock, .shift]) == .jumpToBottom)
    check(
        "caps lock on, shift-n → previousHeading",
        action("n", [.capsLock, .shift]) == .previousHeading)
    // And the plain, unlocked cases are untouched.
    check("caps lock off, j → scrollHalfPageDown", action("j", []) == .scrollHalfPageDown)
    check("caps lock off, G → jumpToBottom", action("G", []) == .jumpToBottom)

    // Only letters are re-cased. `?` is shift-slash on a US layout and Caps Lock
    // does nothing to it, so it must arrive exactly as AppKit reported it.
    check(
        "caps lock on, ? is still ?",
        action("?", [.capsLock, .shift]) == .toggleShortcutsHelp)
    check("caps lock on, / is still /", action("/", [.capsLock]) == .find)
    check(
        "caps lock on, esc is still esc",
        stroke("\u{1b}", [.capsLock])?.key == Shortcut.Key.escape)
    // A combo keeps its modifiers through the re-casing.
    check(
        "caps lock on, ⌘] is still ⌘]",
        action("]", [.capsLock, .command]) == .goForward)
}

// MARK: The table is a table

let strokes = Shortcuts.all.map(\.stroke)
check(
    "no two entries share a (key, modifiers) pair (\(strokes.count) entries)",
    Set(strokes).count == strokes.count)

let untitled = Shortcuts.all.filter {
    $0.title.trimmingCharacters(in: .whitespaces).isEmpty
}
check(
    "every entry has a help title\(untitled.isEmpty ? "" : " (\(untitled.count) without)")",
    untitled.isEmpty)

let emptyGroups = Shortcut.Group.allCases.filter { group in
    !Shortcuts.all.contains { $0.group == group }
}
check(
    "every group has entries\(emptyGroups.isEmpty ? "" : " (empty: \(emptyGroups.map(\.rawValue)))")",
    emptyGroups.isEmpty)

let unbound = ShortcutAction.allCases.filter { action in
    !Shortcuts.all.contains { $0.action == action }
}
check(
    "every action has a key\(unbound.isEmpty ? "" : " (unbound: \(unbound.map(\.rawValue)))")",
    unbound.isEmpty)

// The overlay draws one row per action with all its keys on it, so the bindings
// of one action have to agree about what to call it and where to put it.
var described: [ShortcutAction: (title: String, group: Shortcut.Group)] = [:]
var disagreements: [String] = []
for shortcut in Shortcuts.all {
    if let first = described[shortcut.action] {
        if first.title != shortcut.title || first.group != shortcut.group {
            disagreements.append(shortcut.action.rawValue)
        }
    } else {
        described[shortcut.action] = (shortcut.title, shortcut.group)
    }
}
check(
    "bindings of one action share a title and a group\(disagreements.isEmpty ? "" : " (\(disagreements))")",
    disagreements.isEmpty)

// MARK: How the overlay labels a key

let labels: [(Shortcut.Key, Shortcut.Modifiers, String)] = [
    (.char("j"), [], "j"),
    (.char("G"), [], "G"),
    (.char("?"), [], "?"),
    (.escape, [], "esc"),
    (.char("["), .command, "⌘["),
    (.char("b"), .command, "⌘B"),
    (.char("O"), .command, "⇧⌘O"),
    (.char("o"), [.command, .option], "⌥⌘O"),
]
for (key, modifiers, expected) in labels {
    let shortcut = Shortcut(
        key: key, modifiers: modifiers, action: .find, title: "x", group: .app,
        handledBy: .monitor)
    check("\(expected) is labelled \"\(shortcut.keyLabel)\"", shortcut.keyLabel == expected)
}

print(failures == 0 ? "SHORTCUT TESTS PASSED" : "SHORTCUT TESTS FAILED")
exit(failures == 0 ? 0 : 1)
