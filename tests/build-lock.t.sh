#!/bin/sh
# Cases for bin/build-lock.sh and bin/with-build-lock (C5): one machine-wide Rust build at a time, re-entrant for child
# processes through BUILD_LOCK_TOKEN, a foreign lock waited for then refused (a live holder's never stolen; a dead
# holder's lock older than BUILD_LOCK_STALE taken, exchange BACKLOG 56), one shared CARGO_TARGET_DIR
# per repo made safe by the switch-clean rule, sccache when installed. TMPDIR points into the temp dir, so the real
# ${TMPDIR:-/tmp}/build.lock.d is never touched. Run: sh standards/tests/build-lock.t.sh -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); WBL="$S/bin/with-build-lock"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR; L="$T/build.lock.d"
unset BUILD_LOCK_TOKEN BUILD_LOCK_WAIT CARGO_TARGET_DIR RUSTC_WRAPPER
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
check_(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Stub cargo: logs its arguments; `metadata` lists two workspace members; `clean` fails when $T/clean.rc says so.
mkdir -p "$T/bin" "$T/sc"
cat > "$T/bin/cargo" << 'C'
#!/bin/sh
echo "cargo $*" >> "$TMPDIR/cargo.log"
case "$1" in
  metadata) echo '{"packages":[{"name":"m1"},{"name":"m2"}]}';;
  clean) [ -f "$TMPDIR/clean.rc" ] && exit "$(cat "$TMPDIR/clean.rc")";;
esac
exit 0
C
printf '#!/bin/sh\nexit 0\n' > "$T/sc/sccache"; chmod +x "$T/bin/cargo" "$T/sc/sccache"
PATH="$T/bin:/usr/bin:/bin"; export PATH
P="$T/p"; git init -q -b main "$P"; printf '.worktrees/\n/target/\n' > "$P/.gitignore"; printf '[workspace]\nmembers = []\n' > "$P/Cargo.toml"
git -C "$P" add -A; git -C "$P" commit -qm base; P=$(cd "$P" && pwd -P)
git -C "$P" worktree add -q "$P/.worktrees/a" -b lane/a main; git -C "$P" worktree add -q "$P/.worktrees/b" -b lane/b main
A="$P/.worktrees/a"; B="$P/.worktrees/b"
in_dir(){ (cd "$1" && shift && "$@"); }
lockfile(){ mkdir "$L"; printf 'token=999-1-deadbeef\npid=%s\nwho=other-session\nsince=%s\ncwd=/elsewhere\n' "$1" "$2" > "$L/owner"; }
foreign(){ lockfile 999999999 2026-10-03T10:00:00Z; }   # a dead holder (no such pid) and an old lock: the stale rule takes it
unforeign(){ rm -f "$L/owner"; rmdir "$L"; }
# A LIVE holder on this box (killed by its pid at the end of the judge): its lock is never taken, however old.
sleep 300 > /dev/null 2>&1 & LIVE=$!
live(){ lockfile "$LIVE" 2026-10-03T10:00:00Z; }
notaken(){ # notaken <label> <pid> <since> [VAR=value...]: BUILD_LOCK_WAIT=0 -> exit 3, never taken, nothing ran, the owner untouched
  label=$1; lockfile "$2" "$3"; shift 3; rm -f "$T/ran-nt"
  out=$(env BUILD_LOCK_WAIT=0 "$@" sh -c 'cd "$1" && sh "$2" touch "$3/ran-nt"' _ "$A" "$WBL" "$T" 2>&1); rc=$?
  if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q '^with-build-lock: refused — the machine build lock is held by other-session' \
     && ! printf '%s' "$out" | grep -q 'took the stale lock' && [ ! -e "$T/ran-nt" ] && grep -qx 'token=999-1-deadbeef' "$L/owner"; then ok "$label"
  else bad "$label (rc=$rc want 3, held and untouched)"; printf '%s\n' "$out" | tail -n 4 | sed 's/^/        /'; fi
  unforeign; }

