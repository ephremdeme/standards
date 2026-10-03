#!/bin/sh
# Cases for bin/mutants (C4): disposable clones only, a green nextest run of the crate before any `--baseline=skip`
# batch, one --in-diff batch plus one --re batch, unviable mutants never counted as caught, survivors are a failure,
# the build lock held. A fake HOME holds a stub cargo (logs its arguments, writes outcome files) and a stub
# cargo-mutants. Run: sh standards/tests/mutants.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); M="$S/bin/mutants"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
unset BUILD_LOCK_TOKEN BUILD_LOCK_WAIT CARGO_TARGET_DIR RUSTC_WRAPPER
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
check_(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
H="$T/h"; mkdir -p "$H/.cargo/bin"; export HOME="$H" STUB="$T/stub"; mkdir -p "$STUB"
cat > "$H/.cargo/bin/cargo" << 'C'
#!/bin/sh
echo "cargo $*" >> "$STUB/cargo.log"
case "$1" in
  metadata) echo '{"packages":[{"name":"smoke"}]}';;
  clean) ;;
  nextest) exit "$(cat "$STUB/nextest.rc" 2>/dev/null || echo 0)";;
  mutants)
    o=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && o=$a; prev=$a; done
    b=${o##*/}; [ -e "$STUB/no-outcomes" ] && exit 0
    mkdir -p "$o/mutants.out"
    for k in caught missed timeout unviable; do
      n=$(cat "$STUB/$b.$k" 2>/dev/null || echo 0); : > "$o/mutants.out/$k.txt"; i=0
      while [ "$i" -lt "$n" ]; do echo "src/lib.rs:1:1: replace m$i" >> "$o/mutants.out/$k.txt"; i=$((i + 1)); done
    done
    exit "$(cat "$STUB/mutants.rc" 2>/dev/null || echo 0)";;
esac
exit 0
C
printf '#!/bin/sh\nexit 0\n' > "$H/.cargo/bin/cargo-mutants"; chmod +x "$H/.cargo/bin/cargo" "$H/.cargo/bin/cargo-mutants"
P="$T/p"; git init -q -b main "$P"; printf '.worktrees/\n/target/\n' > "$P/.gitignore"; printf '[package]\nname = "smoke"\nversion = "0.0.0"\n' > "$P/Cargo.toml"
mkdir -p "$P/src"; echo 'pub fn a() {}' > "$P/src/lib.rs"; git -C "$P" add -A; git -C "$P" commit -qm base; BASE=$(git -C "$P" rev-parse HEAD)
echo 'pub fn b() {}' >> "$P/src/lib.rs"; git -C "$P" commit -qam change
git -C "$P" worktree add -q "$P/.worktrees/lane" -b opus/lane main
C="$T/clone"; git clone -q --no-local "$P" "$C"; git -C "$C" remote remove origin; CH=$(git -C "$C" rev-parse HEAD)
git clone -q --no-local "$P" "$T/withremote"
git clone -q --no-local "$P" "$T/dirty"; git -C "$T/dirty" remote remove origin; echo x >> "$T/dirty/src/lib.rs"
printf 'f1\n\nf2\n' > "$T/funcs"
reset_stub(){ rm -f "$STUB"/*; }
want "control: a lane worktree -> exit 2" 2 "^mutants: refused — $P/.worktrees/lane is not a disposable clone \(its own \.git directory, no remote, clean tree\)\$" sh "$M" "$P/.worktrees/lane" "$BASE" smoke
want "control: the primary checkout (it has a lane worktree) -> exit 2" 2 'is not a disposable clone' sh "$M" "$P" "$BASE" smoke
want "control: a clone with a remote -> exit 2" 2 "^mutants: refused — $T/withremote is not a disposable clone" sh "$M" "$T/withremote" "$BASE" smoke
want "control: a dirty clone -> exit 2" 2 "^mutants: refused — $T/dirty is not a disposable clone" sh "$M" "$T/dirty" "$BASE" smoke
want "control: two arguments -> usage, exit 2" 2 '^mutants: usage: mutants <clone> <base> <crate> \[<functions file>\]$' sh "$M" "$C" "$BASE"
reset_stub; echo 1 > "$STUB/nextest.rc"
want "control: a red suite -> exit 1, no mutation run" 1 "^mutants: refused — the test suite is red at $CH \(cargo nextest run -p smoke exit 1\); mutation needs a green run first\$" sh "$M" "$C" "$BASE" smoke
check_ "control: ... no cargo mutants call followed" '! grep -q "^cargo mutants" "$STUB/cargo.log"'
reset_stub; echo 3 > "$STUB/diff.caught"; echo 5 > "$STUB/diff.unviable"; echo 1 > "$STUB/functions.caught"
want "green: caught 3 / unviable 5 -> unviable reported apart, exit 0" 0 '^mutants: diff batch — caught 3, missed 0, timeout 0, unviable 5 \(unviable not counted as caught\)$' sh "$M" "$C" "$BASE" smoke "$T/funcs"
n_test=$(grep -n '^cargo nextest run -p smoke' "$STUB/cargo.log" | head -n 1 | cut -d: -f1)
n_diff=$(grep -n '^cargo mutants .*--in-diff' "$STUB/cargo.log" | head -n 1 | cut -d: -f1)
n_re=$(grep -n '^cargo mutants .*--re f1 --re f2' "$STUB/cargo.log" | head -n 1 | cut -d: -f1)
check_ "order: the green nextest run, then the --in-diff batch, then the --re batch" '[ -n "$n_test" ] && [ -n "$n_diff" ] && [ -n "$n_re" ] && [ "$n_test" -lt "$n_diff" ] && [ "$n_diff" -lt "$n_re" ]'
for opt in '--in-place' '-p smoke' '--baseline=skip' '--test-tool nextest' '--timeout 180'; do
  check_ "both batches carry $opt" '[ "$(grep "^cargo mutants " "$STUB/cargo.log" | grep -c -- "$opt")" -eq 2 ]'
done
check_ "the diff batch reads git diff <base> HEAD" 'grep -q "^cargo mutants .*--in-diff [^ ]*/changes\.diff" "$STUB/cargo.log"'
reset_stub; echo 3 > "$STUB/diff.caught"; echo 5 > "$STUB/diff.unviable"; echo 1 > "$STUB/functions.caught"
want "the total line sums both batches" 0 '^mutants: total — caught 4, missed 0, timeout 0, unviable 5$' sh "$M" "$C" "$BASE" smoke "$T/funcs"
reset_stub; echo 2 > "$STUB/diff.caught"; echo 1 > "$STUB/diff.missed"; echo 2 > "$STUB/mutants.rc"
want "control: one missed mutant -> exit 1 naming the survivors file" 1 '^mutants: survivors — see .*/diff/mutants\.out/missed\.txt$' sh "$M" "$C" "$BASE" smoke
reset_stub; echo 2 > "$STUB/diff.caught"
want "no functions file -> one batch only" 0 '^mutants: total — caught 2, missed 0, timeout 0, unviable 0$' sh "$M" "$C" "$BASE" smoke
check_ "... exactly one cargo mutants call" '[ "$(grep -c "^cargo mutants " "$STUB/cargo.log")" -eq 1 ]'
reset_stub; touch "$STUB/no-outcomes"
want "control: missing outcome files -> exit 1" 1 '^mutants: no outcome files in .*/diff/mutants\.out \(cargo mutants did not finish\)$' sh "$M" "$C" "$BASE" smoke
reset_stub; echo 4 > "$STUB/mutants.rc"
want "control: cargo mutants rc outside {0,2,3} -> exit 1" 1 '^mutants: cargo mutants failed \(rc=4\) in the diff batch$' sh "$M" "$C" "$BASE" smoke
reset_stub; mkdir "$T/build.lock.d"; printf 'token=x\npid=999999999\nwho=other-session\nsince=2026-10-03T10:00:00Z\ncwd=/x\n' > "$T/build.lock.d/owner"
want "control: a foreign build lock with BUILD_LOCK_WAIT=0 -> exit 3" 3 '^mutants: refused — the machine build lock is held by other-session' env BUILD_LOCK_WAIT=0 sh "$M" "$C" "$BASE" smoke
check_ "control: ... nothing ran under the foreign lock" '[ ! -s "$STUB/cargo.log" ]'
rm -f "$T/build.lock.d/owner"; rmdir "$T/build.lock.d"
rm -rf "$T"; [ $R -eq 0 ] && echo "mutants.t: all cases behave" || echo "mutants.t: FAILURES"; exit $R
