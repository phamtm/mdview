# MDView

A local Markdown viewer for macOS. It opens a `.md` file — or an `.html` one —
renders it nicely, and re-renders the moment you save the file in your editor. A sidebar holds the
folders you work in, so you can browse and click between files. That's the whole
scope — no editing, no syncing, no accounts.

Built as a normal Swift/SwiftUI app bundle. WebKit (a system framework) does the
layout, so tables, syntax highlighting, Mermaid diagrams and images all work
without writing a text-layout engine. Nothing is fetched from the network: the
renderer libraries are bundled inside the app.

## Build and run

```bash
./build.sh && open build/MDView.app
```

To keep it around:

```bash
cp -R build/MDView.app /Applications/
```

Requires macOS 26 or later and the Xcode Command Line Tools — full Xcode is not
needed. The floor is `DEPLOY_TARGET` in `build.sh`, which sets both the
compiler's target and `LSMinimumSystemVersion`.

### Signing, and the 7-day thing

The 7-day re-signing limit applies to **iOS** apps signed with a free Apple ID.
It does not apply here. `build.sh` ad-hoc signs the app (`codesign --sign -`),
which never expires, and because you built the app locally it carries no
quarantine flag — so Gatekeeper doesn't prompt either. No developer account, no
weekly ritual.

If you ever move the app to another Mac, that copy *will* be quarantined. Clear
it with:

```bash
xattr -dr com.apple.quarantine /Applications/MDView.app
```

## The page is an npm project

The document renderer lives in `web/` and is bundled into `Resources/` by esbuild.
The Swift shell knows nothing about it beyond loading `viewer.html`.

```bash
cd web && npm install     # once
npm run build             # or just ./build.sh, which runs it when sources change
npm run watch             # rebuild on save, then ⌥⌘R in the app
```

| | |
| --- | --- |
| `web/src/viewer.js` | The renderer: markdown → DOM, post-processing |
| `web/src/find.js` | The find bar. Matches are custom highlights, never the selection |
| `web/src/frontmatter.js` | The frontmatter split, the document's head, the word count |
| `web/src/rail.js` | The tick rail beside the column, and it posts the outline to the app |
| `web/src/diagrams.js` | Mermaid: figures, on-demand library load, palette-matched drawing |
| `web/src/reading-position.js` | Where the reader is: anchors, per-file memory, reporting to Swift |
| `web/src/motion.js` | One constant: keyboard scrolling jumps, mouse-driven jumps animate |
| `web/src/util.js` | Tiny shared helpers (`escapeHtml`) |
| `web/src/mermaid.js` | Diagram entry point, built as its own file |
| `web/build.mjs` | esbuild config for the two bundles |
| `Resources/bundle.js` | **Generated.** Don't edit |
| `Resources/mermaid.js` | **Generated.** Injected on demand, never loaded otherwise |

Build output is committed, so `./build.sh` works on a machine without node — it
only re-bundles when `web/src` is newer. Two bundles rather than one because
mermaid is roughly ten times the size of everything else combined, and most
documents have no diagrams.

Swapping a package is now `npm i <thing>` and an import. The output is IIFE rather
than ESM because the page loads from `file://`, where module scripts are blocked
by CORS.

## Markdown support

Full GFM — tables, task lists, strikethrough, autolinked bare URLs, fenced code
with syntax highlighting — plus the GitHub extras that aren't in the base spec:

- **Footnotes**: `text[^1]` with `[^1]: the note` at the bottom
- **Alerts**: `> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]`
- **Mermaid** diagrams in ```` ```mermaid ```` blocks
- Raw HTML, including `<details>` — sanitised before it reaches the page

Not supported: LaTeX/math, `:emoji:` shortcodes.

### Frontmatter

A leading `---` (YAML) or `+++` (TOML) block is parsed out and split in two, so no
field is shown twice: `title` and `subtitle` head the document, and every other
field lives in the disclosure behind the document's name in the titlebar (`⌘I`),
with list values as pills. If the body already opens with an `# H1` matching the
frontmatter title, the title isn't printed twice.

`View ▸ Show Frontmatter` turns the document's head off; the disclosure keeps its
fields, and the block never renders as raw text either way.

The parser handles what frontmatter almost always is: `key: value` scalars,
inline `[a, b]` lists, `- item` block lists, quoted strings and `#` comments.
Nested maps are **skipped rather than guessed at** — this is deliberately not a
full YAML implementation, and a nested key just doesn't appear in the header.

## Using it

### Sidebar

