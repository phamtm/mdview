#!/bin/bash
# Renders the whole window offscreen, light and dark, for looking at.
#
# Not a test: nothing reads the PNGs it writes, and it has no assertions to fail.
# It lived in run-tests.sh for a while and cost 16s a run without ever being able
# to catch a regression. What the *real* window looks like is checked by
# tools/check-window-chrome.sh, which asks the running app instead.
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

# A bare executable's UserDefaults land in a plist named after it, and cfprefsd
# rewrites those after the process exits — so ask the daemon to drop the domain.
defaults delete snapshot-window >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/snapshot-window.plist"

echo "wrote build/window-light.png and build/window-dark.png"
