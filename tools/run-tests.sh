#!/bin/bash
# Runs the checks that a screenshot can't cover.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

# Every harness has top-level code, so it can't compile alongside MDViewApp.swift
# (which owns @main). One list, rather than four that drift when a file is added.
SRC=()
for file in Sources/*.swift; do
  [ "$file" = "Sources/MDViewApp.swift" ] || SRC+=("$file")
done

# Each harness is the same ~16 files plus its own main.swift, and building them
# one at a time with -O was 48s — more than every test in this file put together.
# Two things fix it, and neither changes what is checked:
#   -Onone -wmo   nothing here measures throughput, and the runs come out the
#                 same speed either way, so optimising the code is pure cost.
#                 -wmo then makes it a single frontend job: 8.0s -> 2.7s.
#   all at once   the compiles are independent, so they overlap. Together with
#                 build.sh below, the whole compile phase is ~6s.
# The animation sampler is the one to watch here, since it asserts on timing —
# it passes unoptimised, with the same sample counts.
build_harness() {
  local name="$1" dir="build/$1-tool"
  shift
  # Nothing to do if the binary is already newer than every file that goes into
  # it. This is what makes the common loop cheap: edit web/src or a check script,
  # rerun, and no Swift is compiled at all.
  if [ -x "build/$name" ] \
    && [ -z "$(find "$@" "tools/$name.swift" -newer "build/$name" -print -quit)" ]; then
    return
  fi
  mkdir -p "$dir"
  cp "tools/$name.swift" "$dir/main.swift"
  swiftc -Onone -wmo -o "build/$name" "$@" "$dir/main.swift" >"build/$name.build.log" 2>&1
}

# The watcher harness takes one source file, not the whole app.
build_harness test-watcher Sources/FileWatcher.swift &
compiling="$!"
for harness in test-workspace test-shortcuts test-key-delivery test-panel-animation snapshot; do
  build_harness "$harness" "${SRC[@]}" &
  compiling="$compiling $!"
done

echo "==> web bundle"
# esbuild is the syntax check: it fails the build on a parse error. This also
# guarantees the tests below run against the current web/src.
#
# build.sh decides for itself what is already current — it skips the Swift
# compile when Sources have not changed, which is 10 of its 12 seconds. Keeping a
# second copy of "what the app depends on" here meant two lists to hold in step,
# so there is only the one, in the script that does the building.
./build.sh >/dev/null
echo "  ok   bundle built from web/src"

echo "==> harnesses"
failed=""
for pid in $compiling; do
  wait "$pid" || failed="yes"
done
if [ -n "$failed" ]; then
  echo "  FAIL a harness did not compile:"
  for log in build/*.build.log; do
    grep -q 'error:' "$log" && { echo "  --- $log"; grep -A3 'error:' "$log" | head -20; }
  done
  exit 1
fi
echo "  ok   all harnesses built"

# "auto" does not mean "no animation": it inherits `scroll-behavior: smooth`
# from style.css rather than overriding it, which is how every keyboard motion
# came to animate and how rapid presses lost most of their travel. Only
# "instant" jumps. The keyboard paths take their value from the one constant in
# web/src/motion.js, and tools/check-render.py asserts that constant is
# "instant" — this covers the other way back in, a literal at a call site.
# The leading class excludes comment lines — `*` in a block comment, `/` in a
# line comment — so the prose explaining the trap does not trip it.
if grep -nE '^[^*/]*behavior: *"auto"' web/src/*.js; then
  echo "  FAIL the scroll above asks for \"auto\" — use KEYBOARD_SCROLL_BEHAVIOR" \
    "(web/src/motion.js) for keyboard motion, or \"smooth\" for a mouse-driven jump"
  exit 1
fi
echo "  ok   no scroll asks for \"auto\""

echo "==> payload contract"
./tools/check-payload.sh

echo "==> file watcher"
./build/test-watcher

echo "==> sidebar tree"
./build/test-workspace

echo "==> shortcut table and resolver"
./build/test-shortcuts

echo "==> key delivery (offscreen window, synthesised events)"
./build/test-key-delivery

