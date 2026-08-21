# MDView design

## The spec lives in Claude Design

This app's look is specified by a Claude Design project, not by this file:

- **`Markdown Viewer.dc.html`** — project `bf2995a1-bb2b-4e8c-b27e-e70f3be0b0a0`.
  The app itself: the titlebar band, the library sidebar, the contents rail, the
  settings sheet, the three themes.
- **Classical** — project `713d313f-b0ac-4c37-8302-2d699caba821`, the design
  system it builds on. Its `styles.css` is the token source: the ramps, the
  spacing scale, the type pairing.

Read those before changing anything visual, and take real values from them rather
than inventing spacing or colour. This file records only **how** the spec is
implemented here, and where the two necessarily differ.

## The idea

Editorial. Serif type on a soft ground, justified columns, hairlines carrying the
structure of the page, and a single gold accent applied as **stroke and rule,
never fill**. Cards are bordered, buttons are outlined, photographs sit matted
like tipped-in plates. Nothing is bolder than semibold, and the bigger the type
the lighter it sets.

## Tokens

| | |
| --- | --- |
| Heading face | Cormorant Garamond (400 display, 600 interface) |
| Body face | Lora (400, 600, italic) |
| Neutral ramp | `#f8f4f4` `#eae7e7` `#d7d3d3` `#bab6b6` `#7d7979` `#444141` `#2d2b2b` |
| Accent ramp | `#fff3e4` `#ffe3bf` `#facb8d` `#e1ad66` `#c28d41` `#a06f24` `#5a3b0a` `#3a270d` |
| Spacing | 4.6 · 9.2 · 13.8 · 18.4 · 27.6 · 36.8 |
| Radius | 2 · 4 · 7 |

Three themes resolved from those ramps: **Paper** (near-white), **Vellum** (warm,
accent-tinted), **Colophon** (near-black). Chosen in the settings panel (`⌘,`);
"Follow System" picks Paper or Colophon by appearance.

### Sizing display type against body type

The two faces are not the same optical size at the same point size. Measured from
the files at 12.5pt: **Lora's x-height is 6.25, Cormorant's is 4.83** — 23%
smaller. The eye reads x-height as size, so mixed-case Cormorant set at the body's
point size looks a third too small, which is what made folder names in the sidebar
hard to read next to filenames.

So mixed-case chrome uses `Typeface.displayMatching(bodySize)`, which applies the
measured 1.295 ratio: folder rows are Cormorant at 16pt beside files in Lora at
12.5pt, and they read as equals. Labels **in caps** are governed by cap height
instead and need no correction — those still use `Typeface.display` directly.

The ratio fixes apparent size, not stroke weight, and below about 15pt it stops
being enough: Cormorant is a high-contrast face, so its hairlines thin out to
nothing at list size, worst of all light-on-dark. Asking for a heavier weight
makes it worse, not better — the stems thicken and the hairlines do not, which
widens the contrast that costs the legibility. So the contents panel sets its rows
in Lora and lets weight carry the hierarchy. Everything still on `displayMatching`
sits at 15pt or above, where the face holds.

## Layout

| Zone | Value |
| --- | --- |
| Titlebar band | 52pt, surface-coloured, hairline beneath |
| Band split | hairline at the sidebar's edge; traffic lights and the sidebar toggle sit left of it |
| Left zone, sidebar closed | 136.4pt = buttons (69) + `--space-6` + toggle (26) + inset (13.8) |
| Sidebar | 258pt default (drag 170–460), surface 62% over bg, hairline right edge |
| Sidebar row | 27pt, 16pt indent per level, 4pt radius |
| Contents panel | 244pt default (drag 160–460), same surface, hairline left edge |
| Document column | 700pt measure, body 17px (15 small, 19 large) |
| Column padding | 72pt top, 68pt left, 36.8pt right, 120pt bottom — the left side is wider so the text clears the tick rail |

**The traffic lights' vertical position is not ours to set** — macOS derives it
from the titlebar setup. Measured on macOS 26:

