#!/bin/bash
# Every app→page command Swift sends must exist in the page's COMMANDS table,
# and every command in that table must be sent.
#
# The page-side counterpart of check-payload.sh. Before the dispatch channel
# existed, commands were built by string interpolation in four files, and a
# rename on one side silently broke a shortcut — nothing failed, the key just
# did nothing. Now both sides name their commands in one greppable place each:
# `dispatch("<name>"` here, and quoted keys in the COMMANDS table there.
set -euo pipefail
cd "$(dirname "$0")/.."

# Command names sent from Swift. One per dispatch call site; the directed map
# (scrollHalfPage / scrollToEdge / stepHeading) passes its name through a
# variable, so those three are also listed literally below.
sent=$(grep -hoE 'dispatch\("[a-zA-Z]+"' Sources/*.swift | sed 's/dispatch("//;s/"//' | sort -u)
sent=$(printf '%s\nscrollHalfPage\nscrollToEdge\nstepHeading\n' "$sent" | sort -u)

# Command names defined by the page: the COMMANDS table in viewer.js, its
# top-level entries indented exactly four spaces (nested keys inside an
# entry's body sit deeper, and must not count). One per line is what makes
# this grep honest — see the table's comment in web/src/viewer.js.
defined=$(awk '/^  const COMMANDS = \{/,/^  \};/' web/src/viewer.js \
  | grep -oE '^    [a-zA-Z]+:' | tr -d ' :' | sort -u)

fail=0
for cmd in $sent; do
  if ! grep -q "^$cmd$" <<<"$defined"; then
    echo "  FAIL Swift dispatches \"$cmd\", the page has no such command"
    fail=1
  fi
done
for cmd in $defined; do
  if ! grep -q "^$cmd$" <<<"$sent"; then
    echo "  FAIL the page defines \"$cmd\" but Swift never sends it — dead code"
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "  ok   command contract matches ($(echo "$defined" | wc -l | tr -d ' ') commands)"
exit $fail
