# Source from scripts/verify/mN.sh:  . standards/bin/verify-lib.sh
# bash, set -uo pipefail (NOT -e: every check runs). One verify chain per machine (lock).
set -uo pipefail
export NO_COLOR=1 FORCE_COLOR=0 CI=1   # diagnostics must be plain text for regex checks
VERIFY_OK=0; VERIFY_FAIL=0
# Portable lock (flock is missing on macOS): mkdir is atomic everywhere. Machine-wide BY DESIGN (docs/07 §4: one full
# verify chain per machine), hence the fixed path. Like bin/build-lock.sh (game BACKLOG 90): the acquirer writes an owner
# file (token=, pid=, who=, since=, cwd=; tmp file + mv) and on exit removes the lock only while that file carries its
# token. A held lock is waited for up to VERIFY_LOCK_WAIT seconds (default 1800; 0 = refuse at once), polled every
# VERIFY_LOCK_POLL seconds (default 10), then refused with exit 3 naming the holder; a missing or unreadable owner file is
# held by `unknown`. A waiter never steals, reuses or deletes the lock; a stale one (holder pid gone) is named once and
# removed by hand only. Refused at once, exit 3: a holder that is this process or an ancestor (a nested run would wait for
# itself), and a held lock while this process already holds the build lock (BUILD_LOCK_TOKEN: the order is verify ->
# build, so waiting would deadlock with a chain waiting for our build lock).
VERIFY_LOCK="${TMPDIR:-/tmp}/verify.lock.d"
_vl_whole() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ ${#1} -le 6 ]; }
_vl_wait=${VERIFY_LOCK_WAIT-1800}; _vl_poll=${VERIFY_LOCK_POLL-10}
_vl_whole "$_vl_wait" || { echo "verify-lib: VERIFY_LOCK_WAIT must be a whole number of seconds" >&2; exit 2; }
if ! _vl_whole "$_vl_poll" || [ $((10#$_vl_poll)) -lt 1 ]; then
  echo "verify-lib: VERIFY_LOCK_POLL must be a whole number of seconds, at least 1" >&2; exit 2
fi
_vl_wait=$((10#$_vl_wait)); _vl_poll=$((10#$_vl_poll))
_vl_field() { local v; v=$(sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1); printf '%s' "${v:-unknown}"; }
_vl_ancestor() { # _vl_ancestor <pid>: 0 when <pid> is this process or one of its ancestors (ps works on Linux and macOS)
  local p=$$ n=0
  while [ "$p" -gt 1 ] && [ "$n" -lt 256 ]; do
    [ "$p" = "$1" ] && return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); n=$((n+1))
    case "$p" in ''|*[!0-9]*) return 1;; esac
  done; return 1; }
_vl_running() { kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1; }
_vl_hex=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || _vl_hex=""; _vl_now=$(date +%s 2>/dev/null) || _vl_now=""
case "$_vl_hex" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) _vl_now="";; esac
case "$_vl_now" in ''|*[!0-9]*) echo "verify-lib: could not make a verify lock token" >&2; exit 1;; esac
VERIFY_LOCK_TOKEN="$$-$_vl_now-$_vl_hex"; VERIFY_LOCK_HELD=0; _vl_written=0
_vl_waited=0; _vl_said=0; _vl_stale=0
while ! mkdir "$VERIFY_LOCK" 2>/dev/null; do
  _vl_hpid=$(_vl_field pid "$VERIFY_LOCK/owner")
  _vl_holder="$(_vl_field who "$VERIFY_LOCK/owner") (pid $_vl_hpid, since $(_vl_field since "$VERIFY_LOCK/owner"), cwd $(_vl_field cwd "$VERIFY_LOCK/owner"))"
  case "$_vl_hpid" in *[!0-9]*|'') _vl_hnum=0;; *) _vl_hnum=1;; esac
  if [ "$_vl_hnum" = 1 ] && _vl_ancestor "$_vl_hpid"; then
    echo "verify: nested verify run inside pid $_vl_hpid; chain instruments before sourcing verify-lib" >&2; exit 3
  fi
  _vl_btok=$(sed -n 's/^token=//p' "${TMPDIR:-/tmp}/build.lock.d/owner" 2>/dev/null | head -n 1)
  if [ "$_vl_waited" -ge "$_vl_wait" ] || { [ -n "${BUILD_LOCK_TOKEN:-}" ] && [ "$_vl_btok" = "$BUILD_LOCK_TOKEN" ]; }; then
    echo "verify: refused — the verify lock is held by $_vl_holder after waiting ${_vl_waited}s; stale? check pid $_vl_hpid, then rm $VERIFY_LOCK/owner && rmdir $VERIFY_LOCK" >&2; exit 3
  fi
  if [ "$_vl_said" = 0 ]; then echo "verify: waiting for the verify lock held by $_vl_holder" >&2; _vl_said=1; fi
  if [ "$_vl_stale" = 0 ] && [ "$_vl_hnum" = 1 ] && ! _vl_running "$_vl_hpid"; then
    echo "verify: pid $_vl_hpid is not running — the lock is possibly stale; it is never removed automatically (by hand: rm $VERIFY_LOCK/owner && rmdir $VERIFY_LOCK)" >&2; _vl_stale=1
  fi
  _vl_step=$_vl_poll; [ $((_vl_wait - _vl_waited)) -ge "$_vl_step" ] || _vl_step=$((_vl_wait - _vl_waited))
  sleep "$_vl_step"; _vl_waited=$((_vl_waited + _vl_step))