echo "==> panels slide, from every path (offscreen window, sampled widths)"
# An animation is hard to assert on, so this samples the drawn width every 10ms
# and counts the values between the two ends. It is here because the *thing* it
# catches is silent: the titlebar buttons toggled the panels with no animation at
# all while the keys animated, and nothing in the code read wrong.
./build/test-panel-animation

echo "==> window chrome (real app)"
./tools/check-window-chrome.sh

echo "==> theme reaches the document (real app)"
./tools/check-theme.sh

# The full-window offscreen render moved to tools/shots.sh. It only ever wrote
# PNGs that nothing read, so it could not fail — 16s a run for no coverage. What
# the real window looks like is check-window-chrome.sh above.

echo "==> renderer"
# Every theme, not just the default: the Vellum and Colophon palettes are built
# from color-mix(), and a token that resolves to a syntax mermaid cannot parse
# breaks diagrams in that theme alone.
#
# Only the first render runs the theme-independent half of the checks — the
# frontmatter parser, the word count, page focus, the heading clamp, the
# selection gutter, the second render. Those reach the same verdict whichever
# palette is loaded, and repeating them five times was ~3.5s a render for the
# same answer. MDVIEW_BATTERY=theme runs the palette probe alone.
# check-render.py fails if this ends up on *every* render, so the coverage
# cannot be dropped by accident.
#
# The renders are separate processes, each writing its own diagnostics file and
# sharing no state — not even a preferences domain, since this harness writes no
# defaults at all — so they run at once. Nothing about the waiting changed: every
# fixed wait inside a render is the same length it was, they just overlap. The
# hover and frontmatter-off runs join in, and their checks follow further down.
renders=()
start_render() {
  local diag="$1"
  shift
  "$@" >"$diag" &
  renders+=("$!:$diag")
}
start_render build/diag-light.txt \
  ./build/snapshot Resources sample.md build/shot light
start_render build/diag-dark.txt env MDVIEW_BATTERY=theme \
  ./build/snapshot Resources sample.md build/shot dark
start_render build/diag-night.txt env MDVIEW_BATTERY=theme MDVIEW_THEME=night \
  ./build/snapshot Resources sample.md build/shot-night dark
start_render build/diag-vellum.txt env MDVIEW_BATTERY=theme MDVIEW_THEME=vellum \
  ./build/snapshot Resources sample.md build/shot-vellum light
# The harness sets the webview's appearance from its own light|dark argument,
# independent of MDVIEW_THEME, so the four runs above all have the theme and the
# appearance agreeing. This one makes them disagree — the System theme on a dark
# Mac — which is the case that hid the alert-colour bug.
start_render build/diag-system.txt env MDVIEW_BATTERY=theme MDVIEW_THEME=system \
  ./build/snapshot Resources sample.md build/shot-system dark
# The rail hover and the frontmatter-off render, checked after check-render.py.
start_render build/diag-hover.txt \
  env MDVIEW_BATTERY=theme MDVIEW_RAIL=hover MDVIEW_THEME=paper \
  ./build/snapshot Resources sample.md build/shot-hover light
start_render build/diag-nofm.txt env MDVIEW_BATTERY=theme \
  ./build/snapshot Resources sample.md build/nofm light nofm
# An .html file, which the page must hand straight to the sanitiser instead of
# through marked, and one whose first line is `---` so the frontmatter split is
# not silently applied to it. Both checked after check-render.py, below.
start_render build/diag-html.txt env MDVIEW_BATTERY=theme \
  ./build/snapshot Resources tools/sample.html build/html light
start_render build/diag-html-dashes.txt env MDVIEW_BATTERY=theme \
  ./build/snapshot Resources tools/sample-dashes.html build/html-dashes light
start_render build/diag-html-diagram.txt env MDVIEW_BATTERY=theme \
  ./build/snapshot Resources tools/sample-diagram.html build/html-diagram light

for entry in "${renders[@]}"; do
  wait "${entry%%:*}" || { echo "  FAIL ${entry#*:}: the render exited non-zero"; exit 1; }
