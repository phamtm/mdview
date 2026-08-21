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
for path in sys.argv[1:]:
    raw = open(path).read()
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
    else:
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
    else:
        print(f"  FAIL {path}: no word count results")
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

print("RENDER TESTS FAILED" if failed else "RENDER TESTS PASSED")
sys.exit(1 if failed else 0)
