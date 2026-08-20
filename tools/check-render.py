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
    # frontmatter: the document carries title and subtitle, the titlebar
    # disclosure carries the rest, so nothing is shown in two places
    "frontmatterFields": lambda v: v == 0,
    "frontmatterPills": lambda v: v == 0,
    "rawFrontmatterLeaked": lambda v: v is False,
    # GFM extras
    "alerts": lambda v: v == 5,
    "alertKinds": lambda v: v == "note,tip,important,warning,caution",
    "alertMarkerLeaked": lambda v: v is False,
    "footnoteRefs": lambda v: v == 2,
    "footnoteItems": lambda v: v == 2,
    "autolinks": lambda v: v >= 2,
    "strikethrough": lambda v: v == 1,
    # contents rail: one tick and one panel row per heading
    "railTicks": lambda v: v >= 8,
    "railRows": lambda v: v >= 8,
    "railHidden": lambda v: v is False,
    "asciiBlocks": lambda v: v == 1,
}

failed = False
for path in sys.argv[1:]:
    raw = open(path).read()
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
    expected_theme = "night" if "night" in path else ("vellum" if "vellum" in path else "paper")
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

print("RENDER TESTS FAILED" if failed else "RENDER TESTS PASSED")
sys.exit(1 if failed else 0)
