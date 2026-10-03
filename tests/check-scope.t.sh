#!/bin/sh
# Negative control for bin/check-scope: every refusal must fail FOR ITS OWN REASON (exit 1 + "scope violation: <path>"),
# never 2 (usage) or 126/127. Ownership is the TASK's ```owned block in §3, read by bin/owned-paths (C7); bullets are
# never parsed (NOTES-19 defect 1). Run: sh standards/tests/check-scope.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); C="$S/bin/check-scope"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 4 | sed 's/^/        /'; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main "$T/wt"; W="$T/wt"
mkdir -p "$W/docs" "$W/web/src/components" "$W/api/src/users"
printf 'Branch: opus/x\nBase: 0\nRisk: LOW\n\n## 2. What this is\nx\n\n## 3. Files you own (touch nothing else)\n```owned\ndocs/\nweb/src/components/*\napi/src/owned.rs\n```\n\n## 4. Hard rules\n- none\n' > "$W/TASK.md"
echo a > "$W/docs/a.md"; echo b > "$W/api/src/owned.rs"; echo c > "$W/web/src/components/Btn.tsx"; echo d > "$W/api/src/other.rs"
echo n > "$W/api/src/users/nickname.rs"; echo m > "$W/api/src/users/mod.rs"; echo o > "$W/api/src/users/other.rs"
git -C "$W" add -A; git -C "$W" commit -qm base; B=$(git -C "$W" rev-parse HEAD)
c(){ git -C "$W" add -A; git -C "$W" commit -qm "$1"; }
echo a2 > "$W/docs/a.md"; echo c2 > "$W/web/src/components/Btn.tsx"; echo b2 > "$W/api/src/owned.rs"; c in-scope
want "in-scope edits pass" 0 'check-scope: OK \(3 changed' sh "$C" "$W" "$B"
echo "## Revision" >> "$W/TASK.md"; c task-edit
want "editing TASK.md itself is always allowed" 0 'check-scope: OK' sh "$C" "$W" "$B"
# Defect 1 (NOTES-19): a bullet with nested parentheses and several files after one directory prefix used to break the
# sed parser. Bullets are no longer read; the block beside them is the ownership.
cp "$W/TASK.md" "$T/TASK.orig"
printf 'Branch: opus/x\nBase: 0\nRisk: LOW\n\n## 3. Files you own (touch nothing else)\n- api/src/users/ (nickname.rs (PATCH), mod.rs (export))\n- docs/, `web/src/components/*` (add the button only), api/src/owned.rs\n```owned\ndocs/\nweb/src/components/*\napi/src/owned.rs\napi/src/users/nickname.rs\napi/src/users/mod.rs\n```\n\n## 4. Hard rules\n- none\n' > "$W/TASK.md"
echo n2 > "$W/api/src/users/nickname.rs"; echo m2 > "$W/api/src/users/mod.rs"; c defect1-in
want "defect 1: bullets with nested parentheses beside the block -> the block's files are in scope" 0 'check-scope: OK \(5 changed' sh "$C" "$W" "$B"
echo o2 > "$W/api/src/users/other.rs"; c defect1-out
want "control: defect 1: a third file under the bullet's directory prefix is not owned -> exit 1" 1 'scope violation: api/src/users/other.rs' sh "$C" "$W" "$B"
git -C "$W" reset -q --hard HEAD~2; cp "$T/TASK.orig" "$W/TASK.md"
# Regression: the base branch moved on after the lane branched; those commits are not the lane's changes.
git -C "$W" branch -q lane HEAD; git -C "$W" checkout -q -b basebranch "$B"; echo n > "$W/api/src/other.rs"; c base-moved
want "base branch advanced after branching: its files are not scope violations" 0 'check-scope: OK \(3 changed' sh "$C" "$W" basebranch lane
git -C "$W" checkout -q main; git -C "$W" branch -q -D basebranch lane
echo d2 > "$W/api/src/other.rs"; c out-of-scope
want "control: modified file outside §3 -> exit 1 naming it" 1 'scope violation: api/src/other.rs' sh "$C" "$W" "$B"
git -C "$W" reset -q --hard HEAD~1
mkdir -p "$W/api/src/payouts"; echo n > "$W/api/src/payouts/mod.rs"; c new-file
want "control: brand-new file outside §3 -> exit 1" 1 'scope violation: api/src/payouts/mod.rs' sh "$C" "$W" "$B"
git -C "$W" reset -q --hard HEAD~1
git -C "$W" rm -q api/src/other.rs; c delete
want "control: deleting an unowned file -> exit 1" 1 'scope violation: api/src/other.rs' sh "$C" "$W" "$B"
git -C "$W" reset -q --hard HEAD~1
git -C "$W" mv web/src/components/Btn.tsx api/src/Btn.tsx; c rename
want "control: rename from owned into unowned -> exit 1 (renamed-to path)" 1 'scope violation: api/src/Btn.tsx' sh "$C" "$W" "$B"
git -C "$W" reset -q --hard HEAD~1
want "explicit head argument works" 0 'check-scope: OK' sh "$C" "$W" "$B" HEAD
# Regression: run from a directory where the owned patterns match real files (docs/*, web/src/components/*)
want "in-scope edits pass when run from inside the worktree (patterns are not glob-expanded)" 0 'check-scope: OK \(3 changed' sh -c "cd \"$W\" && sh \"$C\" \"$W\" \"$B\" HEAD~1"
rm "$W/TASK.md"
want "usage: missing TASK.md -> exit 2, not 1" 2 'no TASK.md' sh "$C" "$W" "$B"
printf 'Branch: x\n## 3. Files you own\n- docs/\n- api/src/owned.rs\n## 4.\n' > "$W/TASK.md"
want "control: a bullet-only §3 (no owned-paths block) -> exit 2" 2 'owned-paths: TASK §3 has no owned-paths block' sh "$C" "$W" "$B"
printf 'Branch: x\n## 3. Files you own\n```owned\n<paths>\n```\n## 4.\n' > "$W/TASK.md"
want "control: §3's block still holds the <paths> placeholder -> exit 2" 2 'owned-paths: invalid owned path on block line 1: <paths>' sh "$C" "$W" "$B"
rm -rf "$T"; [ $R -eq 0 ] && echo "check-scope.t: all cases behave" || echo "check-scope.t: FAILURES"; exit $R
