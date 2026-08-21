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

echo "==> an html document renders as html, not as markdown"
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

# The page says which parser it used, so this is asserted rather than inferred.
if data["appliedFormat"] != "html":
    problems.append(f"page rendered it as {data['appliedFormat']!r}")
# And two independent tripwires for the parser having run anyway, because the
# flag above could be right while the branch is wrong. tools/sample.html indents
# a paragraph four spaces, which markdown turns into a code block with the tags
# showing; and it puts `~~this~~` in loose text between HTML blocks, which is
# where markdown still does inline work.
if data["codeFigures"]:
    problems.append(f"{data['codeFigures']} code figure(s) — the indented paragraph went through marked")
if data["strikethrough"]:
    problems.append(f"{data['strikethrough']} strikethrough(s) — loose text went through marked")

# The rest of the render still has to work.
if data["tables"] != 1: problems.append(f"{data['tables']} tables, want 1")
if data["headings"] != 4: problems.append(f"{data['headings']} h2s, want 4")
if data["headingIds"] != 4: problems.append(f"{data['headingIds']} h2s carry an id, want 4")
if data["railTicks"] != 5: problems.append(f"rail has {data['railTicks']} ticks, want 5")
# The first image in the document is the plain `src` one. The `srcset` one after
# it is the case that used to break: the spec prefers srcset over src, so leaving
# it unresolved pointed inside the app bundle and lost a picture that resolving
# src alone had got right.
if data["imgLoaded"] != 220: problems.append(f"first image is {data['imgLoaded']}px wide, want 220")
# Two of the three images must paint: the `src` one and the `srcset` one. The
# third points at a file that is not there on purpose, to fire the onerror the
# sanitiser has to have stripped.
if data["imagesPainted"] != 2:
    problems.append(f"{data['imagesPainted']} of 2 images painted")
# The srcset has to have been rewritten to an absolute path under the document's
# own directory. Asserted on the attribute and not on whether the picture
# appeared: `../sample-image.png` reaches the same file from the page's directory
# as from the fixture's, so a load proves nothing here.
srcset = data["srcsetAttr"]
if not srcset.startswith("file://"):
    problems.append(f"srcset is still relative ({srcset!r}) — it resolves against "
                    "the page inside the app bundle, and the spec prefers it over src")
elif "/Resources/" in srcset:
    problems.append(f"srcset resolved into the app bundle ({srcset!r})")

# Sanitising is the half that does not change between the two formats.
if data["scriptTagsInDoc"]: problems.append(f"{data['scriptTagsInDoc']} script tag(s) survived")
if data["onerrorAttrs"]: problems.append(f"{data['onerrorAttrs']} onerror attribute(s) survived")
if data["pwned"]: problems.append("injected script ran")

# Pinned, not just "less than the file": the count comes off the rendered
# document, so it has to break the source apart at a block edge (the tight
# `<ul><li>alpha</li><li>bravo</li>` is three words, not one) and hold a phrase
# together (`a<em>b</em>c` is one, not three). A bound alone passed both bugs.
words, raw_words = int(fields.get("postedWords", -1)), int(fields.get("rawWords", -1))
if (words, raw_words) != (104, 188):
    problems.append(f"word count is {words} of {raw_words}, want 104 of 188")

# A `---` first line is frontmatter in markdown and nothing at all in HTML.
# Splitting one anyway ate the first heading and paragraph in silence.
dashes, dash_fields = read("build/diag-html-dashes.txt")
if dashes["appliedFormat"] != "html":
    problems.append(f"dashes fixture rendered as {dashes['appliedFormat']!r}")
if int(dash_fields.get("outlineHeadings", -1)) != 2:
    problems.append(f"a --- first line cost the html file a heading "
                    f"({dash_fields.get('outlineHeadings')} of 2 left)")
if int(dash_fields.get("postedWords", -1)) != 15:
    problems.append(f"dashes fixture counts {dash_fields.get('postedWords')} words, want 15")

for p in problems: print(f"  FAIL {p}")
if problems:
    print("HTML TESTS FAILED")
    raise SystemExit(1)
print(f"  ok   parsed as html (no code figure, no strikethrough), {data['tables']} table, "
      f"{data['headings']} headings, src and srcset both resolved, sanitised, "
      f"{words} words of text not {raw_words} of source, and a --- first line costs it nothing")
CHECK

# The tools above aren't app bundles, so their UserDefaults writes land in a plist
# named after each executable. cfprefsd owns those files and rewrites them after a
# process exits, so ask the daemon to drop the domains rather than deleting files.
for domain in test-workspace snapshot test-panel-animation; do
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$domain.plist"
done
