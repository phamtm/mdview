#!/bin/bash
# Formats everything, and shellchecks the shell scripts.
#
# Formatters only — no linters. swift-format and prettier remove decisions;
# SwiftLint/ESLint would add rules to maintain for a one-person repo where the
# compiler and the test suite already catch what matters.
#
# Pass --check to verify without writing (used by tools/run-tests.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

check=""
[ "${1:-}" = "--check" ] && check="yes"

# Ships with the Command Line Tools, but not on PATH — reach it through xcrun.
swiftformat() { xcrun swift-format "$@"; }

echo "==> swift (swift-format $(swiftformat --version))"
if [ -n "$check" ]; then
  swiftformat lint --strict --recursive Sources tools
  echo "  ok   swift formatting clean"
else
  swiftformat format --in-place --recursive Sources tools
  echo "  formatted Sources/ tools/"
fi

if [ -x web/node_modules/.bin/prettier ]; then
  echo "==> js / css"
  targets=(web/src web/build.mjs web/.prettierrc Resources/style.css)
  if [ -n "$check" ]; then
    (cd web && ./node_modules/.bin/prettier --check --config .prettierrc \
      src build.mjs ../Resources/style.css) >/dev/null
    echo "  ok   js/css formatting clean"
  else
    (cd web && ./node_modules/.bin/prettier --write --log-level warn --config .prettierrc \
      src build.mjs ../Resources/style.css)
    echo "  formatted ${targets[*]}"
  fi
else
  echo "==> js / css — skipped (run: cd web && npm install)"
fi

# The one tool here that finds bugs rather than style: it catches the unquoted
# expansions and word-splitting mistakes that shell invites.
if command -v shellcheck >/dev/null 2>&1; then
  echo "==> shellcheck"
  shellcheck build.sh tools/*.sh
  echo "  ok   no shell issues"
else
  echo "==> shellcheck — not installed (brew install shellcheck)"
fi