`⇧⌘O` adds a folder, or use the `Add Folder` row at the bottom of the sidebar.
Add as many as you like; they come back next launch.

- Click a folder to expand it, click a file to open it
- The file you're reading is highlighted, and opening one any other way (Finder,
  a link, `⌘O`) expands the tree to it
- Folders you have open are watched, so files added or deleted elsewhere appear
  and disappear on their own — no refresh needed
- Only markdown-ish files are listed. `View ▸ Show All Files in Sidebar` lifts that
- Right-click for reveal in Finder, copy path, and remove folder
- `h`, `⌘B` hides and shows the sidebar; drag its right edge to resize (the width sticks)

### Reading

A few things the app does so you don't have to think about where you were:

- **Every file remembers where you stopped reading.** Switch away and back, quit
  and reopen tomorrow — the document opens at your place. The last 64 positions
  survive a relaunch; within a session every file is remembered.
- **Live reloads don't move under you.** Saving from an editor re-renders, but
  your viewport is anchored to the nearest heading above it plus how far into
  that section you'd read — so editing paragraphs above the fold can't drag
  your sentence around. Open `<details>` sections stay open too.
- **Following a link between files keeps the way back.** `⌘[` goes back to the
  document you came from, `⌘]` forward again.
- **Quick Open** (`⌘P`) fuzzy-matches every file in the library — folders that
  were never expanded included. An empty query lists your recents.

### Motion

The app respects `prefers-reduced-motion`: smooth scrolling, panel slides, theme
cross-fades and the rest all collapse to instant when the system asks for it.
Theme changes cross-fade over ~200ms otherwise; documents fade up as they open.

### Document

- `⌘O` opens a file; drag a file onto the window; or `open -a MDView notes.md`
- Markdown (`.md .markdown .mdown .mkd .mdx .markdn .rmd .qmd`), HTML (`.html
  .htm`) and plain text (`.txt .text`). A `.txt` is read as markdown, as it
  always was.

  **For an HTML file the job is to display it safely, and nothing else.** It is
  shown as the page it already is — the markdown parser is skipped, because
  running it damages what it is handed: HTML is indented, and four spaces of
  indent is a markdown code block, so nested elements come out as
  `<pre><code>&lt;p&gt;…`. What still applies is everything about *showing* it:
  the sanitiser, which is a separate step from the parser and so is not skipped
  with it, and relative paths, which resolve against the file in all three
  attributes that carry one (`src`, `srcset`, `poster`).

  What does not apply is everything that reads a *document structure* into it —
  no contents panel, no rail ticks, no frontmatter, no word count. An HTML file's
  headings are as likely to be a nav bar, a sidebar or a footer as they are
  sections: a saved page with a three-heading article produced a seven-row
  contents panel, and nothing in the markup says which is which. "How many words"
  has no honest answer for a page either — three attempts at one gave three
  different numbers, and the last still disagreed with the markdown count by 30%
  on the same prose. Both are absent rather than empty, so the titlebar and the
  panel show nothing instead of the last document's
- Save the file in any editor and the view refreshes, keeping your reading position (see Reading above)
- Links to other local `.md` files open in the app; web links go to your browser;
  `#heading` links and footnotes scroll in place
- Relative image paths resolve against the file's own folder. Images below the
  fold load lazily and fade in as they arrive
- Ticks down the left of the column show where you are; hover one to see its
  heading, click to jump there
- `l`, `⌥⌘O` opens a contents panel on the right listing the headings — `#`,
  `##` and `###`; deeper ones are left out. Drag its left edge to resize — like
  the sidebar, the width sticks, and neither panel is allowed to squeeze the
  document below its minimum width

To make `.md` (or `.html`) files open here by default: select one in Finder,
`⌘I`, and pick MDView under "Open with", then "Change All".

### Shortcuts

| | |
| --- | --- |
| `j` / `k` | Half a page down / up |
| `g` / `G` | Top / end of the document |
| `n` / `N` | Next / previous heading |
| `⌘[` / `⌘]` | Back to the previous document / forward again |
| `/` or `⌘F` | Find in document |
| `?` | Every shortcut there is, in a panel |
| `Esc` | Close that panel, or the find bar |
| `h`, `⌘B` | Toggle sidebar |
| `l`, `⌥⌘O` | Toggle the contents panel |
| `⌘P` | Quick Open — type a few letters, land on the file |
| `⌘O` | Open file |
| `⇧⌘O` | Add folder to sidebar |
| `⌘,` | Settings: theme, type size, alignment, column width |
| `⌘R` | Reload document |
| `⌥⌘R` | Reload renderer (after a `web/` rebuild) |
| `⌘I` | Front matter of the open file |
| `⌥⌘C` | Copy the document's markdown source |
| `⌘=` / `⌘-` / `⌘0` | Zoom in / out / reset |
| `Help ▸ Keyboard Shortcuts` | The same panel as `?` |
| `View ▸ Show Frontmatter` | Show or hide the metadata header |
| `File ▸ Copy File Path` | Path of the open file |
| `⇧⌘R` | Reveal in Finder |
| `⇧⌘P` | Print |

