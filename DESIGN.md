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

An earlier version of this document described a different direction — system
sans, monochrome chrome, no lines anywhere. It has been replaced wholesale. Where
traces of it survive in old commits, the design project wins.

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
accent-tinted), **Colophon** (near-black). Chosen from `View ▸ Theme`; "Follow
System" picks Paper or Colophon by appearance.

## Layout

| Zone | Value |
| --- | --- |
| Titlebar band | 52pt, surface-coloured, hairline beneath |
| Band split | hairline at the sidebar's edge; traffic lights and the sidebar toggle sit left of it |
| Left zone, sidebar closed | 136.4pt = buttons (69) + `--space-6` + toggle (26) + inset (13.8) |
| Sidebar | 258pt default (drag 170–460), surface 62% over bg, hairline right edge |
| Sidebar row | 27pt, 16pt indent per level, 4pt radius |
| Document column | 700pt measure at 17px (640/15 small, 760/19 large) |
| Column padding | 72pt top, 36.8pt sides, 120pt bottom |

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

Three implementation notes that are easy to trip over:

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
- **Test every theme.** The bug above passed a suite that only rendered the
  default one. `tools/run-tests.sh` now renders all three.

## Deliberate departures from the spec

- **No hover tint on the document's name.** The design tints it with 10% accent;
  a gold wash sweeping the titlebar on every mouse pass is distracting in use.
  The caret carries the affordance instead.
- **A fourth theme option, "Follow System"**, which the design does not have. It
  highlights whichever of the three is actually in effect, so the panel never
  shows an unselected set.
- **The frontmatter disclosure opens for any document**, saying when there is
  none, rather than being inert on documents without a block.
- **No Parsed/Raw toggle.** The design offers a raw view of the block; the parsed
  rows are what the panel is for, and the file itself is a keystroke away.

## Where things live

| Concern | File |
| --- | --- |
| Chrome palette, theme resolution, typeface registration | `Sources/Theme.swift` |
| Titlebar band, zones, the divider-less split | `Sources/ViewerLayout.swift` |
| Sidebar density, rows, search, badges, footer | `Sources/SidebarView.swift` |
| Document type, colour, code, diagrams, callouts | `Resources/style.css` |
| Document post-processing and diagram tinting | `web/src/viewer.js` |

## Implemented

Document surface in all three themes, text sizes, the editorial column, code
figures with caption bars, syntax colours, diagram treatment, frontmatter block,
alerts, footnotes, find bar. Chrome: the titlebar band with document name and word
count, the library sidebar with search, file badges, gold selection and a counted
footer, the settings panel with self-previewing theme swatches, and the frontmatter
disclosure.

## Frontmatter, and where it is shown

Split deliberately, so nothing appears twice:

- **The document** carries `title` as its display head and `subtitle` as an italic
  line beneath it.
- **The titlebar disclosure** (`⌘I`, or click the document's name) carries every
  other field — rows with hairlines, list values as outlined pills.

The page parses the block and posts the fields to Swift. Swift does not parse
frontmatter at all: a second parser is a second thing to keep in step.

## The contents rail

Lives in the page (`web/src/rail.js`), because it needs live heading offsets and
scroll position. Three states:

- **collapsed** — ticks only, sized by heading level (26/17/11pt), each swelling
  under the pointer with a gaussian falloff so the column reads as one object
  responding rather than a row of separate marks
- **hovered** — the tick under the pointer names its section in a card, with the
  first sentence that follows the heading
- **expanded** — after dwelling 3s in the 58pt zone, the contents panel; the pin
  keeps it open and the column shifts right to 312pt to make room

Two things to know if you touch it:

- **Do not defer the outline read to `requestAnimationFrame`.** WebKit throttles
  animation frames when the window is offscreen, so the rail never initialises in
  the snapshot harness. `getBoundingClientRect` forces layout anyway, so reading
  synchronously is both simpler and testable.
- **The outline is re-read after diagrams draw.** Mermaid changes the height of
  the page, which invalidates every offset below it.