| Titlebar setup | Button centre | Titlebar height |
| --- | --: | --: |
| Hidden titlebar | 16 | 32 |
| + empty toolbar, `.unified` | 26 | 66 |
| `.unifiedCompact` | 20 | 40 |
| `.expanded` | 16 | 48 |

So the band is **52pt** and an empty unified toolbar is attached to the window:
that puts the buttons at 26, exactly half the band, and they sit centred. Nothing
is ever placed in that toolbar. Change the band height and the buttons stop being
centred — `tools/check-window-chrome.sh` asserts `buttonCentre=26` to catch it.

Horizontally they span x=9…69, which is what the left zone reserves. With the
sidebar closed that zone is sized from the scale rather than left to whatever a
spacer had spare — which was 11pt, and read as the toggle touching the buttons.

## How the two halves stay in step

The palette exists **twice**: `Resources/style.css` for the document, and
`Sources/Theme.swift` for the chrome AppKit draws. The duplication is deliberate —
two short readable tables beat a build step that syncs them, for an app this size —
but it means **a colour changed in one must be changed in the other.**

Implementation notes that are easy to trip over:

- **Three surfaces need the theme colour, not one.** The stylesheet paints the
  page, but AppKit paints the window frame and WebKit paints the area behind the
  page — which is what shows when you rubber-band past either end. Left as system
  colours, those two read as a black edge and a black overscroll band in Colophon.
  `tools/check-theme.sh` asks the running app for both and fails if they drift from
  the theme.
- **The window's appearance has to follow the theme, not the OS.** AppKit draws
  scrollers, carets and selections in the *system* tone, so Vellum under a dark
  macOS drew a white scroller knob on cream paper. `ViewerView` pins the window
  with `.preferredColorScheme` — nil for System, which must stay nil: `colorScheme`
  is how System resolves, so pinning it would freeze the app in whichever tone it
  launched in. `tools/check-window-chrome.sh` asserts the window's appearance
  matches the stored theme.
- **Scrollbars are the system's, deliberately.** Styling `::-webkit-scrollbar` in
  the page opts WebKit out of macOS overlay scrollbars, so the document carried a
  permanent grey bar that also stole 10px from the measure on every reflow. The
  skin is gone; `color-scheme` per theme is what tells WebKit which tone to draw
  the native bar in.
- **Fonts ship twice too.** The page loads woff2 (small, and all WebKit needs);
  the chrome needs real TTFs, because CoreText cannot register woff2. Both sit in
  `Resources/fonts/`, and neither can come from Google's CDN — the page's CSP
  blocks remote origins.
- **Mermaid cannot read the theme tokens directly.** Vellum and Colophon are built
  from `color-mix()`, which WebKit resolves to `color(srgb …)` — a syntax mermaid's
  colour parser rejects, and which silently killed every diagram in those two
  themes. Tokens are flattened to plain `rgb()` through a 1×1 canvas first, then
  the diagram is repainted as stroke-on-nothing.
- **A block drawing a tree gets `line-height: 1`, on the `pre` as well as the
  `code`.** Box-drawing characters only join up when the line box equals the glyph
  height; at the normal 1.7 leading the verticals break into dashes. Setting it on
  `code` alone does nothing — `code` is inline inside `pre`, so the pre's strut
  sets the line box. `web/src/viewer.js` tags such blocks `.ascii` by testing for
  U+2500–257F, and the render check asserts the leading matches the font size.