want "runs the command and propagates its exit code (7)" 7 'ran' in_dir "$A" sh "$WBL" sh -c 'echo ran; exit 7'
check_ "the lock is gone after the run" '[ ! -e "$L" ]'
# The stale rule (exchange BACKLOG 56): a dead holder's lock older than BUILD_LOCK_STALE (default 900 s) is taken.
foreign
want "a dead holder's lock older than BUILD_LOCK_STALE=900 with BUILD_LOCK_WAIT=0 -> taken, the command runs, exit 0" 0 '^build-lock: took the stale lock of other-session \(pid 999999999, since 2026-10-03T10:00:00Z\): the holder is gone and the lock is older than 900s$' \
  env BUILD_LOCK_WAIT=0 sh -c 'cd "$1" && sh "$2" touch "$3/ran-after-take"' _ "$A" "$WBL" "$T"
check_ "... the command ran" '[ -e "$T/ran-after-take" ]'
check_ "... and the lock is released afterwards" '[ ! -e "$L" ] && ! ls "$T" | grep -q "^build\.lock\.d\."'
live
want "control: a LIVE holder's old lock with BUILD_LOCK_WAIT=0 -> exit 3 naming the holder" 3 "^with-build-lock: refused — the machine build lock is held by other-session \\(pid $LIVE, since 2026-10-03T10:00:00Z, cwd /elsewhere\\) after waiting 0s; stale\\? check pid $LIVE, then rm .*/build\\.lock\\.d/owner && rmdir .*/build\\.lock\\.d" \
  env BUILD_LOCK_WAIT=0 sh -c 'cd "$1" && sh "$2" touch "$3/ran-under-foreign"' _ "$A" "$WBL" "$T"
check_ "control: ... and the command did not run" '[ ! -e "$T/ran-under-foreign" ]'
check_ "control: ... and the live holder's lock is untouched (never stolen or deleted)" 'grep -qx "token=999-1-deadbeef" "$L/owner" && grep -qx "pid=$LIVE" "$L/owner"'
want "control: a wrong BUILD_LOCK_TOKEN does not re-enter a foreign lock -> exit 3" 3 'held by other-session' \
  env BUILD_LOCK_WAIT=0 BUILD_LOCK_TOKEN=999-1-deadbeee sh -c 'cd "$1" && sh "$2" true' _ "$A" "$WBL"
want "control: BUILD_LOCK_WAIT=abc -> exit 2" 2 '^build-lock: BUILD_LOCK_WAIT must be a whole number of seconds$' env BUILD_LOCK_WAIT=abc sh -c 'cd "$1" && sh "$2" true' _ "$A" "$WBL"
for v in abc 12345678 -1; do
  want "control: BUILD_LOCK_STALE=$v -> exit 2" 2 '^build-lock: BUILD_LOCK_STALE must be a whole number of seconds$' env BUILD_LOCK_WAIT=0 BUILD_LOCK_STALE="$v" sh -c 'cd "$1" && sh "$2" true' _ "$A" "$WBL"
done
(sleep 2; unforeign) & UF=$!
want "a live holder's lock released after 2 s with BUILD_LOCK_WAIT=10 -> waits, then runs" 0 "waiting for the build lock held by other-session \\(pid $LIVE, since 2026-10-03T10:00:00Z\\)" \
  env BUILD_LOCK_WAIT=10 sh -c 'cd "$1" && sh "$2" sh -c "echo ran-after-wait"' _ "$A" "$WBL"
