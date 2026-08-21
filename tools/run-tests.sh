#!/bin/bash
# Runs the checks that a screenshot can't cover.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

# Every harness has top-level code, so it can't compile alongside MDViewApp.swift
# (which owns @main). One list, rather than four that drift when a file is added.
SRC=$(ls Sources/*.swift | grep -v 'MDViewApp.swift')

echo "==> web bundle"
# esbuild is the syntax check: it fails the build on a parse error. This also
# guarantees the tests below run against the current web/src.
./build.sh >/dev/null
echo "  ok   bundle built from web/src"

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
# swiftc only allows top-level code in a file called main.swift
cp tools/test-watcher.swift build/main.swift
swiftc -O -o build/test-watcher Sources/FileWatcher.swift build/main.swift
./build/test-watcher

echo "==> sidebar tree"
mkdir -p build/workspace-tool
cp tools/test-workspace.swift build/workspace-tool/main.swift
swiftc -O -o build/test-workspace $SRC build/workspace-tool/main.swift
./build/test-workspace

echo "==> shortcut table and resolver"
mkdir -p build/shortcuts-tool
cp tools/test-shortcuts.swift build/shortcuts-tool/main.swift
swiftc -O -o build/test-shortcuts $SRC build/shortcuts-tool/main.swift
./build/test-shortcuts

echo "==> key delivery (offscreen window, synthesised events)"
mkdir -p build/keys-tool
cp tools/test-key-delivery.swift build/keys-tool/main.swift
swiftc -O -o build/test-key-delivery $SRC build/keys-tool/main.swift
./build/test-key-delivery

echo "==> panels slide, from every path (offscreen window, sampled widths)"
# An animation is hard to assert on, so this samples the drawn width every 10ms
# and counts the values between the two ends. It is here because the *thing* it
# catches is silent: the titlebar buttons toggled the panels with no animation at
# all while the keys animated, and nothing in the code read wrong.
mkdir -p build/anim-tool
cp tools/test-panel-animation.swift build/anim-tool/main.swift
swiftc -O -o build/test-panel-animation $SRC build/anim-tool/main.swift
./build/test-panel-animation

echo "==> window chrome (real app)"
./tools/check-window-chrome.sh

echo "==> theme reaches the document (real app)"
./tools/check-theme.sh

echo "==> window layout"
mkdir -p build/window-tool
cp tools/snapshot-window.swift build/window-tool/main.swift
swiftc -O -o build/snapshot-window $SRC build/window-tool/main.swift
./build/snapshot-window build/window-light.png light
./build/snapshot-window build/window-dark.png dark

echo "==> renderer"
# Every theme, not just the default: the Vellum and Colophon palettes are built
# from color-mix(), and a token that resolves to a syntax mermaid cannot parse
# breaks diagrams in that theme alone.
mkdir -p build/render-tool
cp tools/snapshot.swift build/render-tool/main.swift
swiftc -O -o build/snapshot $SRC build/render-tool/main.swift
./build/snapshot Resources sample.md build/shot light >build/diag-light.txt
./build/snapshot Resources sample.md build/shot dark  >build/diag-dark.txt
MDVIEW_THEME=night ./build/snapshot Resources sample.md build/shot-night dark \
  >build/diag-night.txt
MDVIEW_THEME=vellum ./build/snapshot Resources sample.md build/shot-vellum light \
  >build/diag-vellum.txt
# The harness sets the webview's appearance from its own light|dark argument,
# independent of MDVIEW_THEME, so the four runs above all have the theme and the
# appearance agreeing. This one makes them disagree — the System theme on a dark
# Mac — which is the case that hid the alert-colour bug.
MDVIEW_THEME=system ./build/snapshot Resources sample.md build/shot-system dark \
  >build/diag-system.txt
python3 tools/check-render.py build/diag-light.txt build/diag-dark.txt \
  build/diag-night.txt build/diag-vellum.txt build/diag-system.txt

echo "==> contents rail preview sits beside its tick"
MDVIEW_RAIL=hover MDVIEW_THEME=paper ./build/snapshot Resources sample.md build/shot-hover light \
  >build/diag-hover.txt
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
for domain in test-workspace snapshot-window snapshot test-panel-animation; do
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$domain.plist"
done