The plain keys work while you are reading and stand down while you are typing —
in the sidebar's search box or the find bar, they are just letters. A key nothing
is bound to does nothing at all, deliberately: no beep, and nothing typed.

## Design

Spacing, type and colour follow [DESIGN.md](DESIGN.md) — the layout zones, the
density of the sidebar, the three themes, and the rule that the gold accent is
stroke and rule, never fill. Change that document first, then follow it into
`ViewerLayout.swift`, `SidebarView.swift`, `Controls.swift` and `style.css`.

## The window

The real titlebar is hidden. In its place a 52pt band runs across the top of the
window, carrying the traffic lights and the sidebar toggle on the left, the
document's name and word count in the middle, and the copy, contents and settings
buttons on the right. Panels are separated by hairlines of our own rather than
system dividers.

Consequences worth knowing:

- **`NavigationSplitView` isn't used.** It always draws a divider between its
  columns and offers no way to turn that off, so the split is a plain `HStack`
  with an invisible drag handle on the seam.
- **The titlebar is hidden via `.windowStyle(.hiddenTitleBar)`** on the scene.
  Setting `titlebarAppearsTransparent` and `titleVisibility` on the `NSWindow` by
  hand does *not* hold: SwiftUI configures its own titlebar after the scene is
  attached and puts the title text back, giving you the filename twice — once in
  the titlebar, once in our band — plus an empty band above the document. Use
  the scene modifier. `tools/check-window-chrome.sh` guards against a regression by
  asking the running app what its window actually looks like.
- The traffic lights sit over app content, and macOS decides where: it derives
  their position from the titlebar setup. With an empty unified toolbar attached
  they are 14pt, span x=9…69 and sit 26pt from the top — so the band is 52pt to
  put them in its centre, and the band's left zone reserves their span plus room
  for the toggle. Those numbers are constants in `ViewerLayout.swift` and
  `tools/check-window-chrome.sh` asserts `buttonCentre=26`; DESIGN.md has the
  measurements they came from. Re-measure rather than nudge them by eye.
- **No focus rings, and focus starts in the document.** `.focusEffectDisabled()` on
  the layout root covers every control, and the web view is made first responder on
  creation — otherwise SwiftUI focuses the header button at launch and rings it,
  and page keys don't work until you click.

## The icon

`tools/make-icon.swift` draws it — three variants (`ink`, `paper`, `accent`).
Change `ICON_VARIANT` at the top of `build.sh` and rebuild. To compare them
first:

```bash
swift tools/make-icon.swift --sheet build/icon-paper.png paper
```

That renders the icon large plus at real Dock sizes (128, 96, 64, 32), which is
the only honest way to judge one.

macOS caches icons aggressively. If the Dock keeps showing the old one after a
rebuild, `killall Dock` forces it to re-read.

## How it fits together

