"""Asserts the headless render produced everything sample.md asks for."""
import json, sys

EXPECT = {
    "headings": lambda v: v >= 8,
    "headingIds": lambda v: v >= 8,
    "codeFigures": lambda v: v == 4,
    "highlighted": lambda v: v > 0,
    "copyButtons": lambda v: v == 4,
    "tables": lambda v: v == 1,
    "tasks": lambda v: v == 2,
    "tasksDone": lambda v: v == 1,
    "mermaidSvg": lambda v: v == 1,
    "details": lambda v: v == 1,
    "imgLoaded": lambda v: v > 0,
    "scriptTagsInDoc": lambda v: v == 0,
    "onerrorAttrs": lambda v: v == 0,
    "pwned": lambda v: v is False,
    # the document carries title and subtitle (asserted below), the titlebar
    # disclosure carries the rest, and the raw yaml is never shown
    "rawFrontmatterLeaked": lambda v: v is False,
    # GFM extras
    "alerts": lambda v: v == 5,
    "alertKinds": lambda v: v == "note,tip,important,warning,caution",
    "alertMarkerLeaked": lambda v: v is False,
    "footnoteRefs": lambda v: v == 2,
    "footnoteItems": lambda v: v == 2,
    "autolinks": lambda v: v >= 2,
    "strikethrough": lambda v: v == 1,
    # contents rail: one tick per heading
    "railTicks": lambda v: v >= 8,
    "railHidden": lambda v: v is False,
    "asciiBlocks": lambda v: v == 1,
    # The column clears the contents rail by 68px. This lived in a duplicate
    # .prose rule for a while and won only by being last in the file.
    "proseLeftPadding": lambda v: v == "68px",
    # Keyboard motion jumps; it must never animate. Asserted as the decision
    # rather than as a measured scroll, because this render is offscreen: rAF
    # never fires there, so every scroll is instant whatever was asked for and a
    # measurement would pass with the bug in place. "auto" is the trap — it
    # inherits `scroll-behavior: smooth` from style.css instead of overriding it,
    # which cost five rapid j presses 666px of their 2000 and put five rapid n
    # presses on the second heading instead of the fifth. See web/src/motion.js.
    "keyboardScrollBehavior": lambda v: v == "instant",
}

# Which render a diagnostics file came from, taken from its name. "system" first:
# that run is also a dark one, and the theme it asks for is what distinguishes it.
def which(path):
    for name in ("system", "night", "vellum", "light", "dark"):
        if name in path:
            return name
    return "paper"


THEME_FOR = {"night": "night", "vellum": "vellum", "system": "system"}
alert_colors = {}

