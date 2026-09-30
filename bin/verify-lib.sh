# Source from scripts/verify/mN.sh:  . standards/bin/verify-lib.sh
# bash, set -uo pipefail (NOT -e: every check runs). One verify chain per machine (lock).
set -uo pipefail
export NO_COLOR=1 FORCE_COLOR=0 CI=1   # diagnostics must be plain text for regex checks
VERIFY_OK=0; VERIFY_FAIL=0
# Portable lock (flock is missing on macOS): mkdir is atomic everywhere.
VERIFY_LOCK="${TMPDIR:-/tmp}/verify.lock.d"
if ! mkdir "$VERIFY_LOCK" 2>/dev/null; then echo "verify: another verify chain is running on this machine; wait (stale? rmdir $VERIFY_LOCK)"; exit 3; fi
trap 'rmdir "$VERIFY_LOCK" 2>/dev/null' EXIT

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

# section <name>: run only the named section when called with --section <name>
SECTION_FILTER=""; [ "${1:-}" = "--section" ] && SECTION_FILTER=${2:-}
section() { [ -z "$SECTION_FILTER" ] || [ "$SECTION_FILTER" = "$1" ]; }

verify_done() { echo "verify:$1 — $VERIFY_OK ok, $VERIFY_FAIL failed"; [ "$VERIFY_FAIL" -eq 0 ]; exit $?; }
