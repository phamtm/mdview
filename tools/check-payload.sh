#!/bin/bash
# Every payload key the page reads must be declared in RenderPayload.swift.
#
# This exists because the two sides drifted once: the app stopped sending
# `theme`, the document silently ignored the theme setting, and the tests passed
# because the harness built its own complete payload.
set -euo pipefail
cd "$(dirname "$0")/.."

keys=$(grep -oE 'payload\.[a-zA-Z]+' web/src/viewer.js | cut -d. -f2 | sort -u)
fail=0
for key in $keys; do
  if ! grep -q "\"$key\":" Sources/RenderPayload.swift; then
    echo "  FAIL page reads payload.$key, RenderPayload.swift does not send it"
    fail=1
  fi
done

# The other direction: a key the payload sends that the page never reads is dead
# weight, and `name` sat there unused for weeks.
sent=$(grep -oE '"[a-zA-Z]+":' Sources/RenderPayload.swift | tr -d '":')
for key in $sent; do
  if ! grep -q "payload\.$key" web/src/*.js; then
    echo "  FAIL RenderPayload sends $key, no page code reads it"
    fail=1
  fi
done

# And the harness must go through the same type, not hand-roll a dictionary.
if grep -q 'let payload: \[String: Any\]' tools/snapshot.swift; then
  echo "  FAIL tools/snapshot.swift builds its own payload dictionary"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "  ok   payload contract matches ($(echo "$keys" | wc -l | tr -d ' ') keys)"
exit $fail
