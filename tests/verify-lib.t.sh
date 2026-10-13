#!/usr/bin/env bash
# Cases for bin/verify-lib.sh: sourcing takes the verify lock and then the machine build lock (C5), releasing both on
# exit; expect_nextest (NOTES-19 defect 3) asserts an exact passed count for filtered runs and `0 skipped` only for
# unfiltered ones. A stub cargo prints a nextest summary. VERIFY_FAIL_TAIL sets how many lines of a failing command's
# output both helpers print (default 8); any other value than a positive integer stops the instrument with exit 2.
# Run: bash standards/tests/verify-lib.t.sh -> exit 0 when all behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
unset BUILD_LOCK_TOKEN BUILD_LOCK_WAIT CARGO_TARGET_DIR RUSTC_WRAPPER VERIFY_FAIL_TAIL
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "cargo $*" >> "$TMPDIR/cargo.log"\ncat "$TMPDIR/stub.out"\nexit "$(cat "$TMPDIR/stub.rc")"\n' > "$T/bin/cargo"; chmod +x "$T/bin/cargo"
export PATH="$T/bin:$PATH"
P="$T/p"; git init -q -b main "$P"; mkdir -p "$P/scripts/verify" "$P/standards"; cp -r "$S/bin" "$P/standards/bin"
cat > "$P/scripts/verify/m0.sh" << 'V'
#!/usr/bin/env bash
cd "$(git rev-parse --show-toplevel)" && . standards/bin/verify-lib.sh "$@"
stub(){ printf '%s\n' "$1" > "$TMPDIR/stub.out"; echo "${2:-0}" > "$TMPDIR/stub.rc"; }
if section locks; then
  [ -d "$TMPDIR/verify.lock.d" ] && echo "verify lock held"
  [ -d "$TMPDIR/build.lock.d" ] && echo "build lock held"
  expect_out "trivial" 0 . -- echo x
fi
if section filtered_ok; then stub '     Summary [   0.010s] 1 test run: 1 passed, 41 skipped'
  expect_nextest "filtered one" 1 -- cargo nextest run -p api -E 'test(=lock_at_is_enforced)'; fi
if section unfiltered_skipped; then stub '     Summary [   0.010s] 1 test run: 1 passed, 41 skipped'
  expect_nextest "unfiltered with skips" 1 -- cargo nextest run -p api; fi
if section filtered_plus; then stub '     Summary [   0.010s] 1 test run: 1 passed, 41 skipped'
  expect_nextest "filtered any" + -- cargo nextest run -p api --filterset 'test(x)'; fi
if section zero; then stub '     Summary [   0.010s] 0 tests run: 0 passed, 0 skipped' 0
  expect_nextest "nothing ran" + -- cargo nextest run -p api; fi
if section failed; then stub '     Summary [   0.010s] 2 tests run: 1 passed, 1 failed, 0 skipped' 100
  expect_nextest "one failed" 2 -- cargo nextest run -p api; fi
if section mismatch; then stub '     Summary [   0.010s] 3 tests run: 3 passed, 0 skipped'
  expect_nextest "count mismatch" 2 -- cargo nextest run -p api; fi
if section plus_ok; then stub '     Summary [   0.010s] 3 tests run: 3 passed, 0 skipped'
  expect_nextest "unfiltered any" + -- cargo nextest run -p api; fi
if section mixed; then stub '     Summary [   0.010s] 1 test run: 1 passed, 41 skipped'
  expect_nextest "mixed ok" 1 -- cargo nextest run -E 'test(=a)'
  expect_nextest "mixed fail" 1 -- cargo nextest run; fi
twenty(){ for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do echo "$1-$i"; done; return 1; }
if section tail; then expect_out "twenty lines" 0 . -- twenty o; fi
if section tail || section tail_nextest; then stub "$(twenty n)" 1
  expect_nextest "nextest twenty lines" 1 -- cargo nextest run -p api; fi