failed = False
# Most checks below reach the same verdict whichever palette is loaded, so one
# render runs them and the rest only probe their theme. The harness says which it
# was, and a file that did not claim the full battery is not asked for those
# results. See `fullBattery` in tools/snapshot.swift.
full_battery = []
for path in sys.argv[1:]:
    raw = open(path).read()
    full = "BATTERY full" in raw
    if full:
        full_battery.append(path)
    # The page posts its outline to the app, which draws the contents panel.
    posted = [line for line in raw.splitlines() if line.startswith("POSTED ")]
    if not posted:
        print(f"  FAIL {path}: page posted nothing to the app")
        failed = True
    else:
        fields = dict(part.split("=", 1) for part in posted[0].removeprefix("POSTED ").split(" "))
        if "outline" not in fields.get("actions", ""):
            print(f"  FAIL {path}: no outline posted (actions: {fields.get('actions')!r})")
            failed = True
        elif int(fields.get("outlineHeadings", -1)) < 8:
            print(f"  FAIL {path}: outline has {fields.get('outlineHeadings')} headings")
            failed = True
        else:
            print(f"  ok   {path}: outline posted ({fields['outlineHeadings']} headings)")
        # The titlebar's word count comes from the page and covers the body only.
        # sample.md has frontmatter, so a count equal to the raw file's means the
        # frontmatter block is being counted again.
        posted_words = int(fields.get("postedWords", -1))
        raw_words = int(fields.get("rawWords", -1))
        if posted_words <= 0:
            print(f"  FAIL {path}: page posted no word count ({posted_words})")
            failed = True
        elif posted_words >= raw_words:
            print(f"  FAIL {path}: word count {posted_words} includes the frontmatter "
                  f"(whole file is {raw_words})")
            failed = True
        else:
            print(f"  ok   {path}: word count excludes frontmatter "
                  f"({posted_words} of {raw_words})")
    if "FRONTMATTER " in raw:
        fm = json.loads(raw.split("FRONTMATTER ", 1)[1].splitlines()[0])
        for failure in fm.get("failures", []):
            print(f"  FAIL {path}: frontmatter parser — {failure}")
            failed = True
        if not fm.get("failures"):
            print(f"  ok   {path}: frontmatter parser (yaml, toml, lists, quotes, crlf, edge cases)")
    elif full:
        print(f"  FAIL {path}: no frontmatter parser results")
        failed = True
    # The word count above only shows that the frontmatter is left out. This is
    # the predicate itself: which characters break a word, and which — a tab, a
    # non-breaking space — deliberately do not. sample.md contains none of them.
    if "WORDCOUNT " in raw:
        wc = json.loads(raw.split("WORDCOUNT ", 1)[1].splitlines()[0])
        for failure in wc.get("failures", []):
            print(f"  FAIL {path}: word count — {failure}")
            failed = True
        if not wc.get("failures"):
            print(f"  ok   {path}: word count separators (space, newlines, crlf; "
                  f"not tab or nbsp)")
    elif full:
        print(f"  FAIL {path}: no word count results")
        failed = True
    # The page tells the app when an input inside it has the keyboard, and the
    # app stands its plain keys down while one does. A report that never arrives
    # leaves that flag stuck: press `/`, type, click a file in the sidebar, and
    # j k g G n N h l / ? are all dead with no beep to explain why.
    if "PAGEFOCUS " in raw:
        focus = json.loads(raw.split("PAGEFOCUS ", 1)[1].splitlines()[0])
        problems = []
        # One report as the page loads, so a reload (⌥⌘R sends no message of its
        # own) re-syncs the app instead of inheriting a stale flag.
        # Each step is judged by the *first* report it produced, not by being the
        # only one. The page also answers a real window focus event with whatever
        # is true at the time, and the harness's own window handling — the resize
        # before a snapshot, bringing the window forward — makes AppKit deliver
        # one of those often enough to land mid-check. That extra report is the
        # page behaving correctly, and requiring an exact sequence failed it as
        # if the app were broken: an intermittent
        # `afterBlur = [False, True, False, True]`. The bug actually being
        # guarded against is a step reporting *nothing*, so that is what to
        # assert.
        def first_new(before, after):
            extra = after[len(before):]
            return extra[0] if extra else None

        if focus["startup"] != [False]:
            problems.append(f"no single false report at startup ({focus['startup']})")
        # Focusing the find bar has to say so, or plain keys would type into it.
        if first_new(focus["startup"], focus["afterOpenFind"]) is not True:
            problems.append(f"opening the find bar did not report focus ({focus['afterOpenFind']})")
        # And the window losing focus has to stand the flag down, which is the
        # half focusin/focusout alone never covered.
        if first_new(focus["afterOpenFind"], focus["afterBlur"]) is not False:
            problems.append(f"a window blur did not report focus false ({focus['afterBlur']})")
        for problem in problems:
            print(f"  FAIL {path}: page focus — {problem}")
        if problems:
            failed = True
        else:
            print(f"  ok   {path}: page focus reported at startup, on the find bar, "
                  f"and on a window blur")
    elif full:
        print(f"  FAIL {path}: no page focus results")
        failed = True
    # `n` at the end of the document, and `N` at the start, must not move. The
    # clamp used to aim at the last (or first) heading instead of standing still,
    # which past the final heading is a jump backwards — 329px in a document with
    # a tail, and the whole document in one with a single heading.
    #
    # Two documents, rendered by the harness for this: sample.md's last heading
    # sits close enough to the bottom that the scroll clamp swallows the bad jump,
    # so it cannot see the bug at all.
    if "STEPCLAMP " in raw:
        clamps = json.loads(raw.split("STEPCLAMP ", 1)[1].splitlines()[0])
        problems = []
        for name, clamp in clamps.items():
            if "error" in clamp:
                problems.append(f"{name}: {clamp['error']}")
                continue
            # Without headroom below the last heading, "aim at the last heading"
            # and "stand still" land on the same pixel and this proves nothing.
            if clamp["bottomHeadroom"] < 200:
                problems.append(f"{name}: only {clamp['bottomHeadroom']}px below the last "
                                "heading — this document cannot show a backwards jump")
            if clamp["afterNext"] != clamp["atBottom"]:
                problems.append(f"{name}: n at the bottom moved "
                                f"{clamp['afterNext'] - clamp['atBottom']}px")
            if clamp["afterNextTwice"] != clamp["atBottom"]:
                problems.append(f"{name}: a second n at the bottom moved to "
                                f"{clamp['afterNextTwice']}")
            if clamp["afterPrevious"] != clamp["atTop"]:
                problems.append(f"{name}: N at the top moved "
                                f"{clamp['afterPrevious'] - clamp['atTop']}px")
            if clamp["afterPreviousTwice"] != clamp["atTop"]:
                problems.append(f"{name}: a second N at the top moved to "
                                f"{clamp['afterPreviousTwice']}")
            # Without this the checks above pass for a step() that does nothing.
            if clamp["afterOneStepFromTop"] <= clamp["atTop"]:
                problems.append(f"{name}: n from the top did not move at all — stepping is "
                                "broken, not clamped")
        for problem in problems:
            print(f"  FAIL {path}: heading step — {problem}")
        if problems:
            failed = True
        else:
            ends = ", ".join(f"{name} holds at y={c['atBottom']} with {c['bottomHeadroom']}px "
                             f"below its last heading" for name, c in clamps.items())
            print(f"  ok   {path}: n and N stand still at the ends ({ends})")
    elif full:
        print(f"  FAIL {path}: no heading step results")
        failed = True
    # Selecting across blocks used to paint the tint as full-window bands, 208px
    # past the column on the left and 177px on the right. Nothing else in this
    # file can see it: WebKit fills the gaps between a selection root's children
    # out to that root's content box, `body` is the selection root and `.prose`
    # is not — so the artefact is in the paint alone. Computed style is the same
    # either way, and getClientRects() never leaves the column even while the
    # bands are on screen. Hence a pixel diff: the same page shot unselected and
    # selected, with every changed pixel outside the column counted.
    if "SELECTION " in raw:
        sel = json.loads(raw.split("SELECTION ", 1)[1].splitlines()[0])
        problems = []
        if "error" in sel:
            problems.append(sel["error"])
        else:
            if sel["blocks"] < 4 or sel["chars"] <= 0:
                problems.append(f"selected {sel['chars']} characters across {sel['blocks']} "
                                "blocks — the gaps between blocks are what paint the bug")
            # Vacuity: with no highlight painted the diff is empty and every
            # check below passes for nothing. WebKit needs a key window and the
            # web view as first responder to paint one at all.
            if sel["insidePixels"] < 1000:
                problems.append(f"only {sel['insidePixels']} pixels changed inside the column — "
                                f"the selection did not paint (windowKey={sel['windowKey']}, "
                                f"firstResponder={sel['firstResponder']}), so this check saw nothing")
            # If the geometry itself left the column, the tint legitimately would
            # too, and the count below would be measuring a different bug.
            if (sel["rectsLeft"] < sel["columnLeft"] - 1
                    or sel["rectsRight"] > sel["columnRight"] + 1):
                problems.append(f"the selection's own rects ({sel['rectsLeft']}–{sel['rectsRight']}) "
                                f"leave the column ({sel['columnLeft']}–{sel['columnRight']}) — "
                                "that is a layout bug, not the paint one")
            if sel["selectionGutterPixels"]:
                problems.append(
                    f"the tint reaches {sel['gutterLeftPx']}px past the column's left edge and "
                    f"{sel['gutterRightPx']}px past its right "
                    f"({sel['selectionGutterPixels']} device pixels: "
                    f"{sel['gutterLeftPixels']} left, {sel['gutterRightPixels']} right). "
                    f"body is `display: {sel['bodyDisplay']}` — a flex column paints no "
                    "selection gaps; see style.css")
        for problem in problems:
            print(f"  FAIL {path}: selection tint — {problem}")
        if problems:
            failed = True
        else:
            print(f"  ok   {path}: selection tint stays inside the column "
                  f"({sel['insidePixels']} pixels painted between {sel['columnLeft']} and "
                  f"{sel['columnRight']}, 0 outside)")
    elif full:
        print(f"  FAIL {path}: no selection tint results")
        failed = True
    data = json.loads(raw.split("DIAGNOSTICS ", 1)[1].splitlines()[0])
    for key, ok in EXPECT.items():
        got = data.get(key)
        if not ok(got):
            print(f"  FAIL {path}: {key} = {got!r}")
            failed = True
    if "file://" not in str(data.get("imgSrc", "")):
        print(f"  FAIL {path}: image src not resolved: {data.get('imgSrc')}")
        failed = True
    if "file://" not in str(data.get("mdLinkHref", "")):
        print(f"  FAIL {path}: local md link not resolved: {data.get('mdLinkHref')}")
        failed = True
    alert_colors[which(path)] = data.get("alertLabelColors") or {}
    expected_theme = THEME_FOR.get(which(path), "paper")
    if data.get("appliedTheme") != expected_theme:
        print(f"  FAIL {path}: theme not applied — asked {expected_theme}, "
              f"page has {data.get('appliedTheme')!r}")
        failed = True
    # Layout settings have to reach the page, not just the chrome.
    if data.get("appliedAlign") != "justify":
        print(f"  FAIL {path}: alignment did not apply ({data.get('appliedAlign')!r})")
        failed = True
    if data.get("appliedMeasure") != "700px":
        print(f"  FAIL {path}: measure did not apply ({data.get('appliedMeasure')!r})")
        failed = True

    # Box-drawing connects only when the line box equals the glyph height.
    leading = str(data.get("asciiLeading", ""))
    if " / " in leading:
        line, size = (float(part.replace("px", "")) for part in leading.split(" / "))
        if abs(line - size) > 0.5:
            print(f"  FAIL {path}: ascii block leading {line}px != font size {size}px "
                  f"— box-drawing will break into dashes")
            failed = True
    else:
        print(f"  FAIL {path}: no ascii block to check ({leading})")
        failed = True
    if data.get("frontmatterSubtitle") != "A small, local Markdown viewer for macOS":
        print(f"  FAIL {path}: subtitle = {data.get('frontmatterSubtitle')!r}")
        failed = True
    if data.get("frontmatterTitle") != "MDView":
        print(f"  FAIL {path}: frontmatter title = {data.get('frontmatterTitle')!r}")
        failed = True
    print(f"  ok   {path}: markdown, code, tables, tasks, diagram, image, sanitiser,")
    print(f"       frontmatter (title + subtitle in doc, fields in titlebar), "
          f"alerts ({data.get('alertKinds')}), footnotes, autolinks")

    # The second render, which everything above is blind to: it renders once and
    # then snapshots. A first render that works and a later one that silently
    # does nothing look identical from a single shot — and that is the whole
    # product (save the file, change a setting, click a link).
    lines = [l for l in raw.splitlines() if l.startswith("RERENDER ")]
    if not lines:
        print(f"  FAIL {path}: no second render (harness did not re-render)")
        failed = True
    else:
        r = json.loads(lines[0].removeprefix("RERENDER "))
        problems = []
        if r["asked"] == r["firstTheme"]:
            problems.append(f"harness asked for the same theme twice ({r['asked']}) — "
                            "this check cannot see a theme that never changes")
        if r["appliedTheme"] != r["asked"]:
            problems.append(f"theme is still {r['appliedTheme']!r}, asked {r['asked']!r}")
        # sample.md has 12 headings; the second document has one h1 and three h2s.
        if (r["h1"], r["h2"]) != (1, 3):
            problems.append(f"document is not the second one (h1={r['h1']}, h2={r['h2']}, "
                            "want 1 and 3)")
        # Four, not eight or sixteen: a rail that appends instead of replacing,
        # or a second set of listeners, leaves the first document's marks behind.
        if r["railTicks"] != 4:
            problems.append(f"rail has {r['railTicks']} ticks, want 4 — state from the "
                            "first render leaked into the second")
        if r["railHidden"]:
            problems.append("rail hidden after the second render")
        if r["outlineHeadings"] != 4:
            problems.append(f"posted outline has {r['outlineHeadings']} headings, want 4")
        if r["outlineTitles"] != "Second Render,Alpha,Beta,Gamma":
            problems.append(f"posted outline is {r['outlineTitles']!r}, not the second "
                            "document's headings")
        for problem in problems:
            print(f"  FAIL {path}: second render — {problem}")
        if problems:
            failed = True
        else:
            print(f"  ok   {path}: second render replaced the first "
                  f"({r['firstTheme']} → {r['asked']}, 4 ticks, 4 outline rows)")

