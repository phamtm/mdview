#!/bin/bash
# Writes every PNG the harnesses can produce, for looking at.
#
# Not a test: nothing reads these images and there is nothing here that can fail.
# The window render lived in run-tests.sh for a while and cost 16s a run without
# ever being able to catch a regression; the document renders still happen in the
# suite, but the capture itself is off there because holding the page still for
# it was the most expensive moment in the run.
#
# What the *real* window looks like is checked by tools/check-window-chrome.sh,
# which asks the running app instead.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/window-tool

SRC=()
for file in Sources/*.swift; do
  [ "$file" = "Sources/MDViewApp.swift" ] || SRC+=("$file")
done
cp tools/snapshot-window.swift build/window-tool/main.swift
swiftc -Onone -wmo -o build/snapshot-window "${SRC[@]}" build/window-tool/main.swift

./build/snapshot-window build/window-light.png light
./build/snapshot-window build/window-dark.png dark

# The document itself, in each theme. MDVIEW_SHOTS is what turns the capture back
# on; MDVIEW_BATTERY=theme skips the checks, since this is not a test run.
mkdir -p build/render-tool
cp tools/snapshot.swift build/render-tool/main.swift
swiftc -Onone -wmo -o build/snapshot "${SRC[@]}" build/render-tool/main.swift
export MDVIEW_SHOTS=1 MDVIEW_BATTERY=theme
./build/snapshot Resources sample.md build/shot light >/dev/null
./build/snapshot Resources sample.md build/shot dark >/dev/null
MDVIEW_THEME=night ./build/snapshot Resources sample.md build/shot-night dark >/dev/null
MDVIEW_THEME=vellum ./build/snapshot Resources sample.md build/shot-vellum light >/dev/null

# A bare executable's UserDefaults land in a plist named after it, and cfprefsd
# rewrites those after the process exits — so ask the daemon to drop the domains.
for domain in snapshot-window snapshot; do
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$domain.plist"
done

echo "wrote build/window-{light,dark}.png and build/shot*-{light,dark}.png"