| Piece | Job |
| --- | --- |
| `Sources/DocumentModel.swift` | Owns the open file: loads it, tracks recents, restores the last one on launch |
| `Sources/Workspace.swift` | The sidebar's folders and tree nodes: lazy directory reads, sorting, filtering |
| `Sources/SidebarView.swift` | The sidebar itself — rows, disclosure, context menus |
| `Sources/FileWatcher.swift` | Watches the file for changes, including the temp-file-plus-rename that editors use when saving |
| `Sources/ViewerWebView.swift` | Hosts the WebKit view, routes menu commands and link clicks, accepts dropped files |
| | The navigation policy is load-bearing: WebKit reports in-page `#fragment` jumps as link activations on `viewer.html`, so they must be allowed, while everything else must be cancelled — navigating away destroys `window.mdview` and every later render fails silently |
| `Sources/Notifications.swift` | The one list of `mdv.*` channels: most are handled by the web view, the panel toggles and the overlays by `ViewerLayout` |
| `Sources/Shortcuts.swift` | The one table of every key binding, and the pure rule that says what a keystroke means right now |
| `Sources/ShortcutMonitor.swift` | The AppKit half: key events in, actions out. It also swallows bare keys nothing is bound to, so they don't beep |
| `Sources/ShortcutsOverlay.swift` | The `?` panel, drawn entirely from that table |
| `Sources/MDViewApp.swift` | App entry point, menu bar, launch behaviour |
| `Sources/ViewerLayout.swift` | The window: the hand-built split, the titlebar band, the panel resize handles |
| `Sources/WindowChrome.swift` | The AppKit side of the window: hidden titlebar, transparency, background — and the dump `tools/check-window-chrome.sh` reads |
| `Sources/Controls.swift` | The small chrome controls the design allows: the icon button, the copy button, and the outline and ghost button styles |
| `Resources/viewer.html` + `bundle.js` + `style.css` | The page itself: markdown to DOM, then styling (`mermaid.js` joins them on demand) |
| `web/` | npm project for the page: marked + marked-footnote (markdown), highlight.js (code), Mermaid (diagrams), DOMPurify (sanitising) |

Three things worth knowing if you change it:

- **Everything an opened file contains is treated as untrusted** — markdown and
  HTML alike; skipping the markdown parser for an HTML file does not skip the
  sanitiser, which is the whole reason the two are separate steps. The rendered
  HTML goes through DOMPurify, and `viewer.html` carries a Content-Security-Policy.

  Both are needed, for a narrower reason than you might assume. The page is
  granted file read access, but that only lets it *display* local files as
  subresources — `fetch`/`XHR` to `file:` URLs is blocked, so script in a document
  could not read `~/.ssh` even if it ran. What it *could* do, before the CSP, was
  phone home the moment a file was opened: DOMPurify passes `<img src="https://…">`
  and `<form action="https://…">` through untouched. The CSP closes that and means
  a future sanitiser bypass can't fetch or exfiltrate either.

  One gap to know about: Mermaid's SVG output is assigned with `innerHTML` and does
  **not** pass through this app's DOMPurify call. It is sanitised by Mermaid's own
  bundled copy because it runs at `securityLevel: "strict"` — so the boundary holds,
  but by delegation to a pinned dependency.
- **File identity uses symlink-resolved paths.** A folder reached through a
  symlink produces different paths for the same file, which would stop the
  sidebar from highlighting or revealing what you have open. Each node resolves
  its path once at creation; comparisons use that.
- **Mermaid is loaded on demand.** It is 3.3MB of the 4MB bundle, so it is only
  fetched into the page when a document actually contains a `mermaid` block.
  Diagrams are redrawn when the system appearance changes, since Mermaid bakes
  its colours into the SVG.

## Tests

```bash
./tools/run-tests.sh
```

About 18 seconds — the same whether nothing changed or you edited the page. A
Swift edit costs low 30s, all of it the optimised app build that a Swift edit
genuinely needs. Six things keep it there, and all of them are easy to undo by
accident:

- **The harnesses build with `-Onone -wmo`, all at once.** Each one is the same
  ~16 source files plus its own `main.swift`, so building them one at a time with
  `-O` was 48s — more than every check in the suite put together. Nothing here
  measures throughput and the runs come out the same speed either way, so
  optimising was pure cost.
- **Waits poll the page, they don't sleep.** The mermaid wait used to be a flat
  3s; the diagram is drawn in 0.1s.
- **Nothing is rebuilt that is already newer than its inputs** — neither a
  harness nor the app. `build.sh` caches the compiled binary outside the bundle
  and skips the compile when only the page changed, which is 10 of its 12
  seconds; the bundle around it is still assembled from scratch every time, so
  there is no stale-file class of bug to reason about. That decision lives only
  in `build.sh` — a second copy of "what the app depends on" would be two lists
  to hold in step. Get the inputs wrong and tests run against a stale build,
  which is loud; it cannot make them flake.
- **The renders run at once, and so do the theme probes.** Seven render
  processes and three app launches, all independent — nothing shared, not even a
  preferences domain. No wait got shorter: the waiting overlaps. That it holds
  under load is checked rather than assumed — 14 consecutive suite runs, four of
  them with eight cores busy competing, no failures and no change in duration.
  The suite is dominated by fixed waits, not CPU, which is why this was safe.
- **`check-theme.sh` passes the theme on the command line**, which
  NSUserDefaults reads as its argument domain and prefers over the stored value.
  It used to `defaults write com.minh.mdview theme` and restore the old value
  from a trap, so running the tests edited your own setting — and left it on the
  last theme tried if the script was killed in between. Nothing is written now,
  which is both safer and what lets the three runs overlap.
