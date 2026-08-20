"""Asserts the headless render produced everything sample.md asks for."""
import json, sys

EXPECT = {
    "headings": lambda v: v >= 8,
    "headingIds": lambda v: v >= 8,
    "codeFigures": lambda v: v == 3,
    "highlighted": lambda v: v > 0,
    "copyButtons": lambda v: v == 3,
    "tables": lambda v: v == 1,
    "tasks": lambda v: v == 2,
    "tasksDone": lambda v: v == 1,
    "mermaidSvg": lambda v: v == 1,
    "details": lambda v: v == 1,
    "imgLoaded": lambda v: v > 0,
    "scriptTagsInDoc": lambda v: v == 0,
    "onerrorAttrs": lambda v: v == 0,
    "pwned": lambda v: v is False,
    # frontmatter
    "frontmatterFields": lambda v: v == 5,          # subtitle, date, status, tags, authors
    "frontmatterPills": lambda v: v == 4,           # 3 tags + 1 author
    "rawFrontmatterLeaked": lambda v: v is False,
    # GFM extras
    "alerts": lambda v: v == 5,
    "alertKinds": lambda v: v == "note,tip,important,warning,caution",
    "alertMarkerLeaked": lambda v: v is False,
    "footnoteRefs": lambda v: v == 2,
    "footnoteItems": lambda v: v == 2,
    "autolinks": lambda v: v >= 2,
    "strikethrough": lambda v: v == 1,
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
    if data.get("frontmatterTitle") != "MDView":
        print(f"  FAIL {path}: frontmatter title = {data.get('frontmatterTitle')!r}")
        failed = True
    print(f"  ok   {path}: markdown, code, tables, tasks, diagram, image, sanitiser,")
    print(f"       frontmatter ({data.get('frontmatterFields')} fields), "
          f"alerts ({data.get('alertKinds')}), footnotes, autolinks")

print("RENDER TESTS FAILED" if failed else "RENDER TESTS PASSED")
sys.exit(1 if failed else 0)