done

python3 tools/check-render.py build/diag-light.txt build/diag-dark.txt \
  build/diag-night.txt build/diag-vellum.txt build/diag-system.txt

echo "==> contents rail preview sits beside its tick"
python3 - <<'CHECK'
import json
raw = open("build/diag-hover.txt").read()
data = json.loads(raw.split("DIAGNOSTICS ", 1)[1].splitlines()[0])
card, tick = data["railCardCentre"], data["railTickCentre"]
if card < 0:
    print("  FAIL hover preview did not appear")
    raise SystemExit(1)
# It is positioned against the rail zone; using offsetTop instead once put it up
# at the top of the window, far from the tick it describes.
if abs(card - tick) > 6:
    print(f"  FAIL preview centre {card} is not beside its tick {tick}")
    raise SystemExit(1)
print(f"  ok   preview centred on its tick ({card} vs {tick})")
CHECK

echo "==> frontmatter hidden (View > Show Frontmatter off)"
python3 - <<'CHECK'
import json
raw = open("build/diag-nofm.txt").read()
data = json.loads(raw.split("DIAGNOSTICS ", 1)[1].splitlines()[0])
problems = []
# With the setting off the document keeps no head of its own: no title, no subtitle.
if data["frontmatterTitle"] != "none": problems.append(f"title still shown ({data['frontmatterTitle']!r})")
if data["frontmatterSubtitle"] != "none": problems.append(f"subtitle still shown ({data['frontmatterSubtitle']!r})")
if data["rawFrontmatterLeaked"]: problems.append("raw yaml leaked into the document")
if data["headings"] < 8: problems.append(f"body lost headings ({data['headings']})")
for p in problems: print(f"  FAIL {p}")
print("  ok   header hidden, body intact" if not problems else "FRONTMATTER-OFF TESTS FAILED")
raise SystemExit(1 if problems else 0)
CHECK

echo "==> an html document is displayed, and nothing more"
python3 - <<'CHECK'
import json

def read(path):
    raw = open(path).read()
    data = json.loads(raw.split("DIAGNOSTICS ", 1)[1].splitlines()[0])
    posted = [l for l in raw.splitlines() if l.startswith("POSTED ")]
    fields = dict(p.split("=", 1) for p in posted[0].removeprefix("POSTED ").split(" ")) if posted else {}
    return data, fields

problems = []
data, fields = read("build/diag-html.txt")

# --- it is displayed as html -------------------------------------------------
# The page reports which parser it used, which catches Swift sending the wrong
# format. It cannot catch the branch itself going wrong, being read from the same
# flag the branch reads, so two tripwires cover that: tools/sample.html indents a
# paragraph four spaces, which markdown turns into a code block with the tags
# showing, and puts `~~this~~` in loose text between HTML blocks, which is where
# markdown still does inline work.
if data["appliedFormat"] != "html":
    problems.append(f"page rendered it as {data['appliedFormat']!r}")
if data["codeFigures"]:
    problems.append(f"{data['codeFigures']} code figure(s) — the indented paragraph went through marked")
if data["strikethrough"]:
    problems.append(f"{data['strikethrough']} strikethrough(s) — loose text went through marked")
if data["tables"] != 1: problems.append(f"{data['tables']} tables, want 1")
if data["headings"] != 5: problems.append(f"{data['headings']} h2s in the document, want 5")
if data["headingIds"] != 5: problems.append(f"{data['headingIds']} h2s carry an id, want 5")
# Six heading anchors — one h1 and five h2s — each marked as the viewer's own, so
# the find bar leaves the "#" out of the heading's words.
if data["chromeMarked"] != 6:
    problems.append(f"{data['chromeMarked']} elements marked as chrome, want 6")

# --- safely ------------------------------------------------------------------
# Both formats go through DOMPurify, which is why skipping the parser cannot also
# skip the stripping.
if data["scriptTagsInDoc"]: problems.append(f"{data['scriptTagsInDoc']} script tag(s) survived")
if data["onerrorAttrs"]: problems.append(f"{data['onerrorAttrs']} onerror attribute(s) survived")
if data["pwned"]: problems.append("injected script ran")

