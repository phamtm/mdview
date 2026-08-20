# MDView

A local Markdown viewer for macOS. It opens a `.md` file, renders it nicely, and
re-renders the moment you save the file in your editor. A sidebar holds the
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

Requires the Xcode Command Line Tools. Full Xcode is not needed.

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
| `web/src/viewer.js` | The renderer: markdown → DOM, post-processing, find bar |
| `web/src/mermaid.js` | Diagram entry point, built as its own file |
| `web/build.mjs` | esbuild config, and copies highlight.js themes |
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

A leading `---` (YAML) or `+++` (TOML) block is parsed out and shown as a header
above the document — title in full size, everything else as labelled fields, with
list values as pills. If the body already opens with an `# H1` matching the
frontmatter title, the title isn't printed twice.

`View ▸ Show Frontmatter` turns the header off; the block never renders as raw
text either way.

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
- `⌘B` hides and shows the sidebar; drag its right edge to resize (the width sticks)

### Document

- `⌘O` opens a file; drag a file onto the window; or `open -a MDView notes.md`
- Save the file in any editor and the view refreshes, keeping your scroll position
- Links to other local `.md` files open in the app; web links go to your browser;
  `#heading` links and footnotes scroll in place
- Relative image paths resolve against the file's own folder

To make `.md` files open here by default: select one in Finder, `⌘I`, and pick
MDView under "Open with", then "Change All".

### Shortcuts

| | |
| --- | --- |
| `⌘O` | Open file |
| `⇧⌘O` | Add folder to sidebar |
| `⌘B` | Toggle sidebar |
| `⌘R` | Reload document |
| `⌥⌘R` | Reload renderer (after a `web/` rebuild) |
| `⌘F` | Find in document |
| `⌘=` / `⌘-` / `⌘0` | Zoom in / out / reset |
| `⌥⌘S` | Toggle serif reading font |
| `View ▸ Show Frontmatter` | Show or hide the metadata header |
| `⇧⌘R` | Reveal in Finder |
| `⌘P` | Print |

## Design

Spacing, type and colour follow [DESIGN.md](DESIGN.md) — the layout zones, the
density of the sidebar, and the rule that colour belongs to content and not to
chrome. Change that document first, then follow it into `ViewerLayout.swift`,
`SidebarView.swift` and `style.css`.

## The window

There are no dividers anywhere. The sidebar sits flush against the document on a
background a hair off it, runs the full height of the window behind the traffic
lights, and the filename lives in a slim borderless header rather than the
titlebar.

Two consequences worth knowing:

- **`NavigationSplitView` isn't used.** It always draws a divider between its
  columns and offers no way to turn that off, so the split is a plain `HStack`
  with an invisible drag handle on the seam.
- **The titlebar is hidden via `.windowStyle(.hiddenTitleBar)`** on the scene.
  Setting `titlebarAppearsTransparent` and `titleVisibility` on the `NSWindow` by
  hand does *not* hold: SwiftUI configures its own titlebar after the scene is
  attached and puts the title text back, giving you the filename twice — once in
  the titlebar, once in the header — plus an empty band above the document. Use
  the scene modifier. `tools/check-window-chrome.sh` guards against a regression by
  asking the running app what its window actually looks like.
- The traffic lights sit over app content. Measured on macOS 26 they are 14pt,
  spanning x=9…69 with their centre 16pt from the top of the window — so the
  document header is 32pt tall to share that centre line, the sidebar keeps 36pt
  clear, and the header shifts right when the sidebar is hidden. Those numbers are
  constants in `ViewerLayout.swift`; re-measure rather than nudge them by eye.
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
| `Sources/MDViewApp.swift` | App entry point, menu bar, launch behaviour |
| `Sources/ViewerLayout.swift` | The window: the divider-less split, the document header, the titlebar treatment |
| `Resources/viewer.html` + `app.js` + `style.css` | The page itself: markdown to DOM, then styling |
| `web/` | npm project for the page: marked + marked-footnote (markdown), highlight.js (code), Mermaid (diagrams), DOMPurify (sanitising) |

Three things worth knowing if you change it:

- **Everything a markdown file contains is treated as untrusted.** The rendered
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

Checks four things:

- the JS parses
- the file watcher survives the temp-file-plus-rename that editors do on save
- the sidebar tree sorts folders first, filters non-markdown files, expands down
  to a revealed file, and notices files appearing and disappearing on disk
- the frontmatter parser handles YAML and TOML delimiters, both list styles,
  quotes, comments, CRLF endings, nested-map skipping, and the cases that must
  *not* be treated as frontmatter (a `---` rule on the first line)
- a headless WebKit render of `sample.md` produces the expected headings, code
  blocks, tables, task lists, diagram, resolved image path, frontmatter header,
  five alert kinds and footnotes — and strips the `<script>` planted in that file
- with the frontmatter header switched off, the YAML doesn't leak into the body

It also renders the whole window offscreen to `build/window-{light,dark}.png`.
Two things make that harness fiddly, both worked around:

- WebKit draws out of process, so `cacheDisplay()` captures the chrome with an
  empty document area. The web view is snapshotted separately and composited in.
- In a *titled* window, `cacheDisplay()` silently drops the sidebar's scroll
  subtree, capturing it as black. So the harness window is borderless with
  stand-in traffic lights, and the real titlebar is verified by state instead —
  which is exactly the gap that let the duplicate-title bug through.

It also writes `build/shot-{light,dark}.png` and `build/sidebar-{light,dark}.png`
so you can eyeball the styling without launching anything.