verify_done m0
V
git -C "$P" add -A; git -C "$P" commit -qm base
I="$P/scripts/verify/m0.sh"; cd "$P" || exit 1   # the instrument cds to the top of the repo it runs in
want "sourcing takes the verify lock and the build lock" 0 'build lock held' bash "$I" --section locks
want "... (the verify lock too)" 0 'verify lock held' bash "$I" --section locks
[ ! -e "$T/verify.lock.d" ] && [ ! -e "$T/build.lock.d" ] && ok "both locks are released on exit" || bad "a lock was left behind"
mkdir "$T/build.lock.d"; printf 'token=x\npid=999999999\nwho=other-session\nsince=2026-10-03T10:00:00Z\ncwd=/x\n' > "$T/build.lock.d/owner"
want "control: a foreign build lock with BUILD_LOCK_WAIT=0 -> exit 3" 3 '^verify: refused — the machine build lock is held by other-session' env BUILD_LOCK_WAIT=0 bash "$I" --section locks
[ ! -e "$T/verify.lock.d" ] && [ -f "$T/build.lock.d/owner" ] && ok "control: ... the verify lock is released, the foreign build lock untouched" || bad "lock state after a build-lock refusal"
rm -f "$T/build.lock.d/owner"; rmdir "$T/build.lock.d"
want "defect 3: a filtered -E run with '1 passed, 41 skipped' and count 1 -> [ok]" 0 '^\[ok\]   filtered one$' bash "$I" --section filtered_ok
want "control: an unfiltered run with 41 skipped -> [FAIL]" 1 '^\[FAIL\] unfiltered with skips' bash "$I" --section unfiltered_skipped
want "control: a filtered run with + -> [FAIL] (needs an exact count)" 1 '^\[FAIL\] filtered any \(a filtered run needs an exact passed count\)$' bash "$I" --section filtered_plus
want "control: 0 tests run -> [FAIL]" 1 '^\[FAIL\] nothing ran' bash "$I" --section zero
want "control: rc 100 with 1 failed -> [FAIL]" 1 '^\[FAIL\] one failed' bash "$I" --section failed
want "control: passed count differs from the wanted one -> [FAIL]" 1 '^\[FAIL\] count mismatch' bash "$I" --section mismatch
want "an unfiltered run with 0 skipped and + -> [ok]" 0 '^\[ok\]   unfiltered any$' bash "$I" --section plus_ok
want "verify_done counts expect_nextest results" 1 '^verify:m0 — 1 ok, 1 failed$' bash "$I" --section mixed
# VERIFY_FAIL_TAIL (exchange nightlies 10-10 and 10-11 lost their cause and replay seed to the 8-line tail): section tail
# fails expect_out (o-01..o-20) and expect_nextest (n-01..n-20); each prints the LAST N lines of its own output.
tails(){ # tails <label> <lines per helper> [VAR=value]
  label=$1; n=$2; shift 2; out=$(env "$@" bash "$I" --section tail 2>&1); rc=$?
  o=$(printf '%s\n' "$out" | grep -c '^       o-'); x=$(printf '%s\n' "$out" | grep -c '^       n-')
  if [ "$rc" -eq 1 ] && [ "$o" -eq "$n" ] && [ "$x" -eq "$n" ] && printf '%s\n' "$out" | grep -q '^       o-20$' && printf '%s\n' "$out" | grep -q '^       n-20$'
  then ok "$label"; else bad "$label (rc=$rc, $o expect_out and $x expect_nextest tail lines, wanted $n each ending at 20)"; fi; }
tails "VERIFY_FAIL_TAIL unset: the last 8 lines of a 20-line failing output (expect_out and expect_nextest)" 8
tails "VERIFY_FAIL_TAIL=20: all 20 lines (expect_out and expect_nextest)" 20 VERIFY_FAIL_TAIL=20
# A bad value is refused on stderr with exit 2 by whichever helper runs first (stdout discarded: the message must be on stderr).
want "control: VERIFY_FAIL_TAIL=abc refused by expect_out (exit 2, on stderr)" 2 "^verify-lib: VERIFY_FAIL_TAIL must be a positive integer, got 'abc'$" env VERIFY_FAIL_TAIL=abc sh -c 'bash "$1" --section tail 2>&1 >/dev/null' _ "$I"
want "control: VERIFY_FAIL_TAIL=abc refused by expect_nextest (exit 2, on stderr)" 2 "^verify-lib: VERIFY_FAIL_TAIL must be a positive integer, got 'abc'$" env VERIFY_FAIL_TAIL=abc sh -c 'bash "$1" --section tail_nextest 2>&1 >/dev/null' _ "$I"
want "control: VERIFY_FAIL_TAIL=0 refused (not positive; tail -n 0 would print nothing)" 2 "^verify-lib: VERIFY_FAIL_TAIL must be a positive integer, got '0'$" env VERIFY_FAIL_TAIL=0 sh -c 'bash "$1" --section tail 2>&1 >/dev/null' _ "$I"
rm -rf "$T"; [ $R -eq 0 ] && echo "verify-lib.t: all cases behave" || echo "verify-lib.t: FAILURES"; exit $R