- **`body` is a flex column for one reason, and it is paint.** WebKit fills the
  gaps between a selection root's children out to *that root's* content box.
  `body` is a selection root; `.prose` is not (static position, visible overflow,
  no flex or grid parent). So selecting across two blocks painted the tint as
  full-window bands — 208px past the column on the left, 177px on the right,
  covering the centring margins and the column's own padding. A flex container
  has no block gaps to fill, so the tint hugs the line boxes instead. Nothing
  about layout changes: the same 39 `#doc` child rects, the same copied string,
  the same find matches — which is why the rule reads as cruft and invites
  deletion. Moving it to `.prose` does not work: that stops margins
  collapsing between blocks and the column reflows. It is screen-only, with
  `body { display: block }` inside `@media print`: nothing selects on paper, and
  WebKit is said to fragment flex containers badly across pages — untested here,
  because print cannot be measured headlessly, so that half is caution rather
  than a measurement.
  `pre` in `figure.code` remains its own selection root by virtue of
  `overflow-x: auto`, so selected code keeps full-line highlighting inside the
  block — that is wanted, not a leftover. `tools/snapshot.swift` shoots the page
  unselected and selected and `tools/check-render.py` asserts
  `selectionGutterPixels` is 0: the one pixel assertion in the suite, because
  computed style and `getClientRects()` are identical either way.
  It is not the cause of a panel slide looking rough either, which is the other
  thing it gets blamed for. A/B'd against `display: block` while the document's
  width was being animated: the paint catches up 13ms after a widen and 16ms
  after a narrow *both* ways, a forced layout after a resize costs 5.4ms median
  both ways, and the page is handed resize events at the same cadence both ways.
  What actually moves during a slide is the column's left edge — the measure is
  capped, so a wider window only re-centres the text — and that is
  `margin: 0 auto`, not this rule.
- **The page has one selection, and WebKit types into it — so a find match is
  not the selection.** `window.find()` was how a match was made visible without
  any highlighting of our own, and it cost the find bar every character after the
  first. The search moves the selection into the document; WebKit routes a typed
  character at the selection, not at `document.activeElement`; so the field went
  on reporting focus with its insertion point gone. The app then did the right
  thing with the next key — an input in the page has focus, so plain keys stand
  down and the keystroke is passed on — and it fell through a web view with
  nothing editable in it, which is the beep. Measured, not guessed: after one
  character `activeElement` is still `#findinput`, the selection sits in the
  matched heading, and the field never takes another letter.
  Refocusing the field after the search is the obvious fix and the wrong one:
  the selection comes back to the field and the match stops being visible —
  typing for an invisible search. So matches are `Range`s in `CSS.highlights`,
  painted by `::highlight(mdview-find)` and `::highlight(mdview-find-current)`
  in `Resources/style.css`, and the selection is never touched. Two consequences
  worth knowing: matching walks one text node at a time, so a match split by
  inline markup — the "down" of a bolded `mark**down**` — is not found, which
  `window.find` would have caught; and the Custom Highlight API needs macOS
  14.2, one minor version above the app's 14.0 deployment target, so below that
  find still steps and scrolls but paints nothing. `tools/snapshot.swift` types a
  whole query in as real key events, because script setting `.value` would be
  doing the typing WebKit refused to do, and `tools/check-render.py` asserts the
  field ends up holding all of it, still focused, with the match highlighted.
- **A rule written for `[data-theme="night"]` needs a `:root:not([data-theme])`
  twin inside the `prefers-color-scheme: dark` block.** Colophon and the System
  theme on a dark Mac are two different selectors reaching the same palette, so a
  dark-only override written once only lands on one of them — the other keeps the
  light value on a near-black ground. Two rule families need the twin: code text
  (`figure.code code`) and all five alerts. The alerts were missing theirs, and
  `.alert-label` is 10px text in that colour, so it measured 2.2:1 where Colophon
  gets 5.7:1. Note came later for the same reason: it carries the plain accent,
  pinned to the light themes' `accent-600`, which is 3.6:1 on the dark ground — it
  takes the theme's own `--accent` there instead, for 7.8:1. The guard matters as much as the rule: without
  `:not([data-theme])` it would leak into Paper and Vellum, and only *look*
  right because the window's appearance is pinned on the Swift side.
- **The render harness picks the webview's appearance from its own `light|dark`
  argument, not from `MDVIEW_THEME`.** So the default runs only ever exercise
  theme and appearance *agreeing* — which is exactly why the alert bug was
  invisible for as long as it was. `tools/run-tests.sh` adds a
  `MDVIEW_THEME=system … dark` run for the disagreeing case, and
  `tools/check-render.py` asserts its alert accents match Colophon's.
