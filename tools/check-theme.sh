#!/bin/bash
# Does the real app apply the theme setting to the document?
#
# The harness cannot answer this: it builds its own payload, so it kept passing
# while the app silently stopped sending `theme` and every document rendered in
# the system appearance instead. This launches the built app, points it at a
# document, and asks the page what it actually rendered.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/MDView.app/Contents/MacOS/MDView"
DOMAIN="com.minh.mdview"
[ -x "$APP" ] || { echo "  FAIL $APP not built"; exit 1; }

doc="$(mktemp -d)/probe.md"
printf '# Heading\n\nBody text.\n' > "$doc"

# Restore whatever the user had when we are done.
previous="$(defaults read "$DOMAIN" theme 2>/dev/null || echo "__unset__")"
restore() {
  if [ "$previous" = "__unset__" ]; then
    defaults delete "$DOMAIN" theme 2>/dev/null || true
  else
    defaults write "$DOMAIN" theme "$previous"
  fi
  rm -rf "$(dirname "$doc")"
}
trap restore EXIT

fail=0
for theme in paper vellum night; do
  defaults write "$DOMAIN" theme "$theme"
  dump="$(MDVIEW_WINDOW_DUMP=1 MDVIEW_DUMP_DOC="$doc" "$APP" 2>&1)"
  out="$(echo "$dump" | grep '^PAGE ' || true)"
  case "$out" in
    *"\"theme\":\"$theme\""*) echo "  ok   $theme applied to the document" ;;
    *) echo "  FAIL asked for $theme, page reported: ${out:-no report}"; fail=1 ;;
  esac

  # Native scrollers follow the window's appearance, so it has to match the chosen
  # theme rather than the OS: a light theme under a dark macOS drew a white knob.
  case "$theme" in
    night) want="NSAppearanceNameDarkAqua" ;;
    *)     want="NSAppearanceNameAqua" ;;
  esac
  appearance="$(echo "$dump" | sed -n 's/.*appearance=\([^ ]*\).*/\1/p')"
  if [ "$appearance" = "$want" ]; then
    echo "  ok   $theme window appearance $appearance"
  else
    echo "  FAIL $theme wants window appearance $want, got ${appearance:-none}"
    fail=1
  fi

  # The window frame and the overscroll area are painted by AppKit and WebKit, not
  # by the stylesheet. A system colour there shows as a black edge and a black
  # rubber-band in the dark theme.
  page="$(echo "$dump" | awk '/^PAGEBG/ {print $2}')"
  frame="$(echo "$dump" | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^windowBg=/) { sub(/windowBg=/, "", $i); print $i }}')"
  if [ -z "$page" ] || [ -z "$frame" ]; then
    echo "  FAIL $theme: no background reported (page='$page' frame='$frame')"
    fail=1
  elif ! python3 - "$page" "$frame" "$theme" <<'CHECK'
import sys
page, frame, theme = sys.argv[1], sys.argv[2], sys.argv[3]
def rgb(value):
    return [int(value[i:i + 2], 16) for i in (1, 3, 5)]
p, f = rgb(page), rgb(frame)
# Two conversions round independently, so allow a unit per channel.
if any(abs(a - b) > 2 for a, b in zip(p, f)):
    print(f"    page {page} and frame {frame} disagree")
    raise SystemExit(1)
luma = sum(p) / 3
if theme == "night" and luma > 90:
    print(f"    {theme} background {page} is too light to be the dark theme")
    raise SystemExit(1)
if theme == "paper" and luma < 200:
    print(f"    {theme} background {page} is too dark to be the light theme")
    raise SystemExit(1)
CHECK
  then
    echo "  FAIL $theme: window/overscroll background is not the theme's"
    fail=1
  else
    echo "  ok   $theme paints frame and overscroll $page"
  fi
done

exit $fail
