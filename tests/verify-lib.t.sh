#!/usr/bin/env bash
# Cases for bin/verify-lib.sh: sourcing takes the verify lock and then the machine build lock (C5), releasing both on
# exit; expect_nextest (NOTES-19 defect 3) asserts an exact passed count for filtered runs and `0 skipped` only for
# unfiltered ones. A stub cargo prints a nextest summary. VERIFY_FAIL_TAIL sets how many lines of a failing command's
# output both helpers print (default 8); any other value than a positive integer stops the instrument with exit 2.
# Run: bash standards/tests/verify-lib.t.sh -> exit 0 when all behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
unset BUILD_LOCK_TOKEN BUILD_LOCK_WAIT CARGO_TARGET_DIR RUSTC_WRAPPER VERIFY_FAIL_TAIL VERIFY_LOCK_WAIT VERIFY_LOCK_POLL HOLD_S
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
if section hold; then sleep "${HOLD_S:-2}"; expect_out "held" 0 . -- echo x; fi
if section owner; then cat "$TMPDIR/verify.lock.d/owner"; echo "files: $(ls "$TMPDIR/verify.lock.d" | tr '\n' ' ')"
  expect_out "owner" 0 . -- echo x; fi
if section swap; then printf 'token=999-1-deadbeef\npid=1\nwho=swapped\nsince=x\ncwd=/x\n' > "$TMPDIR/verify.lock.d/owner"
  expect_out "swap" 0 . -- echo x; fi
