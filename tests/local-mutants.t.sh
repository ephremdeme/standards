#!/bin/sh
# Cases for bin/local-mutants (exchange D-110, BACKLOG 40): disposable clones only; every cargo mutants call inside a
# `systemd-run --user --scope` with MemoryMax and MemorySwapMax=0 (never uncapped); --in-diff over <base>..HEAD limited
# to <crate>/src, --jobs 1 --timeout 60, nextest, the replay proptest excluded, optional --tests; cargo mutants' own
# baseline; sccache required unless MUTANTS_NO_SCCACHE=1; Σ tested equal to --list; one run: line. PATH is only the
# stub systemd-run and links to system tools: cargo and sccache exist only in the fake HOME's .cargo/bin, so a run
# proves the script put $HOME/.cargo/bin first and no real cargo can be reached. The stub cargo logs its arguments and
# environment, answers --list and writes outcome files; the stub systemd-run logs its arguments and runs the command
# after `--`, or fails to create the scope. Run: sh standards/tests/local-mutants.t.sh -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); LM="$S/bin/local-mutants"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
unset BUILD_LOCK_TOKEN BUILD_LOCK_WAIT CARGO_TARGET_DIR RUSTC_WRAPPER MUTANTS_MEMORY_MAX MUTANTS_NO_SCCACHE
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
check_(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
H="$T/h"; H2="$T/h2"; mkdir -p "$H/.cargo/bin" "$H2/.cargo/bin" "$T/bin" "$T/sys"; export HOME="$H" STUB="$T/stub"; mkdir -p "$STUB"
# The stub cargo: list = how many mutants --list prints; caught/missed/timeout/unviable = outcome lines; list.rc,
# mutants.rc = exit codes; no-outcomes = exit without writing them. It copies the --in-diff file to diff.seen.
cat > "$H/.cargo/bin/cargo" << 'C'
#!/bin/sh
echo "scope=${STUB_SCOPE:-none} wrapper=[${RUSTC_WRAPPER-unset}] cargo $*" >> "$STUB/cargo.log"
case "$1" in
  metadata) echo '{"packages":[{"name":"ledger"},{"name":"other"}]}';;
  clean) ;;
  mutants)
    o=; d=; prev=; for a in "$@"; do [ "$prev" = -o ] && o=$a; [ "$prev" = --in-diff ] && d=$a; prev=$a; done
    [ -z "$d" ] || cp "$d" "$STUB/diff.seen"
    case " $* " in
      *" --list "*)
        rc=$(cat "$STUB/list.rc" 2>/dev/null || echo 0); [ "$rc" -eq 0 ] || exit "$rc"
        i=0; n=$(cat "$STUB/list" 2>/dev/null || echo 0)
        while [ "$i" -lt "$n" ]; do i=$((i + 1)); echo "ledger/src/lib.rs:$i:5: replace f$i -> bool with true"; done; exit 0;;
    esac
    [ -e "$STUB/no-outcomes" ] && exit 0
    mkdir -p "$o/mutants.out"
    for k in caught missed timeout unviable; do
      : > "$o/mutants.out/$k.txt"; i=0; n=$(cat "$STUB/$k" 2>/dev/null || echo 0)
      while [ "$i" -lt "$n" ]; do i=$((i + 1)); echo "ledger/src/lib.rs:$i:5: replace f$i ($k)" >> "$o/mutants.out/$k.txt"; done
    done
    exit "$(cat "$STUB/mutants.rc" 2>/dev/null || echo 0)";;
