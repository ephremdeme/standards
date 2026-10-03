#!/bin/sh
# Cases for bin/build-lock.sh and bin/with-build-lock (C5): one machine-wide Rust build at a time, re-entrant for child
# processes through BUILD_LOCK_TOKEN, a foreign lock waited for then refused (never stolen), one shared CARGO_TARGET_DIR
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
foreign(){ mkdir "$L"; printf 'token=999-1-deadbeef\npid=999999999\nwho=other-session\nsince=2026-10-03T10:00:00Z\ncwd=/elsewhere\n' > "$L/owner"; }
unforeign(){ rm -f "$L/owner"; rmdir "$L"; }

want "runs the command and propagates its exit code (7)" 7 'ran' in_dir "$A" sh "$WBL" sh -c 'echo ran; exit 7'
check_ "the lock is gone after the run" '[ ! -e "$L" ]'
foreign
want "control: a foreign lock with BUILD_LOCK_WAIT=0 -> exit 3 naming the holder" 3 '^with-build-lock: refused — the machine build lock is held by other-session \(pid 999999999, since 2026-10-03T10:00:00Z, cwd /elsewhere\) after waiting 0s; stale\? check pid 999999999, then rm .*/build\.lock\.d/owner && rmdir .*/build\.lock\.d$' \
  env BUILD_LOCK_WAIT=0 sh -c 'cd "$1" && sh "$2" touch "$3/ran-under-foreign"' _ "$A" "$WBL" "$T"
check_ "control: ... and the command did not run" '[ ! -e "$T/ran-under-foreign" ]'
check_ "control: ... and the foreign lock is untouched (never stolen or deleted)" 'grep -q "^token=999-1-deadbeef$" "$L/owner"'
want "control: a wrong BUILD_LOCK_TOKEN does not re-enter a foreign lock -> exit 3" 3 'held by other-session' \
  env BUILD_LOCK_WAIT=0 BUILD_LOCK_TOKEN=999-1-deadbeee sh -c 'cd "$1" && sh "$2" true' _ "$A" "$WBL"
want "control: BUILD_LOCK_WAIT=abc -> exit 2" 2 '^build-lock: BUILD_LOCK_WAIT must be a whole number of seconds$' env BUILD_LOCK_WAIT=abc sh -c 'cd "$1" && sh "$2" true' _ "$A" "$WBL"
(sleep 2; unforeign) &
want "a foreign lock released after 2 s with BUILD_LOCK_WAIT=10 -> waits, then runs" 0 'waiting for the build lock held by other-session \(pid 999999999, since 2026-10-03T10:00:00Z\)' \
  env BUILD_LOCK_WAIT=10 sh -c 'cd "$1" && sh "$2" sh -c "echo ran-after-wait"' _ "$A" "$WBL"
wait
check_ "... the waiting run released its own lock" '[ ! -e "$L" ]'
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
want "sccache installed -> RUSTC_WRAPPER=sccache" 0 '^W=sccache$' env PATH="$T/sc:$PATH" sh -c 'cd "$1" && sh "$2" sh -c "echo W=\$RUSTC_WRAPPER"' _ "$B" "$WBL"
want "sccache absent -> one note, no failure" 0 '^build-lock: sccache not installed — no compiler cache$' in_dir "$B" sh "$WBL" true
want "a caller's RUSTC_WRAPPER and CARGO_TARGET_DIR are kept" 0 "^W=mine T=$T/mytarget\$" env RUSTC_WRAPPER=mine CARGO_TARGET_DIR="$T/mytarget" sh -c 'cd "$1" && sh "$2" sh -c "echo W=\$RUSTC_WRAPPER T=\$CARGO_TARGET_DIR"' _ "$B" "$WBL"
want "control: no command -> usage, exit 2" 2 '^with-build-lock: usage: with-build-lock <command> \[args…\]$' sh "$WBL"
# check takes the lock around its Rust steps: a foreign lock is a BLOCKED rust line and exit 1, never a skipped pass.
mkdir -p "$T/h/.cargo/bin"; cp "$T/bin/cargo" "$T/h/.cargo/bin/cargo"; foreign
want "control: check under a foreign lock with BUILD_LOCK_WAIT=0 -> BLOCKED rust, exit 1" 1 '^BLOCKED rust \(build lock held by other-session, pid 999999999, since 2026-10-03T10:00:00Z\)$' \
  env HOME="$T/h" BUILD_LOCK_WAIT=0 sh -c 'cd "$1" && sh "$2"' _ "$A" "$S/bin/check"
unforeign
rm -rf "$T"; [ $R -eq 0 ] && echo "build-lock.t: all cases behave" || echo "build-lock.t: FAILURES"; exit $R
