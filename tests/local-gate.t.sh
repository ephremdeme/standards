#!/bin/sh
# Cases for bin/local-gate (exchange D-109: the local evidence log replaces GitHub-hosted CI). A fixture repository whose
# standards/bin/check and scripts/verify/x.sh are stubs, switched by files in $CTL outside the tree (so the tree stays
# clean), and a stub `free` first on PATH. TMPDIR is the test's own directory, so the build lock taken here is not the
# machine's. A refusal is exit 2 with its own message and no log written; a red run is exit 1 with the whole log, which
# still ends in gate-head, gate-tree and its red gate-verdict. A second fixture carries the game's instrument ids (m1_1,
# m2_1, m2_2); at the end the gate's own red and green logs go through bin/merge-pr --local-log with a stub gh (the
# review's blocker, end to end).
# Run: sh standards/tests/local-gate.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); LG="$S/bin/local-gate"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
unset BUILD_LOCK_TOKEN BUILD_LOCK_WAIT CARGO_TARGET_DIR RUSTC_WRAPPER VERIFY_FAIL_TAIL
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
check_(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
CTL="$T/ctl"; mkdir -p "$CTL" "$T/h/.cargo/bin" "$T/logs" "$T/plain"; export CTL HOME="$T/h"
# The stub free lives only in $HOME/.cargo/bin: the gate's first log line proves it put that directory first on PATH.
printf '#!/bin/sh\necho "Mem: stub free $*"\n' > "$T/h/.cargo/bin/free"; chmod +x "$T/h/.cargo/bin/free"
# The fixture: a stub check (check-red: FAILED; check-rc: exit code) and a stub instrument x.sh (x-red: one failure
# with its [FAIL] line; x-failline: a failed count without [FAIL]; x-zero: 0 ok and exit 0, so only the N >= 1 rule can
# catch it; x-rc: exit code; x-commit: HEAD moves during the run; x-dirt: a tracked file modified; x-artifact: an
# untracked file left behind; x-index: the index corrupted, so git status fails at the end). Both print where and how
# they ran.
P="$T/repo"; git init -q -b main "$P"; mkdir -p "$P/standards/bin" "$P/scripts/verify"
cat > "$P/standards/bin/check" << 'C'
#!/bin/sh
echo "check-stub: cwd=$(pwd -P) lock=${BUILD_LOCK_TOKEN:+held}"
if [ -e "$CTL/check-red" ]; then echo "FAIL  stub step"; echo "check: FAILED"; exit 1; fi
echo "PASS  stub step"; echo "check: OK"; exit "$(cat "$CTL/check-rc" 2>/dev/null || echo 0)"
C
cat > "$P/scripts/verify/x.sh" << 'V'
#!/bin/bash
echo "x-stub: cwd=$(pwd -P) lock=${BUILD_LOCK_TOKEN:+held} args=$# VERIFY_FAIL_TAIL=${VERIFY_FAIL_TAIL-unset}"
if [ -e "$CTL/x-commit" ]; then git commit -q --allow-empty -m moved; fi
if [ -e "$CTL/x-dirt" ]; then echo dirt >> README; fi
if [ -e "$CTL/x-artifact" ]; then echo out > artifact.txt; fi
if [ -e "$CTL/x-index" ]; then printf 'not an index' > .git/index; fi
if [ -e "$CTL/x-red" ]; then echo "[ok]   a"; echo "[FAIL] b (rc=1, wanted 0, /x/)"; echo "verify:x — 1 ok, 1 failed"; exit 1; fi
if [ -e "$CTL/x-failline" ]; then echo "verify:x — 3 ok, 1 failed"; exit 0; fi
if [ -e "$CTL/x-zero" ]; then echo "verify:x — 0 ok, 0 failed"; exit 0; fi
echo "[ok]   a"; echo "[ok]   b"; echo "[ok]   c"; echo "verify:x — 3 ok, 0 failed"; exit "$(cat "$CTL/x-rc" 2>/dev/null || echo 0)"
V
echo readme > "$P/README"; git -C "$P" add -A; git -C "$P" commit -qm fixture; HD=$(git -C "$P" rev-parse HEAD)
PP=$(cd "$P" && pwd -P)
echo 'the lane contract' > "$P/TASK.md"   # an untracked TASK.md at the top: the one dirt the gate allows
P2="$T/nocheck"; git init -q -b main "$P2"; mkdir -p "$P2/scripts/verify"; cp "$P/scripts/verify/x.sh" "$P2/scripts/verify/"
git -C "$P2" add -A; git -C "$P2" commit -qm nocheck
P3="$T/badindex"; git init -q -b main "$P3"; echo a > "$P3/a"; git -C "$P3" add -A; git -C "$P3" commit -qm badindex
printf 'not an index' > "$P3/.git/index"   # HEAD reads fine, git status fails
# The game's ids: instruments m1_1, m2_1 and m2_2, each printing a green verify line for its own id.
PG="$T/game"; git init -q -b main "$PG"; mkdir -p "$PG/standards/bin" "$PG/scripts/verify"; cp "$P/standards/bin/check" "$PG/standards/bin/"
cat > "$PG/scripts/verify/m2_2.sh" << 'V'
#!/bin/bash
id=$(basename "$0" .sh); echo "[ok]   a"; echo "verify:$id — 3 ok, 0 failed"
V
cp "$PG/scripts/verify/m2_2.sh" "$PG/scripts/verify/m2_1.sh"; cp "$PG/scripts/verify/m2_2.sh" "$PG/scripts/verify/m1_1.sh"
git -C "$PG" add -A; git -C "$PG" commit -qm game; HG=$(git -C "$PG" rev-parse HEAD)
n=0; nl(){ n=$((n + 1)); L="$T/logs/$n.log"; }   # a fresh log path per run
reset(){ rm -f "$CTL"/*; }
tail3(){ printf 'gate-head: %s\ngate-tree: clean\ngate-verdict: %s' "$HD" "$1"; }   # tail3 <verdict>: how a log with an unmoved HEAD and a clean tree ends
# Refusals: exit 2, their own message, no log written.
nl; want "control: two arguments -> usage, exit 2" 2 '^local-gate: usage: local-gate <repo-dir> <mN> <log>$' sh "$LG" "$P" x
nl; echo dirt >> "$P/README"
want "control: a modified tracked file -> refused naming it" 2 "^local-gate: refused — the tree of $P is not clean \(first: README\)\$" sh "$LG" "$P" x "$L"
check_ "control: ... no log written" '[ ! -e "$L" ]'
git -C "$P" checkout -q -- README
nl; echo j > "$P/junk.txt"
want "control: an untracked file beside TASK.md -> refused naming it" 2 "^local-gate: refused — the tree of $P is not clean \(first: junk\.txt\)\$" sh "$LG" "$P" x "$L"
rm -f "$P/junk.txt"
nl; mkdir -p "$P/sub"; echo t > "$P/sub/TASK.md"
want "control: an untracked TASK.md below the top -> refused naming it" 2 "^local-gate: refused — the tree of $P is not clean \(first: sub/TASK\.md\)\$" sh "$LG" "$P" x "$L"
rm -rf "$P/sub"
nl; git -C "$P" add TASK.md
want "control: a staged (not untracked) TASK.md -> refused naming it" 2 "^local-gate: refused — the tree of $P is not clean \(first: TASK\.md\)\$" sh "$LG" "$P" x "$L"
git -C "$P" reset -q -- TASK.md
nl; want "control: a subdirectory, not the top level -> refused" 2 "^local-gate: refused — $P/scripts is not the top level of a git checkout with a commit\$" sh "$LG" "$P/scripts" x "$L"
nl; want "control: git status failing (a corrupt index) -> refused" 2 "^local-gate: refused — git status failed in $P3\$" sh "$LG" "$P3" x "$L"
nl; want "control: a directory outside git -> refused" 2 "^local-gate: refused — $T/plain is not the top level of a git checkout with a commit\$" sh "$LG" "$T/plain" x "$L"
ID='is not a milestone id \(a lowercase letter, then lowercase letters, digits or _\)'
nl; want "control: a milestone id with a path in it -> refused" 2 "^local-gate: refused — '\.\./x' $ID\$" sh "$LG" "$P" ../x "$L"
nl; want "control: an upper-case milestone id -> refused" 2 "^local-gate: refused — 'X1' $ID\$" sh "$LG" "$P" X1 "$L"
nl; want "control: a milestone id starting with a digit -> refused" 2 "^local-gate: refused — '2x' $ID\$" sh "$LG" "$P" 2x "$L"
nl; want "control: a milestone id starting with _ -> refused" 2 "^local-gate: refused — '_x' $ID\$" sh "$LG" "$P" _x "$L"
nl; want "control: no instrument for the milestone -> refused" 2 "^local-gate: refused — $P has no scripts/verify/y\.sh\$" sh "$LG" "$P" y "$L"
nl; want "control: no standards/bin/check -> refused" 2 "^local-gate: refused — $P2 has no standards/bin/check\$" sh "$LG" "$P2" x "$L"
nl; echo old > "$L"; want "control: an existing log -> refused" 2 "^local-gate: refused — $L exists; the gate writes a fresh log only\$" sh "$LG" "$P" x "$L"
check_ "control: ... the existing log is untouched" '[ "$(cat "$L")" = old ]'
nl; ln -s "$T/nowhere" "$L"; want "control: a dangling symlink as the log -> refused" 2 "^local-gate: refused — $L exists; the gate writes a fresh log only\$" sh "$LG" "$P" x "$L"
check_ "control: ... nothing was created through the link" '[ ! -e "$T/nowhere" ]'
nl; want "control: a log in a missing directory -> refused" 2 "^local-gate: refused — cannot create the log $T/missing/1\.log\$" sh "$LG" "$P" x "$T/missing/1.log"
nl; want "control: VERIFY_FAIL_TAIL=abc -> refused" 2 "^local-gate: refused — VERIFY_FAIL_TAIL must be a positive integer, got 'abc'\$" env VERIFY_FAIL_TAIL=abc sh "$LG" "$P" x "$L"
check_ "control: ... no log written" '[ ! -e "$L" ]'
# A green run.
reset; nl; want "green: check: OK and verify:x — 3 ok, 0 failed -> exit 0" 0 "^local-gate: OK x $HD $L\$" sh "$LG" "$P" x "$L"; LGREEN=$L
check_ "... the log starts with free -m, found first in \$HOME/.cargo/bin" '[ "$(head -n 1 "$L")" = "Mem: stub free -m" ]'
check_ "... the log carries check: OK and the verify line" 'grep -qx "check: OK" "$L" && grep -qx "verify:x — 3 ok, 0 failed" "$L"'
check_ "... it ends with gate-head: <HEAD>, gate-tree: clean and gate-verdict: green x, its only verdict line" '[ "$(tail -n 3 "$L")" = "$(tail3 "green x")" ] && [ "$(grep -c "^gate-verdict:" "$L")" -eq 1 ]'
check_ "... check ran first, from the repo, under the build lock" 'grep -qx "check-stub: cwd=$PP lock=held" "$L" && [ "$(grep -n "^check-stub" "$L" | cut -d: -f1)" -lt "$(grep -n "^x-stub" "$L" | cut -d: -f1)" ]'
check_ "... the instrument ran the full chain (no arguments) from the repo, with no lock from the gate and VERIFY_FAIL_TAIL=400" 'grep -qx "x-stub: cwd=$PP lock= args=0 VERIFY_FAIL_TAIL=400" "$L"'
check_ "... the build lock was released" '[ ! -e "$T/build.lock.d" ]'
reset; nl; want "a caller's VERIFY_FAIL_TAIL=25 -> exit 0" 0 "^local-gate: OK x $HD $L\$" env VERIFY_FAIL_TAIL=25 sh "$LG" "$P" x "$L"
check_ "... VERIFY_FAIL_TAIL=25 reached the instrument" 'grep -q "^x-stub: .* VERIFY_FAIL_TAIL=25\$" "$L"'
# Red runs: exit 1, the reason named, the whole log written and ending in gate-head, gate-tree and the red verdict.
reset; touch "$CTL/check-red"; nl
want "red: check: FAILED -> exit 1" 1 "^local-gate: RED x $HD — check printed check: FAILED \(log $L\)\$" sh "$LG" "$P" x "$L"
check_ "... the red log has check: FAILED, the instrument's output, then gate-head, gate-tree and the red verdict last" 'grep -qx "check: FAILED" "$L" && grep -qx "verify:x — 3 ok, 0 failed" "$L" && [ "$(tail -n 3 "$L")" = "$(tail3 "red — check printed check: FAILED")" ]'
reset; echo 1 > "$CTL/check-rc"; nl
want "red: check prints check: OK but exits 1 -> exit 1" 1 "^local-gate: RED x $HD — check exited 1 \(log $L\)\$" sh "$LG" "$P" x "$L"; LCRC=$L
check_ "... the log ends with gate-verdict: red — check exited 1, though it has check: OK and a green verify line" 'grep -qx "check: OK" "$L" && grep -qx "verify:x — 3 ok, 0 failed" "$L" && [ "$(tail -n 3 "$L")" = "$(tail3 "red — check exited 1")" ]'
reset; touch "$CTL/x-red"; nl
want "red: the instrument reports verify:x — 1 ok, 1 failed -> exit 1" 1 "^local-gate: RED x $HD — the log has 1 \[FAIL\] line\(s\) \(log $L\)\$" sh "$LG" "$P" x "$L"
check_ "... the red log has the failure, then gate-head, gate-tree and the red verdict" 'grep -qx "verify:x — 1 ok, 1 failed" "$L" && [ "$(tail -n 3 "$L")" = "$(tail3 "red — the log has 1 [FAIL] line(s)")" ]'
reset; touch "$CTL/x-failline"; nl
want "red: a verify line with 1 failed and no [FAIL] line -> exit 1" 1 "^local-gate: RED x $HD — a verify line reports failures: verify:x — 3 ok, 1 failed \(log $L\)\$" sh "$LG" "$P" x "$L"
reset; touch "$CTL/x-zero"; nl
want "red: verify:x — 0 ok, 0 failed with exit 0 -> exit 1" 1 "^local-gate: RED x $HD — no verify:x — N ok, 0 failed line with N >= 1 \(log $L\)\$" sh "$LG" "$P" x "$L"
reset; echo 1 > "$CTL/x-rc"; nl
want "red: the instrument prints a green line but exits 1 -> exit 1" 1 "^local-gate: RED x $HD — scripts/verify/x\.sh exited 1 \(log $L\)\$" sh "$LG" "$P" x "$L"; LIRC=$L
check_ "... the log ends with gate-verdict: red — scripts/verify/x.sh exited 1, though it has verify:x — 3 ok, 0 failed" 'grep -qx "verify:x — 3 ok, 0 failed" "$L" && [ "$(tail -n 3 "$L")" = "$(tail3 "red — scripts/verify/x.sh exited 1")" ]'
# The tree at the end (review major): tracked files re-read, untracked artifacts allowed, a failing git status is red.
reset; touch "$CTL/x-dirt"; nl
want "red: the instrument modifies a tracked file (echo dirt >> README) -> exit 1" 1 "^local-gate: RED x $HD — the tree is not clean at the end \(first: README\) \(log $L\)\$" sh "$LG" "$P" x "$L"
check_ "... the log ends with gate-tree: dirty (README) and the red verdict, after the instrument's green line" 'grep -qx "verify:x — 3 ok, 0 failed" "$L" && [ "$(tail -n 2 "$L")" = "$(printf "gate-tree: dirty (README)\ngate-verdict: red — the tree is not clean at the end (first: README)")" ] && ! grep -q "^gate-tree: clean" "$L"'
git -C "$P" checkout -q -- README
reset; touch "$CTL/x-artifact"; nl
want "green: an untracked artifact left by the instrument is not dirt (tracked files only) -> exit 0" 0 "^local-gate: OK x $HD $L\$" sh "$LG" "$P" x "$L"
check_ "... gate-tree: clean and gate-verdict: green x" '[ "$(tail -n 3 "$L")" = "$(tail3 "green x")" ]'
rm -f "$P/artifact.txt"
reset; touch "$CTL/x-index"; cp "$P/.git/index" "$T/index.bak"; nl
want "red: git status fails at the end (the instrument corrupts the index) -> exit 1" 1 "^local-gate: RED x $HD — git status failed at the end \(log $L\)\$" sh "$LG" "$P" x "$L"
check_ "... the log has gate-tree: dirty (git status failed), never clean" 'grep -qx "gate-tree: dirty (git status failed)" "$L" && ! grep -q "^gate-tree: clean" "$L" && [ "$(tail -n 1 "$L")" = "gate-verdict: red — git status failed at the end" ]'
cp "$T/index.bak" "$P/.git/index"
# The game's ids (review major): m2_2 is a milestone id, its verify line and verdict carry it.
reset; nl; want "green: the game's id m2_2 (verify:m2_2 — 3 ok, 0 failed) -> exit 0" 0 "^local-gate: OK m2_2 $HG $L\$" sh "$LG" "$PG" m2_2 "$L"
check_ "... the log ends with gate-verdict: green m2_2" '[ "$(tail -n 1 "$L")" = "gate-verdict: green m2_2" ]'
reset; touch "$CTL/x-commit"; nl
want "red: HEAD moved during the run -> exit 1" 1 "^local-gate: RED x $HD — HEAD moved from $HD to [0-9a-f]{40} during the run \(log $L\)\$" sh "$LG" "$P" x "$L"
check_ "... the log names both heads, so no single SHA can match it" '[ "$(grep -c "^gate-head: " "$L")" -eq 2 ] && grep -qx "gate-head: $HD" "$L" && grep -qx "gate-head: $(git -C "$P" rev-parse HEAD)" "$L"'
check_ "... gate-tree: dirty (HEAD moved) and the red verdict" 'grep -qx "gate-tree: dirty (HEAD moved)" "$L" && [ "$(tail -n 1 "$L")" = "gate-verdict: red — HEAD moved from $HD to $(git -C "$P" rev-parse HEAD) during the run" ]'
# End to end (the review's blocker): the gate's own red logs fed to merge-pr --local-log are refused, its green log
# merges. A stub gh serves an open lane PR #12 on exchange whose head is the fixture's first HEAD and its one file, and
# records the merge call; any other call fails. No network: a bogus GH_TOKEN, an empty GH_CONFIG_DIR, the stub first.
GB="$T/ghbin"; mkdir -p "$GB" "$T/ghconf"
cat > "$GB/gh" << 'GH'
#!/bin/sh
case "$*" in
  "pr view 12 --repo ephremdeme/exchange --json "*)
    printf '{"state":"OPEN","isDraft":false,"headRefOid":"%s","baseRefName":"main","headRefName":"opus/x","isCrossRepository":false,"changedFiles":1,"labels":[]}\n' "$GHSTUB_HEAD";;
  "api --paginate repos/ephremdeme/exchange/pulls/12/files?per_page=100") echo '[{"filename":"code.rs","status":"modified"}]';;
  "pr merge 12 --repo ephremdeme/exchange --merge --match-head-commit "*) printf '%s\n' "$*" > "$GHSTUB_MERGE"; echo merged;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 64;;
esac
GH
chmod +x "$GB/gh"
[ "$(env PATH="$GB:$PATH" sh -c 'command -v gh')" = "$GB/gh" ] || { echo "FAIL    the stub gh is not first on PATH; aborting"; rm -rf "$T"; exit 1; }
mp(){ rm -f "$T/merge"; env PATH="$GB:$PATH" GH_TOKEN=stub-not-a-token GH_CONFIG_DIR="$T/ghconf" GHSTUB_HEAD="$HD" GHSTUB_MERGE="$T/merge" \
  sh "$S/bin/merge-pr" ephremdeme/exchange 12 "$HD" --local-log "$1"; }
want "end to end: the gate's red log 'check prints check: OK but exits 1' -> merge-pr --local-log refuses it" 2 "^merge-pr: refused — local log $LCRC has a red gate verdict \(gate-verdict: red — check exited 1\)\$" mp "$LCRC"
check_ "... no merge call" '[ ! -e "$T/merge" ]'
want "end to end: the gate's red log 'the instrument prints a green line but exits 1' -> merge-pr --local-log refuses it" 2 "^merge-pr: refused — local log $LIRC has a red gate verdict \(gate-verdict: red — scripts/verify/x\.sh exited 1\)\$" mp "$LIRC"
check_ "... no merge call" '[ ! -e "$T/merge" ]'
want "end to end: the gate's green log -> merge-pr --local-log merges" 0 "^merge-pr: OK ephremdeme/exchange#12 $HD merged\$" mp "$LGREEN"
check_ "... exactly the guarded merge call" '[ "$(cat "$T/merge" 2>/dev/null)" = "pr merge 12 --repo ephremdeme/exchange --merge --match-head-commit $HD" ]'
reset; rm -rf "$T"; [ $R -eq 0 ] && echo "local-gate.t: all cases behave" || echo "local-gate.t: FAILURES"; exit $R