- **Test every theme.** The bug above passed a suite that only rendered the
  default one. `tools/run-tests.sh` now makes five renders across all four
  settings choices: Paper on a light Mac and on a dark one, Colophon, Vellum,
  and the Follow System run above.

## The titlebar's right side

Copy, contents, settings — spaced `--space-2` apart with `--space-3` to the window
edge, so they read as a cluster of three rather than one wide control.

Copy puts the document's **markdown source** on the clipboard,
not the rendered text, and appears only for markdown files — the app opens plain
text too, where "copy the markdown" means nothing. `⌥⌘C` does the same, and the
icon becomes a tick for a moment so the click is acknowledged.

## Deliberate departures from the spec

- **No hover tint on the document's name.** The design tints it with 10% accent;
  a gold wash sweeping the titlebar on every mouse pass is distracting in use.
  The caret carries the affordance instead.
- **Layout is its own settings section**, which the design does not have: the
  measure and the alignment are settings, not consequences of the type size. The
  design hardcodes justified text and derives the measure from the size; here
  Alignment (justified / left) and Column width (480–1000pt) stand on their own,
  and Type size sets only the type.
- **A fourth theme option, "Follow System"**, which the design does not have. It
  highlights whichever of the three is actually in effect, so the panel never
  shows an unselected set.
- **The frontmatter disclosure opens for any document**, saying when there is
  none, rather than being inert on documents without a block.
- **No Parsed/Raw toggle.** The design offers a raw view of the block; the parsed
  rows are what the panel is for, and the file itself is a keystroke away.

## Sidebar identity

A row's identity is **where it appears**, not what it points at: `depth` plus the
path as listed. A symlink beside its target — `AGENTS.md -> CLAUDE.md` — resolves
to the same file, so using the resolved path gave both rows the same `ForEach` id
and SwiftUI dropped one, leaving a gap in the list.

The resolved path is still used for two things: matching the open document to its
row (so a file reached through a symlinked folder still highlights), and `reveal`.
Because both twins resolve alike, the selected row is chosen once for the whole
list — the row actually opened wins — rather than each row deciding for itself.

## The keyboard

Plain keys for reading — `j k g G n N` to move, `/` to find, `h` and `l` for the
two panels, `?` for the list of them all. `Sources/Shortcuts.swift` holds the
table and the rule for reading it, `ShortcutMonitor.swift` is the only thing that
touches AppKit, `ShortcutsOverlay.swift` draws `?`, and Help ▸ Keyboard Shortcuts
opens the same overlay for a reader who does not know `?` yet — with no key
equivalent of its own, because `?` is already the binding and a second one would
be a binding the table does not know about.

- **One table, and it includes the menu shortcuts.** `Shortcuts.all` is every
  binding in the app, the menu-owned ones as well, because the overlay is
  rendered from it — so a binding cannot exist without the reader being told
  about it. The cost is that the monitor has to skip the `.menu` rows: a menu
  item already owns its key equivalent, and acting on it here would fire it
  twice. `tools/test-shortcuts.swift` pins that, plus the things that make it a
  table: no duplicate strokes, no untitled rows, one title and group per action.
- **Shift lives in the character, not in the modifier set.** `G` is a key of its
  own, and so is `?` — which is what `charactersIgnoringModifiers` reports
  anyway. Recording the flag beside it would record shift twice, and would break
  these bindings on every layout that does not put `?` above `/`.
- **Resolution is a pure function of an explicit context.** `Shortcuts.resolve`
  takes a `KeyContext` — is this window key, is the chrome taking text, does an
  input in the page have focus, which overlay is up — and returns an action or
  nothing. No windows, no globals, no view state: the whole policy is testable
  without synthesising an event, which is most of `test-shortcuts.swift`. The
  monitor holds no state either; it asks `ViewerView` for a fresh context at
  every keystroke.
