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
  out="$(MDVIEW_WINDOW_DUMP=1 MDVIEW_DUMP_DOC="$doc" "$APP" 2>&1 | grep '^PAGE ' || true)"
  case "$out" in
    *"\"theme\":\"$theme\""*) echo "  ok   $theme applied to the document" ;;
    *) echo "  FAIL asked for $theme, page reported: ${out:-no report}"; fail=1 ;;
  esac
done

exit $fail