wait "$UF"
check_ "... the waiting run released its own lock" '[ ! -e "$L" ]'
# A lock is taken only when ALL of: numeric pid, /proc/1 present and /proc/<pid> absent, a since that parses, old enough.
notaken "control: a dead holder whose lock is younger than BUILD_LOCK_STALE -> held" 999999999 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
notaken "control: BUILD_LOCK_STALE=0 disables the rule: a dead holder's old lock -> held" 999999999 2026-10-03T10:00:00Z BUILD_LOCK_STALE=0
notaken "control: pid=abc (not numeric), old lock -> held" abc 2026-10-03T10:00:00Z
notaken "control: pid 0<live pid> (a leading zero names no /proc entry) -> held" "0$LIVE" 2026-10-03T10:00:00Z
notaken "control: since=yesterday (not the owner file's own format) -> held" 999999999 yesterday
notaken "control: since=2026-13-45T99:00:00Z (does not parse) -> held" 999999999 2026-13-45T99:00:00Z
notaken "control: a live holder's lock older than BUILD_LOCK_STALE=1 -> held" "$LIVE" 2026-10-03T10:00:00Z BUILD_LOCK_STALE=1
mkdir "$L"; printf 'pid=999999999\nwho=other-session\nsince=2026-10-03T10:00:00Z\ncwd=/elsewhere\n' > "$L/owner"
want "control: an owner file without token= (dead pid, old since) -> held, exit 3" 3 '^with-build-lock: refused — the machine build lock is held by other-session' \
  env BUILD_LOCK_WAIT=0 sh -c 'cd "$1" && sh "$2" true' _ "$A" "$WBL"
check_ "control: ... the token-less owner file is untouched" '[ "$(cat "$L/owner")" = "$(printf "pid=999999999\nwho=other-session\nsince=2026-10-03T10:00:00Z\ncwd=/elsewhere")" ]'
unforeign
# Review round (blocker): two waiters in lockstep on one dead old lock. The take never vacates the lock path (the owner
# file is renamed aside, never the directory), so one takes it and the other waits: never two holders at once.
foreign; : > "$T/lockstep.log"; printf 'echo start >> "$1"; sleep 1; echo end >> "$1"\n' > "$T/step.sh"
env BUILD_LOCK_WAIT=30 sh -c 'cd "$1" && sh "$2" sh "$3/step.sh" "$3/lockstep.log"' _ "$A" "$WBL" "$T" > "$T/ls1.err" 2>&1 & LS1=$!
env BUILD_LOCK_WAIT=30 sh -c 'cd "$1" && sh "$2" sh "$3/step.sh" "$3/lockstep.log"' _ "$A" "$WBL" "$T" > "$T/ls2.err" 2>&1 & LS2=$!
wait "$LS1"; LR1=$?; wait "$LS2"; LR2=$?
check_ "two waiters in lockstep on a dead old lock -> both exit 0, start/end strictly one pair after the other" '[ "$LR1" -eq 0 ] && [ "$LR2" -eq 0 ] && [ "$(tr "\n" " " < "$T/lockstep.log")" = "start end start end " ]'
check_ "... exactly one of them took the stale lock" '[ "$(cat "$T/ls1.err" "$T/ls2.err" | grep -c "^build-lock: took the stale lock of other-session")" -eq 1 ]'
check_ "... the lock dir is gone and no owner.stale.* or build.lock.d.* is left" '[ ! -e "$L" ] && ! ls -a "$T" | grep -q "^build\.lock\.d\."'
lockfile 999999999 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
want "waiting on a dead holder's young lock names the rule and the manual removal" 3 "^build-lock: pid 999999999 is not running — the lock is possibly stale; it is taken automatically once older than BUILD_LOCK_STALE=900s \\(its owner file renamed aside, never the directory\\); by hand: rm -f .*/build\\.lock\\.d/owner .*/build\\.lock\\.d/owner\\.stale\\.\\* && rmdir .*/build\\.lock\\.d\$" \
  env BUILD_LOCK_WAIT=1 sh -c 'cd "$1" && sh "$2" true' _ "$A" "$WBL"
unforeign
want "nested with-build-lock re-enters through the token; the lock stays until the outer exits" 0 '^nested-ok$' \
  in_dir "$A" sh "$WBL" sh -c 'sh "$1" sh -c "echo inner" > "$3/inner.out" && [ -d "$2" ] && grep -q inner "$3/inner.out" && echo nested-ok' _ "$WBL" "$L" "$T"