- **Plain keys must never take a keystroke from the two text inputs**, the
  sidebar's search field and the page's find bar. Neither can be tracked the
  obvious way. In the chrome, `controlTextDidBeginEditing` fires on the *first*
  keystroke — the one that must not be swallowed — so the window's first
  responder is read instead. In the page, Swift cannot see focus at all, so
  `web/src/viewer.js` reports it. `focusin`/`focusout` alone left that flag stuck
  on: moving first responder out of the web view — clicking a file row, the
  search field, a contents row — fires no `focusout`, the find bar keeps DOM
  focus, and every plain key then died in silence. The window's own blur is the
  event that does fire, so it is what stands the flag down, and the page reports
  once at load because ⌥⌘R sends no message of its own.
- **A bare key nothing is bound to is swallowed.** Nothing in `Sources/`
  implements `keyDown`, so a letter reaching the end of the responder chain makes
  macOS beep — a bubble noise for touching the keyboard in a window whose whole
  job is reading. The trade is deliberate and worth knowing: a *mistyped*
  shortcut now gives no feedback at all. That is what makes the pass-through
  allowlist load-bearing — space and shift-space (how the page turns), tab and
  shift-tab, return, enter, delete, backspace, and Cocoa's whole 0xF700–0xF8FF
  function-key range, which covers the arrows, page up and down, home and end
  without having to name them one by one. It is written as what passes rather
  than what is dropped, because that is the half a future reader has to be able
  to check.
- **Keyboard motion jumps; mouse-driven motion animates.** CSSOM-View's
  `behavior: "auto"` does *not* mean "no animation" — it defers to the computed
  `scroll-behavior`, which the stylesheet sets to `smooth`, and only `"instant"`
  overrides it. This shipped wrong once: a smooth scroll retargets from wherever
  the animation has got to, so five rapid `j` presses travelled 1334px of the
  2000 they asked for, and five rapid `n` presses landed on the second heading
  instead of the fifth. Hence `KEYBOARD_SCROLL_BEHAVIOR` in `web/src/motion.js`,
  the one value every keyboard path takes, plus a text check in
  `tools/run-tests.sh` that fails on a literal `behavior: "auto"` anywhere in
  `web/src` — the constant cannot stop a new call site inventing its own.
  Clicking a rail tick or a contents row keeps the animation on purpose: that is
  one jump, and the eye can follow it. `n` and `N` at the ends stand still rather
  than aiming at the last heading, which past the final heading is a jump
  *backwards* — at the bottom of a one-heading document, the whole document.
- **Caps Lock changes the character, so the case comes from the shift flag.** It
  is not one of the modifiers `charactersIgnoringModifiers` strips: with the lock
  on, `j` arrives as `"J"`, so `j k h l` matched nothing and were swallowed in
  silence while `g` and `n` arrived as `G` and `N` and did the opposite of what
  was pressed. Only letters are re-cased, and only while the lock is on —
  everything else is left exactly as AppKit reported it, `?` included.

## Where things live

| Concern | File |
| --- | --- |
| Chrome palette, theme resolution, typeface registration | `Sources/Theme.swift` |
| Titlebar band, zones, the divider-less split | `Sources/ViewerLayout.swift` |
| Sidebar density, rows, search, badges, footer | `Sources/SidebarView.swift` |
| Icon button, outline and ghost button treatments | `Sources/Controls.swift` |
| Shortcuts overlay: sections, key caps, the two balanced columns | `Sources/ShortcutsOverlay.swift` |
| Hidden titlebar, window transparency and background | `Sources/WindowChrome.swift` |
| Document type, colour, code, diagrams, callouts | `Resources/style.css` |
| Document post-processing and diagram tinting | `web/src/viewer.js` |

## Implemented

Document surface in all three themes, text sizes, the editorial column, code
figures with caption bars, syntax colours, diagram treatment, frontmatter block,
alerts, footnotes, find bar. Chrome: the titlebar band with document name and word
count, the library sidebar with search, file badges, gold selection and a counted
footer, the settings panel with self-previewing theme swatches, the frontmatter
disclosure, and the shortcuts overlay.

## Frontmatter, and where it is shown

Split deliberately, so nothing appears twice:

- **The document** carries `title` as its display head and `subtitle` as an italic
  line beneath it.
