# MDView design language

## Why this exists

Every spacing and colour value in this app used to be decided locally — some in
Swift constants, some in CSS, none of them related to each other. That is how the
chrome drifted into feeling cramped while the document itself felt fine: there was
no shared idea of how much room anything deserves.

This document is the source of truth. The numbers in `Sources/*.swift` and
`Resources/style.css` are meant to *implement* it, not compete with it. When
something looks wrong, change it here first and then follow it into the code.

## The one rule

**The document is the only thing in the window allowed to attract the eye.**

Everything else — sidebar, header, buttons — is navigation furniture. Furniture
earns its keep by being findable when you look for it and invisible when you
don't. Concretely, that means:

- Chrome is greyscale. Colour is reserved for content.
- Nothing in the chrome is separated by a line. Grouping is done with space, and
  with a single small step in surface tint.
- Chrome text sits at secondary or tertiary weight. Only the document uses full
  contrast for body text.
- The eye should land on the document title first, every time.

## Principles

1. **Space is the primary tool.** Before adding a border, a background, or a
   colour to separate two things, add space. Only if space fails do you reach for
   tint. Lines are the last resort and are currently used nowhere in the chrome.
2. **Air around the window controls.** The traffic lights are the first thing you
   see; crowding them makes the whole window feel tight. They get their own band
   that nothing else occupies.
3. **One accent, used rarely.** A second accent colour would force the eye to
   choose. Links, alert rules and in-content selection use the accent; chrome
   never does.
4. **Density is set once, per surface.** The sidebar has one row height, one
   indent step, one horizontal inset. Rows do not get bespoke padding.
5. **Every value comes from the scale.** If a number isn't on the spacing scale,
   it is either a measured platform constraint (documented as such) or a mistake.

## Spacing scale

Base unit 4pt. Use these and nothing between them.

| Token | Value | Used for |
| --- | --: | --- |
| `xs` | 4 | Icon-to-label gaps, inside a control |
| `s` | 8 | Tight grouping, chevron-to-label |
| `m` | 12 | Standard padding inside chrome surfaces |
| `l` | 16 | Between groups of rows; above a section label |
| `xl` | 24 | Between unrelated blocks |
| `xxl` | 32 | Reserved band heights, large separations |

## Layout

### The traffic-light band

Measured on macOS 26, not guessed: the buttons are 14pt, span **x = 9…69**, and
their centre line is **16pt** from the top of the window. Their bottom edge is at
23pt.

**Reserve the top 44pt of the window.** No chrome content sits above that line —
not sidebar rows, not header text. This is the single biggest contributor to
whether the window feels calm or cramped.

An earlier version centred the document header on the buttons' 16pt centre line.
That was the wrong target: it is *technically* aligned and *visually* crowded,
because the header text then sits between the buttons rather than below them. The
reference apps we like all give the buttons their own empty band.

### Zones

| Zone | Value | Notes |
| --- | --: | --- |
| Window top reserved | 44 | Traffic lights only |
| Document header height | 56 | Content centred at 28pt — clear of the buttons |
| Header leading inset, sidebar open | 16 | |
| Header leading inset, sidebar hidden | 84 | Clears x=69 plus `l` |
| Sidebar content top inset | 60 | First row starts below the reserved band |
| Sidebar default width | 264 | Range 200…460 |
| Sidebar horizontal padding | 12 | `m` |
| Document measure | 43rem | ~72 characters |
| Document gutter | 3.25rem | |

## Type

Two ramps, deliberately separate: chrome is quiet and small, content is
comfortable and full-contrast. Chrome uses the system UI font; content has its own
ramp in `style.css`.

| Role | Size | Weight | Colour | Notes |
| --- | --: | --- | --- | --- |
| Section label (root folder) | 10.5 | semibold | tertiary | Uppercase, +0.5 tracking |
| Sidebar row | 13 | regular | primary | |
| Header filename | 13 | medium | primary | |
| Header path | 11 | regular | tertiary | Truncates from the head |
| Quiet action ("Add Folder") | 13 | regular | tertiary | |

Content ramp lives in `Resources/style.css`: 16.5px body at 1.72 line height, and
a display face for headings. Don't reconcile the two — they are different
registers on purpose.

## Colour

Semantic roles only. No component names a raw colour.

| Role | Light | Dark | Where |
| --- | --- | --- | --- |
| `surface-document` | system `textBackgroundColor` | same | Document pane, header |
| `surface-chrome` | document + 3.5% primary | same | Sidebar |
| `text-primary` | system primary | same | Row labels, filename |
| `text-secondary` | system secondary | same | Icons |
| `text-tertiary` | system tertiary | same | Section labels, paths |
| `fill-selected` | 8.5% primary | same | Current file row |
| `fill-hover` | 4.5% primary | same | Row under the pointer |
| `accent` | `#3059c9` | `#86a8ff` | **Content only** |

Two things to note:

- The sidebar is separated from the document by **3.5% tint and nothing else**. No
  border, no shadow, no divider. If the two surfaces ever need more separation than
  that, the fix is more space, not a line.
- Selection in the sidebar is a **neutral** fill, not an accent tint. The current
  file is worth marking, not worth shouting about; an accent-filled row competes
  with the document for attention.

## Components

**Sidebar row.** 32pt tall, 18pt indent per level, 12pt horizontal padding,
8pt-radius fill for hover and selection. Chevron for folders, 13pt wide slot kept
for files so names align. No icons — the chevron carries the structure, and icons
at this density read as clutter.

**Section label (root folder).** Uppercase, tertiary, 10.5pt. `l` (16) of space
above it, except the first one. This space is what makes multiple folders read as
separate groups without a divider.

**Document header.** Filename plus dimmed path, and the sidebar toggle. Shares the
document's background, no bottom border. It is a label, not a toolbar.

**Focus.** No focus rings anywhere: `.focusEffectDisabled()` at the layout root,
and the web view takes first responder at launch. This is a reading window.

**Motion.** Only the sidebar's show/hide is animated (0.2s ease-out). Rows do not
animate on hover; the fill appears immediately.

## Anti-patterns

- A divider anywhere in the chrome.
- An accent-coloured sidebar row, badge, or count.
- A second accent colour.
- Per-component padding that isn't on the scale.
- Aligning chrome text with the traffic lights instead of clearing them.
- Icons added "for scanability" in a list where names already scan.

## Where the tokens live

| Concern | File |
| --- | --- |
| Zone heights, insets, traffic-light constants | `Sources/ViewerLayout.swift` |
| Sidebar density, row and label specs | `Sources/SidebarView.swift` |
| Content type ramp, content colour, callouts, code | `Resources/style.css` |

There is deliberately no shared token file across the Swift/CSS boundary — two
small tables that are read by humans beat a build step that syncs them. The cost
is that this document is the only thing keeping them coherent, which is why
changes start here.