check_ "... and is released by the outer one" '[ ! -e "$L" ]'
want "CARGO_TARGET_DIR is <primary checkout>/target/shared from a lane worktree" 0 "^T=$P/target/shared\$" in_dir "$A" sh "$WBL" sh -c 'echo "T=$CARGO_TARGET_DIR"'
: > "$T/cargo.log"; in_dir "$A" sh "$WBL" cargo build > /dev/null 2>&1
: > "$T/cargo.log"; in_dir "$B" sh "$WBL" cargo build > /dev/null 2>&1
check_ "switch A->B: clean -p of every workspace member, then the command" '[ "$(cat "$T/cargo.log")" = "$(printf "cargo metadata --no-deps --format-version 1\ncargo clean -p m1 -p m2\ncargo build")" ]'
check_ "... and the stamp names B" '[ "$(cat "$P/target/shared/.standards-worktree")" = "$B" ]'
: > "$T/cargo.log"; in_dir "$B" sh "$WBL" cargo build > /dev/null 2>&1
check_ "B->B: no clean, only the command" '[ "$(cat "$T/cargo.log")" = "cargo build" ]'
echo 101 > "$T/clean.rc"
want "control: a failing cargo clean -> exit 1, nothing built" 1 "^build-lock: could not clean the previous worktree's workspace crates; nothing was built\$" in_dir "$A" sh "$WBL" touch "$T/built-after-failed-clean"
check_ "control: ... the command did not run" '[ ! -e "$T/built-after-failed-clean" ]'
check_ "control: ... the stamp still names B" '[ "$(cat "$P/target/shared/.standards-worktree")" = "$B" ]'
rm -f "$T/clean.rc"
# Review round: the switch clean covers every profile directory present in the shared target, not only dev (a release
# binary of A must never run as B's: the game's dev-identity-absent check builds --release).
mkdir -p "$P/target/shared/debug/.fingerprint" "$P/target/shared/release/.fingerprint" "$P/target/shared/ci/.fingerprint"
: > "$T/cargo.log"; in_dir "$A" sh "$WBL" cargo build --release > /dev/null 2>&1
check_ "switch B->A with debug, release and a custom profile present: dev clean" 'grep -qx "cargo clean -p m1 -p m2" "$T/cargo.log"'
check_ "... --release clean" 'grep -qx "cargo clean -p m1 -p m2 --release" "$T/cargo.log"'
check_ "... --profile ci clean" 'grep -qx "cargo clean -p m1 -p m2 --profile ci" "$T/cargo.log"'
check_ "... then the command" '[ "$(tail -n 1 "$T/cargo.log")" = "cargo build --release" ]'
# Review round: cargo reachable only by an absolute path (not on PATH, not in $HOME/.cargo/bin) must not skip the clean.
mkdir -p "$T/nohome" "$T/h2/.cargo/bin"; cp "$T/bin/cargo" "$T/h2/.cargo/bin/cargo"
: > "$T/cargo.log"
want "control: cargo only by absolute path, stamp differs -> exit 1, nothing built" 1 '^build-lock: cargo is not on PATH or in \$HOME/\.cargo/bin, so the previous worktree.s workspace crates cannot be cleaned; nothing was built$' \
  env HOME="$T/nohome" PATH=/usr/bin:/bin sh -c 'cd "$1" && sh "$2" "$3/bin/cargo" build' _ "$B" "$WBL" "$T"
