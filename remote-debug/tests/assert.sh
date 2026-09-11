#!/usr/bin/env bash
# Minimal assert helpers — no external test framework needed.
ASSERT_FAILS=0
assert_eq() { # $1 expected, $2 actual, $3 msg
  if [ "$1" != "$2" ]; then
    printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$3" "$1" "$2" >&2
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  else printf 'ok: %s\n' "$3"; fi
}
assert_contains() { # $1 haystack, $2 needle, $3 msg
  if printf '%s' "$1" | grep -qF -- "$2"; then printf 'ok: %s\n' "$3"
  else printf 'FAIL: %s\n  %q not in output\n' "$3" "$2" >&2; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
finish() { [ "$ASSERT_FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$ASSERT_FAILS FAILED"; exit 1; }; }