esac
exit 0
C
cat > "$T/bin/systemd-run" << 'SD'
#!/bin/sh
echo "systemd-run $*" >> "$STUB/systemd-run.log"
if [ -e "$STUB/scope-fail" ]; then echo "Failed to start transient scope unit: Process org.freedesktop.systemd1 exited with status 1" >&2; exit 1; fi
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
[ $# -ge 2 ] || { echo "systemd-run stub: no command after --" >&2; exit 64; }
shift; STUB_SCOPE=capped; export STUB_SCOPE; exec "$@"
SD
printf '#!/bin/sh\necho "sccache stub must not be called" >&2; exit 99\n' > "$H/.cargo/bin/sccache"
chmod +x "$H/.cargo/bin/cargo" "$H/.cargo/bin/sccache" "$T/bin/systemd-run"; cp "$H/.cargo/bin/cargo" "$H2/.cargo/bin/cargo"
# The fixture: a workspace (ledger, other); the change edits ledger/src/lib.rs, a comment in model.rs, adds new.rs and
# notes.md, deletes gone.rs, and edits other/src/x.rs and ledger/Cargo.toml.
P="$T/p"; git init -q -b main "$P"; printf '/target/\n.worktrees/\n' > "$P/.gitignore"
printf '[workspace]\nmembers = ["ledger", "other"]\n' > "$P/Cargo.toml"
mkdir -p "$P/ledger/src" "$P/other/src"; printf '[package]\nname = "ledger"\n' > "$P/ledger/Cargo.toml"
echo 'pub fn a() {}' > "$P/ledger/src/lib.rs"; echo 'pub fn m() {}' > "$P/ledger/src/model.rs"
echo 'pub fn g() {}' > "$P/ledger/src/gone.rs"; echo 'pub fn x() {}' > "$P/other/src/x.rs"
git -C "$P" add -A; git -C "$P" commit -qm base; BASE=$(git -C "$P" rev-parse HEAD)
echo 'pub fn b() {}' >> "$P/ledger/src/lib.rs"; echo '// a comment only' >> "$P/ledger/src/model.rs"
echo 'pub fn n() {}' > "$P/ledger/src/new.rs"; echo notes > "$P/ledger/src/notes.md"; git -C "$P" rm -q ledger/src/gone.rs
echo 'pub fn y() {}' >> "$P/other/src/x.rs"; echo 'edition = "2024"' >> "$P/ledger/Cargo.toml"
git -C "$P" add -A; git -C "$P" commit -qm change
git -C "$P" worktree add -q "$P/.worktrees/lane" -b opus/lane main
C="$T/clone"; git clone -q --no-local "$P" "$C"; git -C "$C" remote remove origin; CH=$(git -C "$C" rev-parse HEAD)
git clone -q --no-local "$P" "$T/withremote"
git clone -q --no-local "$P" "$T/dirty"; git -C "$T/dirty" remote remove origin; echo x >> "$T/dirty/ledger/src/lib.rs"
O="$T/odd"; git clone -q --no-local "$P" "$O"; git -C "$O" remote remove origin
echo 'pub fn s() {}' > "$O/ledger/src/a b.rs"; git -C "$O" add -A; git -C "$O" commit -qm odd
# From here PATH is the stub systemd-run plus links to the system tools the script and this test use; nothing else.
for t in sh dirname git grep sed cat cut head tail sort paste tr wc mktemp rm rmdir mkdir mv cp od date env jq sleep ls touch; do
  p=$(command -v "$t") && case "$p" in /*) ln -s "$p" "$T/sys/$t";; esac; done
printf '#!/bin/sh\nexit 0\n' > "$T/sys/true"; chmod +x "$T/sys/true"   # the scope probe's command; a builtin has no path
PATH="$T/bin:$T/sys"; export PATH
[ "$(command -v systemd-run)" = "$T/bin/systemd-run" ] && ! command -v cargo >/dev/null && ! command -v sccache >/dev/null \
  || { echo "FAIL    PATH reaches a cargo or sccache, or not the stub systemd-run; aborting"; rm -rf "$T"; exit 1; }
FILES=ledger/src/lib.rs,ledger/src/model.rs,ledger/src/new.rs
reset_stub(){ rm -rf "$STUB"/* "$C/mutants-run.txt"; }
lm(){ "$@" > "$T/out" 2> "$T/err"; lrc=$?; }   # lm <cmd...>: stdout and stderr apart, the exit code in $lrc
runline(){ # runline <tested> <missed> <caught> <unviable> <timeout>: the exact run: line for the clone's head
  printf 'run: %s files: %s tested: %s missed: %s caught: %s unviable: %s timeout: %s' "$CH" "$FILES" "$1" "$2" "$3" "$4" "$5"; }
printed(){ # printed <label> <rc> <line>: after lm — exit <rc>, stdout exactly that one line, <clone>/mutants-run.txt holding it
  if [ "$lrc" -eq "$2" ] && [ "$(cat "$T/out")" = "$3" ] && [ "$(grep -c '' "$T/out")" -eq 1 ] && [ "$(cat "$C/mutants-run.txt" 2>/dev/null)" = "$3" ]; then ok "$1"
  else bad "$1 (rc=$lrc want $2)"; sed 's/^/        out: /' "$T/out"; tail -n 4 "$T/err" | sed 's/^/        err: /'; fi; }
failed(){ # failed <label> <rc> <regex>: after lm — exit <rc>, its own message on stderr, nothing on stdout, no mutants-run.txt
  if [ "$lrc" -eq "$2" ] && grep -Eq -- "$3" "$T/err" && [ ! -s "$T/out" ] && [ ! -f "$C/mutants-run.txt" ]; then ok "$1"
  else bad "$1 (rc=$lrc want $2, /$3/)"; sed 's/^/        out: /' "$T/out"; tail -n 4 "$T/err" | sed 's/^/        err: /'; fi; }
nocall(){ ! grep -q "cargo mutants" "$STUB/cargo.log" 2>/dev/null; }
# Refusals before anything runs (exit 2).
reset_stub
want "control: a lane worktree -> exit 2" 2 "^local-mutants: refused — $P/\.worktrees/lane is not a disposable clone \(its own \.git directory, no remote, clean tree\)\$" sh "$LM" "$P/.worktrees/lane" "$BASE" ledger
want "control: the primary checkout (it has a lane worktree) -> exit 2" 2 "^local-mutants: refused — $P is not a disposable clone" sh "$LM" "$P" "$BASE" ledger
want "control: a clone with a remote -> exit 2" 2 "^local-mutants: refused — $T/withremote is not a disposable clone" sh "$LM" "$T/withremote" "$BASE" ledger
want "control: a dirty clone -> exit 2" 2 "^local-mutants: refused — $T/dirty is not a disposable clone" sh "$LM" "$T/dirty" "$BASE" ledger
want "control: two arguments -> usage, exit 2" 2 '^local-mutants: usage: local-mutants <clone> <base> <crate> \[--tests <name>\[,<name>\.\.\.\]\]$' sh "$LM" "$C" "$BASE"
want "control: --tests without a list -> usage, exit 2" 2 '^local-mutants: usage: ' sh "$LM" "$C" "$BASE" ledger --tests
want "control: a fourth argument other than --tests -> usage, exit 2" 2 '^local-mutants: usage: ' sh "$LM" "$C" "$BASE" ledger --test e3_model
want "control: a crate with a path in it -> usage, exit 2" 2 '^local-mutants: usage: ' sh "$LM" "$C" "$BASE" ../ledger
want "control: a base that looks like an option -> usage, exit 2" 2 '^local-mutants: usage: ' sh "$LM" "$C" --output=x ledger
want "control: a base that is not a commit -> exit 2" 2 "^local-mutants: refused — nosuchbase is not a commit in $C\$" sh "$LM" "$C" nosuchbase ledger
want "control: --tests with an empty list -> exit 2" 2 "^local-mutants: refused — --tests needs at least one test binary name\$" sh "$LM" "$C" "$BASE" ledger --tests ''
for tn in e3-model 'e3_model,,e3_fees' 'a b' '../x'; do
  want "control: --tests '$tn' -> exit 2" 2 "^local-mutants: refused — --tests '$tn' has a name that is not \[A-Za-z0-9_\]\+\$" sh "$LM" "$C" "$BASE" ledger --tests "$tn"
done
for mm in 3GB 512 G 1.5G -1G; do
  want "control: MUTANTS_MEMORY_MAX=$mm -> exit 2" 2 "^local-mutants: refused — MUTANTS_MEMORY_MAX must be digits followed by K, M or G \(like 3G\), got '$mm'\$" env MUTANTS_MEMORY_MAX="$mm" sh "$LM" "$C" "$BASE" ledger
done
check_ "control: ... no systemd-run and no cargo call for any of them" '[ ! -e "$STUB/systemd-run.log" ] && [ ! -e "$STUB/cargo.log" ]'
reset_stub
want "control: no sccache in \$HOME/.cargo/bin or on PATH -> exit 2" 2 "^local-mutants: refused — sccache is not in \\\$HOME/\.cargo/bin or on PATH; every mutation run is cached \(MUTANTS_NO_SCCACHE=1 opts out\)\$" env HOME="$H2" sh "$LM" "$C" "$BASE" ledger
want "control: MUTANTS_NO_SCCACHE=yes -> exit 2" 2 "^local-mutants: refused — MUTANTS_NO_SCCACHE must be 1 or unset, got 'yes'\$" env MUTANTS_NO_SCCACHE=yes sh "$LM" "$C" "$BASE" ledger
check_ "control: ... no systemd-run and no cargo call for either" '[ ! -e "$STUB/systemd-run.log" ] && [ ! -e "$STUB/cargo.log" ]'
reset_stub
want "control: no systemd-run on PATH -> exit 2, never uncapped" 2 "^local-mutants: refused — systemd-run is not on PATH; cargo mutants never runs without the memory cap\$" env PATH="$T/sys" sh "$LM" "$C" "$BASE" ledger
check_ "control: ... no cargo call at all" '[ ! -e "$STUB/cargo.log" ]'
reset_stub; touch "$STUB/scope-fail"
want "control: systemd-run cannot create the scope -> exit 2" 2 "^local-mutants: refused — systemd-run could not create a scope with MemoryMax=3G and MemorySwapMax=0 \(Failed to start transient scope unit: .*\); cargo mutants never runs uncapped\$" sh "$LM" "$C" "$BASE" ledger
check_ "control: ... no cargo mutants call" 'nocall'
reset_stub
want "control: no <crate>/src .rs file changed in the diff -> exit 2" 2 "^local-mutants: refused — no api/src/\*\*/\*\.rs file changed in $BASE\.\.HEAD; nothing to mutate\$" sh "$LM" "$C" "$BASE" api
reset_stub
want "control: a changed file name the run: line cannot carry -> exit 2" 2 "^local-mutants: refused — the changed file 'ledger/src/a b\.rs' has a name the run: line cannot carry \(only A-Z a-z 0-9 _ \. / -\)\$" sh "$LM" "$O" "$BASE" ledger
reset_stub; mkdir "$T/build.lock.d"; printf 'token=x\npid=999999999\nwho=other-session\nsince=2026-10-13T10:00:00Z\ncwd=/x\n' > "$T/build.lock.d/owner"
want "control: a foreign build lock with BUILD_LOCK_WAIT=0 -> exit 3" 3 '^local-mutants: refused — the machine build lock is held by other-session' env BUILD_LOCK_WAIT=0 sh "$LM" "$C" "$BASE" ledger
check_ "control: ... no cargo mutants call under the foreign lock" 'nocall'
rm -f "$T/build.lock.d/owner"; rmdir "$T/build.lock.d"
# Runs that are not green (exit 1).
reset_stub; echo 5 > "$STUB/list"; echo 3 > "$STUB/caught"; lm sh "$LM" "$C" "$BASE" ledger
failed "control: tested 3 != 5 listed -> exit 1, incomplete run" 1 '^local-mutants: incomplete run — tested 3 \(missed 0, caught 3, unviable 0, timeout 0\) of 5 listed mutants$'
reset_stub; echo 3 > "$STUB/list"; echo 2 > "$STUB/caught"; echo 1 > "$STUB/missed"; echo 2 > "$STUB/mutants.rc"; lm sh "$LM" "$C" "$BASE" ledger
printed "control: one missed mutant -> exit 1 with the run: line" 1 "$(runline 3 1 2 0 0)"
check_ "control: ... stderr points at missed.txt and timeout.txt" 'grep -q "^local-mutants: survivors — see .*/mutants\.out/missed\.txt and .*/mutants\.out/timeout\.txt\$" "$T/err"'
reset_stub; echo 2 > "$STUB/list"; echo 1 > "$STUB/caught"; echo 1 > "$STUB/timeout"; echo 3 > "$STUB/mutants.rc"; lm sh "$LM" "$C" "$BASE" ledger
printed "control: one timed-out mutant -> exit 1 with the run: line (a timeout is never caught)" 1 "$(runline 2 0 1 0 1)"
reset_stub; echo 2 > "$STUB/list"; echo 2 > "$STUB/caught"; echo 2 > "$STUB/mutants.rc"; lm sh "$LM" "$C" "$BASE" ledger
failed "control: cargo mutants exit 2 with no missed or timed-out mutant listed -> exit 1" 1 '^local-mutants: cargo mutants exited 2 but its outcome files list no missed or timed-out mutant$'
reset_stub; echo 2 > "$STUB/list"; echo 4 > "$STUB/mutants.rc"; lm sh "$LM" "$C" "$BASE" ledger
failed "control: cargo mutants exit 4 (its baseline is red) -> exit 1" 1 '^local-mutants: cargo mutants failed \(rc=4: its baseline, the unmutated tree, is red\); log: .*/mutants\.log$'
reset_stub; echo 2 > "$STUB/list"; touch "$STUB/no-outcomes"; lm sh "$LM" "$C" "$BASE" ledger
failed "control: missing outcome files -> exit 1" 1 '^local-mutants: no outcome files in .*/mutants\.out \(cargo mutants did not finish\)$'
reset_stub; echo 1 > "$STUB/list.rc"; lm sh "$LM" "$C" "$BASE" ledger
failed "control: cargo mutants --list failing -> exit 1" 1 '^local-mutants: cargo mutants --list failed \(rc=1\)'
check_ "control: ... no mutation run followed" '[ "$(grep -c "cargo mutants " "$STUB/cargo.log")" -eq 1 ]'
reset_stub; echo 1 > "$STUB/list"; echo 1 > "$STUB/caught"; mkdir "$C/mutants-run.txt"; lm sh "$LM" "$C" "$BASE" ledger
failed "control: mutants-run.txt cannot be written -> exit 1, nothing printed" 1 "^local-mutants: could not write $C/mutants-run\.txt\$"
# Green runs.
reset_stub; echo 6 > "$STUB/list"; echo 4 > "$STUB/caught"; echo 2 > "$STUB/unviable"; lm sh "$LM" "$C" "$BASE" ledger
printed "green: 6 listed = 4 caught + 2 unviable -> exit 0, one run: line (unviable not caught)" 0 "$(runline 6 0 4 2 0)"
check_ "... files: holds new.rs, changed with zero mutants (not gone.rs, notes.md, other/ or Cargo.toml)" 'grep -q " files: $FILES tested: " "$T/out" && ! grep -q "new\.rs" "$STUB/cargo.log"'
check_ "... cargo and sccache were found in \$HOME/.cargo/bin; every cargo mutants call ran inside the scope with RUSTC_WRAPPER=sccache" '[ "$(grep -c "cargo mutants " "$STUB/cargo.log")" -eq 2 ] && ! grep "cargo mutants " "$STUB/cargo.log" | grep -qv "^scope=capped wrapper=\[sccache\] "'
check_ "... every systemd-run call is --user --scope -p MemoryMax=3G -p MemorySwapMax=0 --" '[ "$(grep -c "" "$STUB/systemd-run.log")" -eq 3 ] && ! grep -qv "^systemd-run --user --scope -p MemoryMax=3G -p MemorySwapMax=0 -- " "$STUB/systemd-run.log"'
check_ "... the run: --in-diff, -p ledger, nextest, --jobs 1 --timeout 60, -o, the replay proptest excluded, no --test" 'grep -Eq "^scope=capped wrapper=\[sccache\] cargo mutants --in-diff [^ ]+/changes\.diff -p ledger --test-tool nextest --jobs 1 --timeout 60 -o [^ ]+ -- -E not test\(=random_sessions_match_model\)\$" "$STUB/cargo.log"'
check_ "... cargo mutants runs its own baseline (no --baseline) and copies the tree (no --in-place)" '! grep -q -e --baseline -e --in-place "$STUB/cargo.log"'
check_ "... --list ran first, with the same selection" 'grep "cargo mutants " "$STUB/cargo.log" | head -n 1 | grep -Eq "^scope=capped wrapper=\[sccache\] cargo mutants --list --in-diff [^ ]+/changes\.diff -p ledger\$"'
check_ "... the diff holds only ledger/src paths" 'grep -q "^diff --git a/ledger/src/lib.rs " "$STUB/diff.seen" && ! grep "^diff --git " "$STUB/diff.seen" | grep -qv "^diff --git a/ledger/src/"'
reset_stub; echo 2 > "$STUB/list"; echo 2 > "$STUB/caught"; lm sh "$LM" "$C" "$BASE" ledger --tests e3_model,e3_fees
printed "--tests e3_model,e3_fees -> exit 0, the run: line unchanged" 0 "$(runline 2 0 2 0 0)"
check_ "... --test e3_model --test e3_fees follow -- in the run, not in --list" 'grep -Eq "^scope=capped wrapper=\[sccache\] cargo mutants --in-diff .* -- -E not test\(=random_sessions_match_model\) --test e3_model --test e3_fees\$" "$STUB/cargo.log" && ! grep "cargo mutants --list" "$STUB/cargo.log" | grep -q -- "--test "'
reset_stub; echo 1 > "$STUB/list"; echo 1 > "$STUB/caught"; lm env HOME="$H2" MUTANTS_NO_SCCACHE=1 sh "$LM" "$C" "$BASE" ledger
printed "MUTANTS_NO_SCCACHE=1 without sccache -> exit 0" 0 "$(runline 1 0 1 0 0)"
check_ "... the opt-out ran cargo mutants with no rustc wrapper" '[ "$(grep -c "cargo mutants " "$STUB/cargo.log")" -eq 2 ] && ! grep "cargo mutants " "$STUB/cargo.log" | grep -qv "^scope=capped wrapper=\[\] "'
reset_stub; echo 1 > "$STUB/list"; echo 1 > "$STUB/caught"; lm env MUTANTS_MEMORY_MAX=512M sh "$LM" "$C" "$BASE" ledger
printed "MUTANTS_MEMORY_MAX=512M -> exit 0" 0 "$(runline 1 0 1 0 0)"
check_ "... every scope had MemoryMax=512M" '[ -s "$STUB/systemd-run.log" ] && ! grep -qv "^systemd-run --user --scope -p MemoryMax=512M -p MemorySwapMax=0 -- " "$STUB/systemd-run.log"'
reset_stub; echo 0 > "$STUB/list"; lm sh "$LM" "$C" "$BASE" ledger
printed "no mutant on the changed lines -> exit 0, tested 0, no mutation run" 0 "$(runline 0 0 0 0 0)"
check_ "... only the --list call ran" '[ "$(grep -c "cargo mutants " "$STUB/cargo.log")" -eq 1 ] && grep -q "cargo mutants --list " "$STUB/cargo.log"'
rm -rf "$T"; [ $R -eq 0 ] && echo "local-mutants.t: all cases behave" || echo "local-mutants.t: FAILURES"; exit $R