check_ "control: ... the absolute-path cargo did not run" '! grep -q "^cargo build" "$T/cargo.log"'
want "cargo only in \$HOME/.cargo/bin -> found, the switch clean runs" 0 '' env HOME="$T/h2" PATH=/usr/bin:/bin sh -c 'cd "$1" && sh "$2" "$3/h2/.cargo/bin/cargo" build' _ "$B" "$WBL" "$T"
check_ "... clean recorded before the command (every profile, then the build)" '[ "$(grep -c "^cargo clean -p m1 -p m2" "$T/cargo.log")" -eq 3 ] && grep -qx "cargo clean -p m1 -p m2 --release" "$T/cargo.log" && [ "$(tail -n 1 "$T/cargo.log")" = "cargo build" ]'
want "sccache installed -> RUSTC_WRAPPER=sccache" 0 '^W=sccache$' env PATH="$T/sc:$PATH" sh -c 'cd "$1" && sh "$2" sh -c "echo W=\$RUSTC_WRAPPER"' _ "$B" "$WBL"
want "... and one line names the sccache in use" 0 "^build-lock: sccache $T/sc/sccache\$" env PATH="$T/sc:$PATH" sh -c 'cd "$1" && sh "$2" true' _ "$B" "$WBL"
# A HOME without sccache: the machine's own ~/.cargo/bin/sccache must not decide this case.
want "sccache absent -> one note, no failure" 0 '^build-lock: sccache not installed — no compiler cache$' env HOME="$T/nohome" sh -c 'cd "$1" && sh "$2" true' _ "$B" "$WBL"
# sccache installed in $HOME/.cargo/bin but that directory not on PATH (the 2026-10-13 measurement: 412 requests, 2 hits):
# found the way cargo is, RUSTC_WRAPPER set and the directory appended to the PATH the command sees.
mkdir -p "$T/hs/.cargo/bin"; cp "$T/sc/sccache" "$T/hs/.cargo/bin/sccache"
want "control: sccache only in \$HOME/.cargo/bin, not on PATH -> found and named" 0 "^build-lock: sccache $T/hs/\.cargo/bin/sccache\$" env HOME="$T/hs" sh -c 'cd "$1" && sh "$2" true' _ "$B" "$WBL"
want "control: ... RUSTC_WRAPPER=sccache reaches the command, with \$HOME/.cargo/bin last on its PATH" 0 "^W=sccache P=$T/bin:/usr/bin:/bin:$T/hs/\.cargo/bin\$" \
  env HOME="$T/hs" sh -c 'cd "$1" && sh "$2" sh -c "echo W=\$RUSTC_WRAPPER P=\$PATH"' _ "$B" "$WBL"
# Exchange BACKLOG 46 (b): $HOME/.cargo/bin reached PATH only on a worktree switch (or through the sccache lookup), so a
# later call in the same worktree failed `cargo: not found`. Cargo and sccache only in $HOME/.cargo/bin, the caller's
# RUSTC_WRAPPER=sccache, the stamp already naming B (no switch): cargo must still be found.
mkdir -p "$T/hb/.cargo/bin"; cp "$T/bin/cargo" "$T/hb/.cargo/bin/cargo"; cp "$T/sc/sccache" "$T/hb/.cargo/bin/sccache"
want "control: BACKLOG 46 (b): a second call in the same worktree, cargo only in \$HOME/.cargo/bin -> cargo found" 0 '^second-call-built W=sccache$' \
  env HOME="$T/hb" PATH=/usr/bin:/bin RUSTC_WRAPPER=sccache sh -c 'cd "$1" && sh "$2" sh -c "cargo build && echo second-call-built W=\$RUSTC_WRAPPER"' _ "$B" "$WBL"
want "a caller's RUSTC_WRAPPER and CARGO_TARGET_DIR are kept" 0 "^W=mine T=$T/mytarget\$" env RUSTC_WRAPPER=mine CARGO_TARGET_DIR="$T/mytarget" sh -c 'cd "$1" && sh "$2" sh -c "echo W=\$RUSTC_WRAPPER T=\$CARGO_TARGET_DIR"' _ "$B" "$WBL"
want "control: no command -> usage, exit 2" 2 '^with-build-lock: usage: with-build-lock <command> \[args…\]$' sh "$WBL"
# check takes the lock around its Rust steps: a foreign lock is a BLOCKED rust line and exit 1, never a skipped pass.
mkdir -p "$T/h/.cargo/bin"; cp "$T/bin/cargo" "$T/h/.cargo/bin/cargo"; live
want "control: check under a live foreign lock with BUILD_LOCK_WAIT=0 -> BLOCKED rust, exit 1" 1 "^BLOCKED rust \\(build lock held by other-session, pid $LIVE, since 2026-10-03T10:00:00Z\\)\$" \
  env HOME="$T/h" BUILD_LOCK_WAIT=0 sh -c 'cd "$1" && sh "$2"' _ "$A" "$S/bin/check"
unforeign
kill "$LIVE"; wait "$LIVE" 2>/dev/null
rm -rf "$T"; [ $R -eq 0 ] && echo "build-lock.t: all cases behave" || echo "build-lock.t: FAILURES"; exit $R