- **One render runs the theme-independent checks, not all six.** The frontmatter
  parser, the word count, page focus, the heading clamp and the selection gutter
  reach the same verdict whichever palette is loaded, and running them per theme
  was ~3.5s a render for the same answer five times over. `MDVIEW_BATTERY=theme`
  runs the two phases that *do* vary — the diagnostics probe, and the second
  render, which switches theme and so exercises each palette as both a starting
  point and a destination. Full is the default, and `check-render.py` fails if no
  render ran it, so this cannot quietly become "checks nothing".

The PNGs are not tests — no check has ever read one, and writing one means
holding the page still for 1.2s. They are off in the suite. To write every image
the harnesses can produce, including the full-window render:

```bash
./tools/shots.sh
```

That render used to be a suite step, at 16s a run, and it had no assertions at
all — it could not fail. What the real window looks like is
`check-window-chrome.sh`, which asks the running app.

Thirteen checks, in the order they run:

- **web bundle** — esbuild is the syntax check, since it fails the build on a
  parse error, and it means everything below runs against the current `web/src`.
  Plus a grep for `behavior: "auto"`, which reads like "no animation" and is not:
  it inherits `scroll-behavior: smooth` from the stylesheet instead of overriding
  it, which is how every keyboard scroll came to animate and lose most of its
  travel
- **payload contract** — every `payload.*` key the page reads is declared in
  `RenderPayload.swift`, and the harness goes through that type rather than
  hand-rolling a dictionary. The two sides drifted once and the tests missed it
- **file watcher** — survives the temp-file-plus-rename that editors do on save
- **sidebar tree** — sorts folders first, filters files it cannot open, expands
  down to a revealed file, and notices files appearing and disappearing on disk.
  Also which extension means what: that `.html` is opened but is *not* markdown,
  so it reaches the page as `format: "html"` and the wrong parser cannot run
- **shortcut table and resolver** — what every key means, and what it means while
  something else has the keyboard: the sidebar's search box, the page's find bar,
  each overlay, another window, Caps Lock on. The expectations are written out by
  hand rather than read from the table, since a test that derives them from the
  thing it is testing cannot fail. Also that the table stays a table — no
  duplicate strokes, no untitled rows, every action bound to something
- **key delivery** — the same rules through a real (offscreen) window and
  synthesised events, which the pure resolver cannot cover: `j` reaches a focused
  text field and fires nothing, `⌘]` still fires while you type, an unbound letter
  is swallowed instead of beeped at, and space still reaches the responder chain
  because that is how the page turns
- **panels slide, from every path** — samples the drawn panel width every 10ms
  through a toggle, from the titlebar button and from the menu, and counts the
  widths in between — none at all means it jumped. It is here because the failure
  is silent: the buttons toggled the panels with no animation at all while the
  keys animated, and nothing in the code read wrong. It also checks that setting a
  width still lands in one step, which is the other half — animate the width and a
  seam drag lags the pointer
- **window chrome** — launches the built app and asks what its window actually
  looks like: titlebar hidden and transparent, content filling the frame, traffic
  lights centred in the band, focus in the web view
- **theme reaches the document** — the real app in each of the three fixed themes,
  checking the page rendered the one that was asked for, that the window's own
  appearance follows the theme rather than the OS (native scrollbars take their
  knob colour from it, so a light theme under a dark macOS drew a white knob),
  and that the window frame and the overscroll area are painted to match
