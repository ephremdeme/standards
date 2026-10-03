# Source from scripts/verify/mN.sh:  . standards/bin/verify-lib.sh
# bash, set -uo pipefail (NOT -e: every check runs). One verify chain per machine (lock).
set -uo pipefail
export NO_COLOR=1 FORCE_COLOR=0 CI=1   # diagnostics must be plain text for regex checks
VERIFY_OK=0; VERIFY_FAIL=0
# Portable lock (flock is missing on macOS): mkdir is atomic everywhere. Machine-wide BY DESIGN (docs/07 §4: one full
# verify chain per machine), hence the fixed path: mkdir refuses an existing one, so it is never reused or deleted.
VERIFY_LOCK="${TMPDIR:-/tmp}/verify.lock.d"
if ! mkdir "$VERIFY_LOCK" 2>/dev/null; then echo "verify: another verify chain is running on this machine; wait (stale? rmdir $VERIFY_LOCK)"; exit 3; fi
trap 'rmdir "$VERIFY_LOCK" 2>/dev/null' EXIT
# Then the machine build lock (C5, bin/build-lock.sh): one Rust build at a time across sessions, the repo's shared
# CARGO_TARGET_DIR. Re-entrant for a check run inside the chain (BUILD_LOCK_TOKEN); a foreign lock is waited for up to
# BUILD_LOCK_WAIT seconds, then refused with exit 3. Both locks are released on exit.
BUILD_LOCK_WHO=verify; . "$(dirname "${BASH_SOURCE[0]}")/build-lock.sh"
build_lock_acquire; _vl_rc=$?
if [ "$_vl_rc" -eq 3 ]; then build_lock_refusal; exit 3; fi
[ "$_vl_rc" -eq 0 ] || exit "$_vl_rc"
trap 'build_lock_release; rmdir "$VERIFY_LOCK" 2>/dev/null' EXIT
build_lock_env || exit 1

# expect_out "<label>" <wanted_rc> '<regex>' -- cmd args...
# Passes only if the real exit code == wanted AND combined output matches regex (the check's OWN diagnostic).
expect_out() {
  local label=$1 want=$2 re=$3; shift 3; [ "$1" = "--" ] && shift
  local out rc; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then
    echo "[ok]   $label"; VERIFY_OK=$((VERIFY_OK+1))
  else
    echo "[FAIL] $label (rc=$rc, wanted $want, /$re/)"; printf '%s\n' "$out" | tail -n 8 | sed 's/^/       /'
    VERIFY_FAIL=$((VERIFY_FAIL+1))
  fi
}

# expect_nextest "<label>" <passed> -- cargo nextest run …   (NOTES-19 defect 3)
# <passed> is an exact count >= 1, or + (any positive; unfiltered runs only). Passes only if the exit code is 0, the
# summary `N test(s) run: P passed` has N = P (nothing failed or timed out), P equals <passed> (or >= 1 for +), and —
# when the command carries no -E/--filterset/--filter-expr — `0 skipped`. A filtered run reports every other test as
# skipped, so it needs an exact passed count instead.
expect_nextest() {
  local label=$1 want=$2; shift 2; [ "${1:-}" = "--" ] && shift
  local filtered=0 a out rc sum run passed why=""
  for a in "$@"; do case "$a" in -E|-E?*|--filterset|--filterset=*|--filter-expr|--filter-expr=*) filtered=1;; esac; done
  case "$want" in +) ;; ''|*[!0-9]*|0) why="bad passed count '$want' (an exact count >= 1 or +)";; esac
  if [ -z "$why" ] && [ "$filtered" -eq 1 ] && [ "$want" = + ]; then why="a filtered run needs an exact passed count"; fi
  if [ -n "$why" ]; then echo "[FAIL] $label ($why)"; VERIFY_FAIL=$((VERIFY_FAIL+1)); return; fi
  out=$("$@" 2>&1); rc=$?
  sum=$(printf '%s\n' "$out" | grep -Eo '[0-9]+ tests? run: [0-9]+ passed.*' | tail -n 1)
  run=$(printf '%s' "$sum" | sed -En 's/^([0-9]+) tests? run: .*/\1/p')
  passed=$(printf '%s' "$sum" | sed -En 's/^[0-9]+ tests? run: ([0-9]+) passed.*/\1/p')
  if [ "$rc" -ne 0 ]; then why="rc=$rc"
  elif [ -z "$run" ] || [ -z "$passed" ]; then why="no nextest summary"
  elif [ "$run" -ne "$passed" ]; then why="$run run, $passed passed"
  elif [ "$passed" -lt 1 ]; then why="no test passed"
  elif [ "$want" != + ] && [ "$passed" -ne "$want" ]; then why="$passed passed, wanted $want"
  elif [ "$filtered" -eq 0 ] && ! printf '%s' "$sum" | grep -Eq '(^|[^0-9])0 skipped'; then why="an unfiltered run skipped tests"
  fi
  if [ -z "$why" ]; then echo "[ok]   $label"; VERIFY_OK=$((VERIFY_OK+1))
  else
    echo "[FAIL] $label ($why; summary: ${sum:-none})"; printf '%s\n' "$out" | tail -n 8 | sed 's/^/       /'
    VERIFY_FAIL=$((VERIFY_FAIL+1))
  fi
}

# section <name>: run only the named section when called with --section <name>
SECTION_FILTER=""; [ "${1:-}" = "--section" ] && SECTION_FILTER=${2:-}
section() { [ -z "$SECTION_FILTER" ] || [ "$SECTION_FILTER" = "$1" ]; }

# A run in which no check ran (an unknown --section, a section that forgot its checks) is a failure, never green
# (retro review 18).
verify_done() { echo "verify:$1 — $VERIFY_OK ok, $VERIFY_FAIL failed"
  if [ $((VERIFY_OK + VERIFY_FAIL)) -eq 0 ]; then echo "verify: no checks ran (unknown section?)"; exit 1; fi
  [ "$VERIFY_FAIL" -eq 0 ]; exit $?; }