# Local paths resolve against the file, in all three attributes that carry one.
# srcset matters most and is the least obvious: the spec prefers it over src, so
# leaving it relative used to *lose* a picture that resolving src alone got right.
if data["imgLoaded"] != 220: problems.append(f"first image is {data['imgLoaded']}px wide, want 220")
for srcset in data["srcsetAttrs"].split(" | "):
    if not srcset.startswith("file://"):
        problems.append(f"srcset is still relative ({srcset!r})")
    elif "/Resources/" in srcset:
        problems.append(f"srcset resolved into the app bundle ({srcset!r})")
    # One candidate, not two: a URL may contain a comma, `?w=100,200` being a
    # legal query, so splitting the list on commas broke a valid srcset in half.
    if srcset.count("file://") != 1:
        problems.append(f"srcset is not one candidate ({srcset!r}) — a comma inside "
                        "the URL was treated as a candidate separator")
if not data["posterAttr"].startswith("file://"):
    problems.append(f"poster is still relative ({data['posterAttr']!r})")

# --- and nothing more --------------------------------------------------------
# No outline, no rail, no frontmatter, no word count. An HTML file's headings are
# as likely to be a nav bar or a footer as they are sections — a saved page with a
# three-heading article gave a seven-row contents panel — and "how many words" has
# no honest answer for a page.
if data["railTicks"]: problems.append(f"rail has {data['railTicks']} ticks, want none")
if not data["railHidden"]: problems.append("the rail is showing for an html document")
if int(fields.get("outlineHeadings", -1)):
    problems.append(f"posted an outline of {fields.get('outlineHeadings')} rows")
if data["frontmatterTitle"] != "none" or data["frontmatterSubtitle"] != "none":
    problems.append(f"a frontmatter header was drawn "
                    f"({data['frontmatterTitle']!r}/{data['frontmatterSubtitle']!r})")
# -1 is the harness's "never posted a count". The count must be *absent* rather
# than zero or unsent: Swift reads it as an optional and deliberately keeps the
# last one on open, so saying nothing would leave the previous file's number up.
if int(fields.get("postedWords", -1)) != -1:
    problems.append(f"posted a word count of {fields.get('postedWords')} for an html file")

# --- a `---` first line is frontmatter in markdown and nothing in HTML -------
# Splitting it anyway ate the first heading and the paragraph under it, silently.
dashes, _ = read("build/diag-html-dashes.txt")
if dashes["appliedFormat"] != "html":
    problems.append(f"dashes fixture rendered as {dashes['appliedFormat']!r}")
if dashes["h1s"] != 1:
    problems.append(f"a --- first line cost the html file its h1 ({dashes['h1s']} left) — "
                    "the frontmatter split was applied to a format that has none")

# --- drawing a diagram rebuilds the rail, which is a second way back ---------
diagram, _ = read("build/diag-html-diagram.txt")
if diagram["mermaidSvg"] != 1:
    problems.append(f"the diagram fixture drew {diagram['mermaidSvg']} diagrams, want 1 — "
                    "without one it cannot reach the rebuild it exists to check")
if diagram["railTicks"] or not diagram["railHidden"]:
    problems.append(f"the rail came back after the diagram redrew "
                    f"({diagram['railTicks']} ticks) — the rebuild is not gated")

for p in problems: print(f"  FAIL {p}")
if problems:
    print("HTML TESTS FAILED")
    raise SystemExit(1)
print(f"  ok   html displayed ({data['headings']} headings, {data['tables']} table, "
      f"src/srcset/poster resolved), sanitised, and nothing more: no outline, no rail, "
      f"no frontmatter, no word count")
CHECK

# The tools above aren't app bundles, so their UserDefaults writes land in a plist
# named after each executable. cfprefsd owns those files and rewrites them after a
# process exits, so ask the daemon to drop the domains rather than deleting files.
for domain in test-workspace snapshot test-panel-animation; do
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$domain.plist"
done