- **The titlebar disclosure** (`⌘I`, or click the document's name) carries every
  other field — rows with hairlines, list values as outlined pills.

The page parses the block and posts the fields to Swift. Swift does not parse
frontmatter at all: a second parser is a second thing to keep in step. The
titlebar's **word count** rides the same message for that reason — Swift counted
the raw file for a while, frontmatter included, and the only way to fix that in
Swift was the second parser.

## The outline: a rail and a panel

Two pieces, with different jobs:

- **The tick rail** (`web/src/rail.js`) is a passive indicator down the left of the
  column: ticks sized by heading level (26/17/11pt), each swelling under the
  pointer with a gaussian falloff so the column reads as one object responding
  rather than a row of separate marks. Hovering names the section in a card, with
  the text that follows the heading; clicking jumps. It costs no horizontal space
  and shows where you are at a glance.
- **The contents panel** (`Sources/OutlinePanel.swift`) is the navigable list, on
  the **right**, toggled from the titlebar or `⌥⌘O`. Left answers "where am I in my
  files"; right answers "where am I in this document".

Both panels are resized by dragging their inner seam, and both remember the width
(`sidebarWidth`, `outlineWidth`). One `ResizeHandle` in `ViewerLayout.swift` serves
both: an invisible 9pt strip straddling the seam, told which edge it sits on.

Two things that made the seam judder, both fixed and both easy to reintroduce:

- **Measure the drag in `.global` space.** The handle rides the edge it resizes, so
  in the default local space a panel growing by 10pt moved the pointer 10pt left in
  the handle's own coordinates — the drag fed back on itself, frame by frame.
- **Cap a panel by what the window can spare** (the other panel plus
  `documentMinWidth`). Past that the `HStack` has to squeeze someone, and the seam
  jumps out from under the pointer. The cap limits the drag and the width drawn,
  never the stored width — widen the window and the reader's choice comes back.

## Why the panels' slide is declared on the view

`ViewerLayout.swift` carries `.animation(.easeOut(duration: 0.2), value:)` for each
of the two visibility flags, and the toggles themselves are bare `toggle()` calls.
That is not a style choice: wrapping the toggles in `withAnimation` instead breaks
the animation for most of the app.

**`sidebarVisible` and `outlineVisible` are `@AppStorage`, and an `@AppStorage`
write is invalidated later than a `@State` one.** By the time SwiftUI acts on it, a
transaction opened inside SwiftUI's own dispatch has already closed, and the
animation closed with it. `withAnimation` therefore animates only from a caller
outside that cycle, such as the key monitor, and does nothing from the titlebar
buttons or the menu.

Measured across storage kind against dispatch site: `@State` animates from all
three call sites, `@AppStorage` + `withAnimation` only from the monitor,
`@AppStorage` + `.animation(value:)` from all three. Hence declaring it on the
view: the slide belongs to the panel, not to whoever flipped the flag, and no call
site can forget it.

**Keyed on the flags, never on the widths.** Dragging a seam writes `sidebarWidth`
continuously; animate that and the panel trails the pointer by a fifth of a second.

`tools/test-panel-animation.swift` samples the drawn width every 10ms through a
toggle and counts the values between the two ends — it wants more than four, and
an unanimated toggle gives none — for the button path and the menu path on both
panels, and checks that a width write still lands in one step. The key monitor is
not covered: it fires only while the window is key, and a bare executable cannot
activate itself.

The design has the rail expand into a contents panel after dwelling two seconds in
its zone. That is gone: an outline you have to know about, and then wait for, is
not an outline you use. The panel replaced it.

The page owns the outline, because it needs live heading offsets and scroll
position; it posts the headings and the current index to the app, and the app posts
back a heading index to scroll to. Same shape as frontmatter.

Two things to know if you touch it:

- **Do not defer the outline read to `requestAnimationFrame`.** WebKit throttles
  animation frames when the window is offscreen, so the rail never initialises in
  the snapshot harness. `getBoundingClientRect` forces layout anyway.
- **The outline is re-read after diagrams draw.** Mermaid changes the height of
  the page, which invalidates every offset below it.