done
# Ours from here. Until the owner file is in place (_vl_written=0) nobody else can hold the directory, so release removes it
# with the tmp file (rmdir fails if the mv already happened) and falls through; otherwise only while the owner file still
# carries our token (also the case of a signal between the mv and _vl_written=1).
verify_lock_release() {
  [ "${VERIFY_LOCK_HELD:-0}" = 1 ] || return 0
  VERIFY_LOCK_HELD=0
  if [ "$_vl_written" = 0 ]; then rm -f "$VERIFY_LOCK/owner.$$"; rmdir "$VERIFY_LOCK" 2>/dev/null; fi
  if [ "$(sed -n 's/^token=//p' "$VERIFY_LOCK/owner" 2>/dev/null | head -n 1)" = "$VERIFY_LOCK_TOKEN" ]; then
    rm -f "$VERIFY_LOCK/owner"; rmdir "$VERIFY_LOCK" 2>/dev/null
  fi
  return 0
}
VERIFY_LOCK_HELD=1
trap 'verify_lock_release' EXIT
trap 'verify_lock_release; exit 129' HUP
trap 'verify_lock_release; exit 130' INT
trap 'verify_lock_release; exit 143' TERM
if ! { printf 'token=%s\npid=%s\nwho=%s\nsince=%s\ncwd=%s\n' "$VERIFY_LOCK_TOKEN" "$$" "${0##*/}" \
         "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(pwd -P)" > "$VERIFY_LOCK/owner.$$" && mv "$VERIFY_LOCK/owner.$$" "$VERIFY_LOCK/owner"; }; then
  echo "verify-lib: could not write $VERIFY_LOCK/owner" >&2; exit 1
fi
_vl_written=1
# Then the machine build lock (C5, bin/build-lock.sh): one Rust build at a time across sessions, the repo's shared
# CARGO_TARGET_DIR. Re-entrant for a check run inside the chain (BUILD_LOCK_TOKEN); a foreign lock is waited for up to
# BUILD_LOCK_WAIT seconds, then refused with exit 3. Both locks are released on exit.
BUILD_LOCK_WHO=verify; . "$(dirname "${BASH_SOURCE[0]}")/build-lock.sh"
build_lock_acquire; _vl_rc=$?
if [ "$_vl_rc" -eq 3 ]; then build_lock_refusal; exit 3; fi
[ "$_vl_rc" -eq 0 ] || exit "$_vl_rc"
trap 'build_lock_release; verify_lock_release' EXIT
build_lock_env || exit 1

# VERIFY_FAIL_TAIL: how many lines of a failing command's output the helpers print (default 8; the exchange nightlies of
# 10-10 and 10-11 lost their cause and replay seed to 8). Read per call and checked before the command runs, so a bad
# value stops the instrument (exit 2) instead of silently printing another length; tail itself must accept the value.
_vl_fail_tail_valid() {
  case "${VERIFY_FAIL_TAIL:-8}" in ''|0*|*[!0-9]*) ;; *) tail -n "${VERIFY_FAIL_TAIL:-8}" </dev/null >/dev/null 2>&1 && return 0;; esac
  echo "verify-lib: VERIFY_FAIL_TAIL must be a positive integer, got '${VERIFY_FAIL_TAIL-}'" >&2; exit 2
}

# expect_out "<label>" <wanted_rc> '<regex>' -- cmd args...
# Passes only if the real exit code == wanted AND combined output matches regex (the check's OWN diagnostic).
expect_out() {
  _vl_fail_tail_valid
  local label=$1 want=$2 re=$3; shift 3; [ "$1" = "--" ] && shift
  local out rc; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then
    echo "[ok]   $label"; VERIFY_OK=$((VERIFY_OK+1))
  else
    echo "[FAIL] $label (rc=$rc, wanted $want, /$re/)"; printf '%s\n' "$out" | tail -n "${VERIFY_FAIL_TAIL:-8}" | sed 's/^/       /'
    VERIFY_FAIL=$((VERIFY_FAIL+1))
  fi
}

# expect_nextest "<label>" <passed> -- cargo nextest run …   (NOTES-19 defect 3)
# <passed> is an exact count >= 1, or + (any positive; unfiltered runs only). Passes only if the exit code is 0, the
# summary `N test(s) run: P passed` has N = P (nothing failed or timed out), P equals <passed> (or >= 1 for +), and —
# when the command carries no -E/--filterset/--filter-expr — `0 skipped`. A filtered run reports every other test as
# skipped, so it needs an exact passed count instead.
expect_nextest() {
  _vl_fail_tail_valid
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
    echo "[FAIL] $label ($why; summary: ${sum:-none})"; printf '%s\n' "$out" | tail -n "${VERIFY_FAIL_TAIL:-8}" | sed 's/^/       /'
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