- **renderer** — a headless render of `sample.md` produces the expected headings,
  code blocks, tables, task lists, diagram, resolved image path, five alert kinds
  and footnotes, and strips the `<script>` planted in that file. Run in every
  theme, because a token that Mermaid's colour parser rejects breaks diagrams in
  that theme alone — plus one run with the System theme on a *dark* appearance,
  the only combination where the theme and the appearance disagree, which is
  where the alert colours went wrong. Also asserts the column's 68px left
  padding, and that the word count the page reports leaves the frontmatter out.
  Two unit suites run inside the page here too. The frontmatter parser:
  YAML and TOML delimiters, both list styles, quotes, comments, CRLF endings,
  nested-map skipping, and the cases that must *not* be treated as frontmatter.
  And the word count's separators — space and the newlines, but deliberately not
  a tab or a non-breaking space, which is how Swift counted before the page took
  it over and is not something `sample.md` can show.
  Finally it renders a **second** document, in a different theme, into the same
  page: the new theme has to apply, the headings have to be the new document's,
  and the rail and the posted outline have to be *replaced* rather than added
  to. That is the page-side half of "the first render works and every later one
  silently does nothing", which is invisible in a single shot.
  Three more things are asserted from inside the page, none of them visible in a
  screenshot: that keyboard motion is set to jump rather than animate — offscreen
  every scroll is instant whatever was asked for, so only the decision can be
  checked; that the page reports find-bar focus at load, when the bar takes focus
  and when the window loses it, because a report that never arrives leaves every
  plain key dead; and that `n` and `N` stand still at the ends of two documents
  written for the purpose instead of jumping backwards. Plus the suite's one
  pixel assertion: the same page shot unselected and selected, with every changed
  pixel outside the column counted, since WebKit's selection gap filling reaches
  neither computed style nor geometry.
  And one thing that has to come from *outside* the page: a whole query typed into
  the find bar as real key events, one character at a time, after which the field
  must still hold all of it, still have focus, and have a match highlighted. Only
  the first character used to arrive — see the single-selection note in DESIGN.md —
  and script setting `.value` cannot see that, because then script is doing the
  typing WebKit refused to do.
  Two more searches run on that same document, this time driven from script,
  because what they are about is which ranges the search builds rather than how
  the characters arrive: a phrase inline markup splits in two — the "down" of a
  bolded `mark**down**` — must be found, with a range that starts in one text
  node and ends in another, and two adjacent blocks whose text would spell a
  word between them must *not* match it.
  The app's navigation policy is *not* covered — the harness runs its own
  navigation delegate
- **contents rail** — the hover preview appears, and sits beside the tick it
  describes rather than at the top of the window
- **frontmatter hidden** — with the header switched off, nothing from the block
  reaches the document, the YAML doesn't leak into the body, and the body keeps
  its headings
- **an html document is displayed, and nothing more** — three fixtures, each for
  a way the contract can break. `tools/sample.html` covers "displayed as HTML,
  safely": the page reports which parser it used, and two tripwires cover that
  flag being right while the branch is wrong — a paragraph indented four spaces,
  which markdown turns into a code block with the tags showing, and a `~~this~~`
  in loose text between HTML blocks, which is where markdown still does inline
  work. Then the table, the five headings with ids, `src`/`srcset`/`poster` each
  resolved against the file, and the `<script>` and `onerror` stripped. Then the
  "nothing more" half: no rail, no outline posted, no frontmatter header, and no
  word count — *absent*, not zero, since the count is deliberately kept when a
  document opens and saying nothing would leave the previous file's number up.
  `tools/sample-dashes.html` opens with `---`, which is frontmatter in markdown
  and nothing in HTML; splitting it anyway ate the first heading in silence, so
  its `h1` is what is checked. `tools/sample-diagram.html` has a diagram, because
  drawing one rebuilds the rail — a second place the outline could come back
  from, and one only a document with a diagram reaches

Two things make the window snapshot fiddly, both worked around:

- WebKit draws out of process, so `cacheDisplay()` captures the chrome with an
  empty document area. The web view is snapshotted separately and composited in.
- In a *titled* window, `cacheDisplay()` silently drops the sidebar's scroll
  subtree, capturing it as black. So the harness window is borderless with
  stand-in traffic lights, and the real titlebar is verified by state instead —
  which is exactly the gap that let the duplicate-title bug through.

The offscreen renders can be driven into states a still capture cannot reach:

| Variable | Effect |
| --- | --- |
| `MDVIEW_THEME=paper\|vellum\|night` | Render in that theme |
| `MDVIEW_ALIGN=left`, `MDVIEW_MEASURE=900` | Alignment and column width |
| `MDVIEW_WIDTH=1400` | Page width, for layout that depends on the measure fitting |
| `MDVIEW_RAIL=hover` | Hover a tick, showing its preview card |
| `MDVIEW_SETTINGS=1`, `MDVIEW_FRONTMATTER=1`, `MDVIEW_OUTLINE=1` | Open that panel |
| `MDVIEW_SIDEBAR_CLOSED=1` | Capture with the library closed |
| `MDVIEW_ROOT=<path>` | Point the sidebar at a real folder |

It also writes `build/shot-{light,dark}.png`, plus one per remaining run
(`shot-night-dark.png`, `shot-vellum-light.png`, `shot-system-dark.png`), so you
can eyeball the styling without launching anything.
