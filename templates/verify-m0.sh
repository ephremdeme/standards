#!/usr/bin/env bash
# scripts/verify/m0.sh — milestone instrument. Commit it PROVEN RED per section before dispatch.
cd "$(git rev-parse --show-toplevel)" && . standards/bin/verify-lib.sh "$@"
# Chain the previous milestone (none for m0):  bash scripts/verify/m(N-1).sh || VERIFY_FAIL=$((VERIFY_FAIL+1))

if section check; then
  expect_out "definition of done: standards/bin/check" 0 'check: OK' -- standards/bin/check
fi

if section lock; then
  # Rust: explicit test target + positive count (a name that matches nothing exits 0 with "0 passed").
  expect_out "pick after lock_at is rejected" 0 'test result: ok\. [1-9][0-9]* passed' -- cargo test --test lock_timing
  # Negative control: executed red, for its own reason.
  expect_out "control: trigger removed -> late pick accepted (must be red)" 101 'late_pick_rejected.*FAILED' -- cargo test --test lock_timing_negative_control
fi

verify_done m0
