#!/bin/sh
# Cases for bin/lane-verify (E4 retrospective A.1): a lane's acceptance in one read-only call. A fixture primary repo
# with a lane worktree on opus/fix carrying an untracked, task-lint-clean TASK.md (the real bin/task-lint, check-scope
# and classify-risk are used: lane-verify resolves its siblings), a lane commit that changes a.txt and adds an
# executable tool.sh (so classify-risk says HIGH), and a stub instrument scripts/verify/e9.sh, switched by files in
# $CTL outside the tree. The all-OK case (with risk HIGH, which never flips the verdict), then one control per step,
# each FAIL for its own detail, and the refusals. task-lint needs >= 15 GB free on the fixture's filesystem (TMPDIR is
# under /tmp, on /): when task-lint reports its disk rule, a case that does not behave is marked BLOCKED, not FAIL.
# Run: sh tests/lane-verify.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); LV="$S/bin/lane-verify"; T=$(mktemp -d); R=0; NB=0
T=$(cd "$T" && pwd -P); TMPDIR=$T; export TMPDIR
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <regex2> <cmd...>: both regexes must match a line of the output
  label=$1; rc_want=$2; re=$3; re2=$4; shift 4; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re" && printf '%s' "$out" | grep -Eq -- "$re2"; then ok "$label"
  elif printf '%s\n' "$out" | grep -q '^task-lint: FAIL disk'; then
    NB=$((NB + 1)); echo "BLOCKED $label (task-lint's disk rule: under 15 GB free for the fixture, not lane-verify's reason)"
  else bad "$label (rc=$rc want $rc_want, /$re/ and /$re2/)"; printf '%s\n' "$out" | tail -n 10 | sed 's/^/        /'; fi; }