# The System theme on a dark Mac is the only combination the harness renders
# where the theme and the appearance disagree, and for a long time it kept the
# light alert accents on a near-black ground — 2.2:1 on 10px label text. The
# stylesheet needs a `:root:not([data-theme])` twin inside the
# prefers-color-scheme block for every `[data-theme="night"]` rule.
DARK_ALERTS = ("note", "tip", "important", "warning", "caution")
if "system" not in alert_colors or "night" not in alert_colors:
    print("  FAIL no System-theme-on-dark render to check the alert accents against")
    failed = True
else:
    system, night, light = (alert_colors.get(k, {}) for k in ("system", "night", "light"))
    # Without this the check below passes vacuously if the dark overrides are
    # deleted outright, because then every theme agrees on the light colour.
    same = [k for k in DARK_ALERTS if light and light.get(k) == night.get(k)]
    if same:
        print(f"  FAIL dark and light alert accents are identical for {same} — "
              "the check below can no longer see the bug it exists for")
        failed = True
    for kind in DARK_ALERTS:
        if system.get(kind) != night.get(kind):
            leak = " (still the light one)" if light.get(kind) == system.get(kind) else ""
            print(f"  FAIL alert-{kind} on the System theme in dark mode is "
                  f"{system.get(kind)}{leak}, not the dark accent {night.get(kind)}")
            failed = True
    # The other half of the same rule: the dark overrides are for the *System*
    # theme only. Paper on a dark Mac has its own light ground and must keep the
    # light accents — drop the `:not([data-theme])` guard and the check above
    # still passes while Paper turns washed out.
    paper_dark = alert_colors.get("dark") or {}
    leaked = [k for k in DARK_ALERTS if light and paper_dark.get(k) != light.get(k)]
    if leaked:
        print(f"  FAIL the Paper theme on a dark Mac picked up the dark alert accents "
              f"for {leaked} — the `:not([data-theme])` guard is missing")
        failed = True
    if not failed:
        print("  ok   System theme on a dark Mac uses the dark alert accents, "
              "Paper on a dark Mac keeps the light ones")

# Without this, setting MDVIEW_BATTERY=theme on every render would drop the
# frontmatter parser, the word count, page focus, the heading clamp, the
# selection gutter and the second render — and the suite would go green having
# checked none of them.
if not full_battery:
    print("  FAIL no render ran the full battery — the frontmatter parser, the word count, "
          "page focus, the heading clamp and the selection gutter were all skipped. "
          "See MDVIEW_BATTERY in tools/run-tests.sh")
    failed = True
elif len(full_battery) > 1:
    # Not wrong, just slow: each extra one is ~3.5s for an answer already known.
    print(f"  ok   theme-independent checks ran in {', '.join(full_battery)} "
          f"({len(full_battery)} runs — one is enough)")
else:
    print(f"  ok   theme-independent checks ran once, in {full_battery[0]}")

print("RENDER TESTS FAILED" if failed else "RENDER TESTS PASSED")
sys.exit(1 if failed else 0)