if section nested; then
  expect_out "inner refused" 3 '^verify: nested verify run inside pid [0-9]+; chain instruments before sourcing verify-lib$' -- bash "$0" --section locks; fi
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
mkdir "$T/build.lock.d"; printf 'token=x\npid=999999999\nwho=other-session\nsince=%s\ncwd=/x\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$T/build.lock.d/owner"
want "control: a foreign build lock with BUILD_LOCK_WAIT=0 -> exit 3" 3 '^verify: refused — the machine build lock is held by other-session' env BUILD_LOCK_WAIT=0 bash "$I" --section locks
[ ! -e "$T/verify.lock.d" ] && [ -f "$T/build.lock.d/owner" ] && ok "control: ... the verify lock is released, the foreign build lock untouched" || bad "lock state after a build-lock refusal"
rm -f "$T/build.lock.d/owner"; rmdir "$T/build.lock.d"
# The verify lock waits like the build lock (game BACKLOG 90): owner file, VERIFY_LOCK_WAIT/VERIFY_LOCK_POLL, stale naming,
# nested refusal. run() captures one command; has() checks its exit code and every regex given (one per line of output).
run(){ out=$("$@" 2>&1); rc=$?; }
has(){ # has <label> <rc> <regex>...
  label=$1; rc_want=$2; shift 2; why=""
  [ "$rc" -eq "$rc_want" ] || why="rc=$rc want $rc_want"
  for re in "$@"; do printf '%s\n' "$out" | grep -Eq -- "$re" || why="${why:+$why; }no /$re/"; done
  if [ -z "$why" ]; then ok "$label"; else bad "$label ($why)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
lacks(){ # lacks <label> <regex> — the last run() printed no such line
  if printf '%s\n' "$out" | grep -Eq -- "$2"; then bad "$1"; else ok "$1"; fi; }
VL="$T/verify.lock.d"
untilheld(){ i=0; while [ ! -f "$VL/owner" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done; }
fake(){ mkdir "$VL"; printf 'token=999-1-deadbeef\npid=%s\nwho=other-chain\nsince=2026-10-16T10:00:00Z\ncwd=/elsewhere\n' "$1" > "$VL/owner"; cp "$VL/owner" "$T/owner.orig"; }
unfake(){ chmod 600 "$VL/owner" 2>/dev/null; rm -f "$VL/owner"; rmdir "$VL"; }
untouched(){ [ -d "$VL" ] && cmp -s "$VL/owner" "$T/owner.orig" && ok "$1" || bad "$1"; }
HOLD_S=3 bash "$I" --section hold >/dev/null 2>&1 & HP=$!; untilheld
run env VERIFY_LOCK_WAIT=10 VERIFY_LOCK_POLL=1 bash "$I" --section locks; wait $HP
has "lock: a second run waits and proceeds when the holder exits" 0 \
  '^verify: waiting for the verify lock held by m0\.sh \(pid [0-9]+, since [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z, cwd /.*/p\)$' '^verify lock held$'
HOLD_S=2 bash "$I" --section hold >/dev/null 2>&1 & HP=$!; untilheld
env VERIFY_LOCK_WAIT=15 VERIFY_LOCK_POLL=1 HOLD_S=1 bash "$I" --section hold > "$T/w1" 2>&1 & W1=$!
env VERIFY_LOCK_WAIT=15 VERIFY_LOCK_POLL=1 HOLD_S=1 bash "$I" --section hold > "$T/w2" 2>&1 & W2=$!
wait $W1; r1=$?; wait $W2; r2=$?; wait $HP
[ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && grep -q '^verify: waiting for the verify lock held by m0\.sh' "$T/w1" && grep -q '^verify: waiting for the verify lock held by m0\.sh' "$T/w2" && [ ! -e "$VL" ] \
  && ok "lock: two waiters both wait and both run, one after the other" || { bad "lock: two waiters both wait and both run (rc $r1, $r2)"; tail -n 3 "$T/w1" "$T/w2"; }
sleep 30 & SP=$!; fake "$SP"   # a running holder that is not an ancestor of the instrument
run env VERIFY_LOCK_WAIT=2 VERIFY_LOCK_POLL=1 bash "$I" --section locks
has "lock: VERIFY_LOCK_WAIT=2 refuses after the wait naming the holder" 3 \
  "^verify: waiting for the verify lock held by other-chain \(pid $SP, since 2026-10-16T10:00:00Z, cwd /elsewhere\)$" \
  "^verify: refused — the verify lock is held by other-chain \(pid $SP, since 2026-10-16T10:00:00Z, cwd /elsewhere\) after waiting 2s; stale\? check pid $SP, then rm $VL/owner && rmdir $VL$"
lacks "... a running holder is not named stale" 'is not running'
untouched "... the foreign lock and its owner file are untouched"
run env VERIFY_LOCK_WAIT=0 bash "$I" --section locks
has "lock: VERIFY_LOCK_WAIT=0 refuses at once" 3 \
  "^verify: refused — the verify lock is held by other-chain \(pid $SP, since 2026-10-16T10:00:00Z, cwd /elsewhere\) after waiting 0s; stale\? check pid $SP, then rm $VL/owner && rmdir $VL$"
lacks "... without a waiting line" 'waiting for the verify lock'
untouched "... the foreign lock is untouched"
mkdir "$T/build.lock.d"; printf 'token=777-1-cafecafe\npid=%s\nwho=dispatch\nsince=x\ncwd=/x\n' "$SP" > "$T/build.lock.d/owner"
run env BUILD_LOCK_TOKEN=777-1-cafecafe VERIFY_LOCK_WAIT=30 VERIFY_LOCK_POLL=1 bash "$I" --section locks
has "lock: a run that already holds the build lock refuses a held verify lock at once (lock order verify -> build)" 3 \
  '^verify: refused — the verify lock is held by other-chain .* after waiting 0s; '
run env BUILD_LOCK_TOKEN=888-1-feedfeed VERIFY_LOCK_WAIT=2 VERIFY_LOCK_POLL=1 bash "$I" --section locks
has "lock: a run with a foreign BUILD_LOCK_TOKEN still waits" 3 \
  "^verify: waiting for the verify lock held by other-chain \(pid $SP, " '^verify: refused — the verify lock is held by other-chain .* after waiting 2s; '
rm -f "$T/build.lock.d/owner"; rmdir "$T/build.lock.d"; unfake
if [ "$(id -u)" -ne 0 ]; then
  run sh -c 'umask 0277; exec bash "$1" --section locks' _ "$I"
  has "lock: a failed owner write removes its own lock dir" 1 '^verify-lib: could not write .*/owner$'
  [ ! -e "$VL" ] && ok "... no lock dir left" || { bad "... the lock dir was left behind"; rmdir "$VL"; }
fi
for v in abc 1234567 -1 ''; do
  run env VERIFY_LOCK_WAIT="$v" bash "$I" --section locks
  has "lock: a bad VERIFY_LOCK_WAIT exits 2 ('$v')" 2 '^verify-lib: VERIFY_LOCK_WAIT must be a whole number of seconds$'
done
for v in 0 abc ''; do
  run env VERIFY_LOCK_POLL="$v" bash "$I" --section locks
  has "... and a bad VERIFY_LOCK_POLL ('$v') exits 2" 2 '^verify-lib: VERIFY_LOCK_POLL must be a whole number of seconds, at least 1$'
done
fake 999999999
run env VERIFY_LOCK_WAIT=2 VERIFY_LOCK_POLL=1 bash "$I" --section locks
has "lock: a stale holder is named and never removed" 3 \
  "^verify: pid 999999999 is not running — the lock is possibly stale; it is never removed automatically \(by hand: rm $VL/owner && rmdir $VL\)$" \
  '^verify: refused — the verify lock is held by other-chain \(pid 999999999, '
[ "$(printf '%s\n' "$out" | grep -c 'is not running')" -eq 1 ] && ok "... named once" || bad "... the stale line is not printed exactly once"
untouched "... the stale lock and its owner file are untouched"; unfake
run bash "$I" --section owner
has "lock: owner file written on acquire and removed on exit" 0 '^token=[0-9]+-[0-9]+-[0-9a-f]{8}$' '^pid=[0-9]+$' '^who=m0\.sh$' \
  '^since=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' '^cwd=/.*/p$' '^files: owner $'
[ ! -e "$VL" ] && ok "... removed on exit" || bad "... the verify lock was left behind"
run bash "$I" --section swap
[ "$rc" -eq 0 ] && [ -f "$VL/owner" ] && grep -q '^who=swapped$' "$VL/owner" && ok "... a lock whose owner file no longer carries our token is left alone" || bad "... a swapped lock was removed (rc=$rc)"
rm -f "$VL/owner"; rmdir "$VL"
mkdir "$VL"
run env VERIFY_LOCK_WAIT=1 VERIFY_LOCK_POLL=1 bash "$I" --section locks
has "lock: an ownerless lock dir counts as held by unknown" 3 \
  "^verify: refused — the verify lock is held by unknown \(pid unknown, since unknown, cwd unknown\) after waiting 1s; stale\? check pid unknown, then rm $VL/owner && rmdir $VL$"
[ -d "$VL" ] && ok "... the ownerless lock dir is untouched" || bad "... the ownerless lock dir was removed"
rmdir "$VL"; fake "$SP"; chmod 000 "$VL/owner"
if [ ! -r "$VL/owner" ]; then
  run env VERIFY_LOCK_WAIT=0 bash "$I" --section locks
  has "... an unreadable owner file counts as unknown too" 3 '^verify: refused — the verify lock is held by unknown \(pid unknown, since unknown, cwd unknown\) after waiting 0s'
fi
unfake; kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
run env VERIFY_LOCK_WAIT=4 VERIFY_LOCK_POLL=1 bash "$I" --section nested
has "lock: a nested run inside the holder is refused at once" 0 '^\[ok\]   inner refused$'
[ ! -e "$VL" ] && [ ! -e "$T/build.lock.d" ] && ok "... both locks are released after the nested refusal" || bad "... a lock was left behind after the nested case"
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
