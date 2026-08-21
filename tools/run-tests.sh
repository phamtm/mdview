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
# Skipped when the app is already newer than everything that goes into it —
# every source of the bundle and of the binary. There is no parse error left to
# find in a file that has not changed since it last built, and the real-app
# probes below want that same binary either way. Getting this list wrong makes
# tests fail against a stale build, which is loud; it cannot make them flake.
APP="build/MDView.app/Contents/MacOS/MDView"
APP_INPUTS=(Sources Resources web/src web/build.mjs web/package.json build.sh tools/make-icon.swift)
if [ -x "$APP" ] && [ -z "$(find "${APP_INPUTS[@]}" -newer "$APP" -print -quit)" ]; then
  echo "  ok   app and bundle already current"
else
  ./build.sh >/dev/null
  echo "  ok   bundle built from web/src"
fi

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
./build/snapshot Resources sample.md build/shot light >build/diag-light.txt
MDVIEW_BATTERY=theme \
  ./build/snapshot Resources sample.md build/shot dark  >build/diag-dark.txt
MDVIEW_BATTERY=theme MDVIEW_THEME=night \
  ./build/snapshot Resources sample.md build/shot-night dark >build/diag-night.txt
MDVIEW_BATTERY=theme MDVIEW_THEME=vellum \
  ./build/snapshot Resources sample.md build/shot-vellum light >build/diag-vellum.txt
# The harness sets the webview's appearance from its own light|dark argument,
# independent of MDVIEW_THEME, so the four runs above all have the theme and the
# appearance agreeing. This one makes them disagree — the System theme on a dark
# Mac — which is the case that hid the alert-colour bug.
MDVIEW_BATTERY=theme MDVIEW_THEME=system \
  ./build/snapshot Resources sample.md build/shot-system dark >build/diag-system.txt
python3 tools/check-render.py build/diag-light.txt build/diag-dark.txt \
  build/diag-night.txt build/diag-vellum.txt build/diag-system.txt

echo "==> contents rail preview sits beside its tick"
MDVIEW_BATTERY=theme MDVIEW_RAIL=hover MDVIEW_THEME=paper \
  ./build/snapshot Resources sample.md build/shot-hover light >build/diag-hover.txt
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
MDVIEW_BATTERY=theme \
  ./build/snapshot Resources sample.md build/nofm light nofm >build/diag-nofm.txt
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

# The tools above aren't app bundles, so their UserDefaults writes land in a plist
# named after each executable. cfprefsd owns those files and rewrites them after a
# process exits, so ask the daemon to drop the domains rather than deleting files.
for domain in test-workspace snapshot test-panel-animation; do
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$domain.plist"
done
