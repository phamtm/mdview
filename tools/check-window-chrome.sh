#!/bin/bash
# Launches the built app and asks it what its window actually looks like.
#
# Worth its own check: the titlebar treatment is applied by SwiftUI, and an
# offscreen harness builds its own window, so a harness render can look right
# while the real app still shows a titlebar and a duplicate filename.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/MDView.app/Contents/MacOS/MDView"
[ -x "$APP" ] || { echo "  FAIL $APP not built"; exit 1; }

out="$(MDVIEW_WINDOW_DUMP=1 "$APP" 2>&1 | grep '^WINDOW ' || true)"
[ -n "$out" ] || { echo "  FAIL app did not report its window state"; exit 1; }
echo "  $out"

fail=0
# Focus starts in the document. Otherwise SwiftUI focuses the header button at
# launch and draws a focus ring around it.
# buttonCentre must be half the titlebar band's height, or the traffic lights sit
# off-centre in it. macOS decides where they go from the titlebar setup: 16pt with
# a plain hidden titlebar, 26pt once an empty unified toolbar is attached. The band
# is 52pt to match the latter.
for expected in "titleVisibility=hidden" "fullSizeContentView=true" "titlebarTransparent=true" \
                "firstResponder=DroppableWebView" "buttonCentre=26"; do
  case "$out" in
    *"$expected"*) ;;
    *) echo "  FAIL expected $expected"; fail=1 ;;
  esac
done

# The window's appearance is checked in check-theme.sh, which sets each theme
# in turn. Reading whatever theme the developer happens to have set would pass
# without exercising anything.

# Content filling the whole window frame is what removes the empty titlebar band.
content="$(echo "$out" | sed -n 's/.*contentHeight=\([0-9]*\).*/\1/p')"
window="$(echo "$out" | sed -n 's/.*windowHeight=\([0-9]*\).*/\1/p')"
if [ "$content" != "$window" ]; then
  echo "  FAIL content ($content) does not fill the window ($window) — titlebar band remains"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "  ok   titlebar hidden, buttons centred in the band, content full height, focus in document"
exit $fail