check_(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
CTL="$T/ctl"; mkdir -p "$CTL"; export CTL
P="$T/primary"; git init -q -b main "$P"; mkdir -p "$P/scripts/verify"
printf '%s\n' '#!/bin/bash' \
  '[ "$#" -eq 2 ] && [ "$1" = --section ] && [ "$2" = x ] || { echo "e9-stub: wanted --section x, got: $*"; exit 3; }' \
  'echo "e9-stub noise: cwd=$(pwd -P)"' \
  'if [ -e "$CTL/e9-red" ]; then echo "[ok]   a"; echo "[FAIL] b (rc=1)"; echo "verify:e9 — 1 ok, 1 failed"; exit 1; fi' \
  'echo "[ok]   a"; echo "[ok]   b"; echo "verify:e9 — 2 ok, 0 failed"' > "$P/scripts/verify/e9.sh"
echo a > "$P/a.txt"; git -C "$P" add -A; git -C "$P" commit -qm base; B=$(git -C "$P" rev-parse HEAD)
W="$T/lane"; git -C "$P" worktree add -q -b opus/fix "$W" main
echo b >> "$W/a.txt"; printf '#!/bin/sh\necho tool\n' > "$W/tool.sh"; chmod +x "$W/tool.sh"
git -C "$W" add -A; git -C "$W" commit -qm lane
# task <tags>: the lane's TASK.md (untracked in the worktree).
task(){ printf 'Branch: opus/fix\nBase: %s\nRisk: HIGH\n\n## 1. Read first\n- a.txt\n## 2. What this is\nComplexity: low\nTags: %s\n## 3. Files you own\n```owned\na.txt\ntool.sh\n```\n## 4. Hard rules\n- none\n## 5. Verify\n- sh tool.sh\n## 6. Commit subject\nfix: a\n## 7. Binding facts\n- none\n' "$B" "$1" > "$W/TASK.md"; }
task none

want "all OK with --section e9 x -> exit 0, OK (5 steps), together with risk HIGH" 0 '^lane-verify: OK \(5 steps\)$' '^lane-verify: risk HIGH$' sh "$LV" "$W" "$B" --section e9 x
check_ "the steps come in order (tree branch task-lint check-scope risk section) and the instrument's verify line is shown, not its noise" \
  '[ "$(printf "%s\n" "$out" | grep "^lane-verify: " | cut -d" " -f2 | tr "\n" " ")" = "tree branch task-lint check-scope risk section OK " ] && printf "%s\n" "$out" | grep -qx "verify:e9 — 2 ok, 0 failed" && ! printf "%s\n" "$out" | grep -q "noise\|\[ok\]"'
want "all OK without --section -> OK (4 steps)" 0 '^lane-verify: OK \(4 steps\)$' '^lane-verify: risk (LOW|HIGH)$' sh "$LV" "$W" "$B"
check_ "lane-verify wrote nothing in the worktree" '[ "$(git -C "$W" status --porcelain --untracked-files=all)" = "?? TASK.md" ]'
# tree
echo s > "$W/stray"
want "control tree: an untracked file other than TASK.md -> FAIL tree naming it" 1 '^lane-verify: tree FAIL — not clean: stray$' '^lane-verify: FAILED' sh "$LV" "$W" "$B"
rm -f "$W/stray"
# branch
git -C "$W" checkout -q --detach
want "control branch: a detached HEAD -> FAIL branch" 1 '^lane-verify: branch FAIL — detached HEAD \(no current branch\)$' '^lane-verify: risk ' sh "$LV" "$W" "$B"
git -C "$W" checkout -q opus/fix
# task-lint
task bogus
want "control task-lint: Tags: bogus -> FAIL task-lint with its FAIL line re-printed" 1 '^lane-verify: task-lint FAIL — exit 1' "^task-lint: FAIL tags: 'bogus' is not one of" sh "$LV" "$W" "$B"
check_ "control task-lint: only task-lint fails (1 of 4)" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "lane-verify: FAILED (1 of 4 steps)" || printf "%s\n" "$out" | grep -q "^task-lint: FAIL disk"'
task none
# check-scope
echo out > "$W/b.txt"; git -C "$W" add b.txt; git -C "$W" commit -qm outside
want "control check-scope: a change outside §3 -> FAIL check-scope with its violation re-printed" 1 '^lane-verify: check-scope FAIL — exit 1' '^scope violation: b.txt$' sh "$LV" "$W" "$B"
git -C "$W" reset -q --hard HEAD~1
# section
touch "$CTL/e9-red"
want "control section: the instrument prints 1 ok, 1 failed and exits 1 -> FAIL section" 1 '^lane-verify: section FAIL — scripts/verify/e9.sh --section x exited 1$' '^\[FAIL\] b \(rc=1\)$' sh "$LV" "$W" "$B" --section e9 x
check_ "control section: only the section fails (1 of 5)" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "lane-verify: FAILED (1 of 5 steps)" || printf "%s\n" "$out" | grep -q "^task-lint: FAIL disk"'
rm -f "$CTL/e9-red"
# refusals
want "refusal: a --section name with a space -> exit 2" 2 "^lane-verify: refused — <section-name> 'a b' does not match" . sh "$LV" "$W" "$B" --section e9 'a b'
want "refusal: an instrument id E9 -> exit 2" 2 "^lane-verify: refused — <instrument-id> 'E9' does not match" . sh "$LV" "$W" "$B" --section E9 x
want "refusal: a missing instrument -> exit 2" 2 '^lane-verify: refused — scripts/verify/e7.sh is missing' . sh "$LV" "$W" "$B" --section e7 x
want "refusal: a relative worktree -> exit 2" 2 "^lane-verify: refused — <worktree> 'lane' is not an absolute path\$" . sh "$LV" lane "$B"
want "refusal: a base that is not a commit -> exit 2" 2 "^lane-verify: refused — <base> 'nope' is not a commit" . sh "$LV" "$W" nope
rm -f "$W/TASK.md"
want "refusal: no TASK.md -> exit 2" 2 '^lane-verify: refused — no readable TASK.md in ' . sh "$LV" "$W" "$B"
want "refusal: usage -> exit 2" 2 '^lane-verify: refused — usage' . sh "$LV" "$W"
rm -rf "$T"
[ $NB -eq 0 ] || echo "lane-verify.t: $NB case(s) BLOCKED by task-lint's disk rule"
[ $R -eq 0 ] && echo "lane-verify.t: all cases behave" || echo "lane-verify.t: FAILURES"
exit $R
