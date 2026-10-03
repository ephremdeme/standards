#!/bin/sh
# Cases for bin/prune-lane (C5 "worktrees and their artefacts pruned after merge"): a merged, clean lane worktree goes
# with its branch and the review checkouts review-checkout made for it; anything else is refused for its own reason.
# Run: sh standards/tests/prune-lane.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); PL="$S/bin/prune-lane"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
check_(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
in_dir(){ (cd "$1" && shift && "$@"); }
P="$T/p"; git init -q -b main "$P"; printf '.worktrees/\n/target/\n' > "$P/.gitignore"; echo x > "$P/README.md"
git -C "$P" add -A; git -C "$P" commit -qm base; P=$(cd "$P" && pwd -P)
lane(){ # lane <slug> <branch> [merge]: a lane worktree with one commit, merged into main when $3 = merge
  git -C "$P" worktree add -q "$P/.worktrees/$1" -b "$2" main; echo "$1" > "$P/.worktrees/$1/$1.txt"
  git -C "$P/.worktrees/$1" add -A; git -C "$P/.worktrees/$1" commit -qm "$1"
  [ "${3:-}" = merge ] && git -C "$P" merge -q --no-ff -m "merge $1" "$2"; :; }
lane opus-one opus/one merge; lane opus-two opus/two; lane opus-three opus/three merge
W1="$P/.worktrees/opus-one"; echo t > "$W1/TASK.md"; echo l > "$W1/.lane-run.log"; mkdir -p "$W1/target"; echo b > "$W1/target/x"
mkrev(){ mkdir "$T/$1"; echo x > "$T/$1/f"; [ "${2:-}" = nohead ] || { echo sha > "$T/$1.head"; echo m > "$T/$1.review.sha256"; }; }
mkrev review-opus-one.Ab12Cd; mkrev review-opus-one.Zz99Yy nohead; mkrev review-other.Xy12Zw; mkrev review-opus-one.x.Qq11Ww
want "control: an unmerged lane -> exit 1" 1 "^prune-lane: refused — opus/two is not merged into main\$" in_dir "$P" sh "$PL" "$P/.worktrees/opus-two" main
check_ "control: ... the unmerged lane is untouched" '[ -d "$P/.worktrees/opus-two" ] && git -C "$P" rev-parse -q --verify refs/heads/opus/two >/dev/null'
echo dirty >> "$P/.worktrees/opus-three/opus-three.txt"
want "control: a merged lane with a dirty tracked file -> exit 1" 1 "^prune-lane: refused — uncommitted changes in $P/.worktrees/opus-three: opus-three\.txt\$" in_dir "$P" sh "$PL" "$P/.worktrees/opus-three" main
check_ "control: ... the dirty lane is untouched" '[ -f "$P/.worktrees/opus-three/opus-three.txt" ]'
want "control: the primary checkout -> exit 2" 2 "^prune-lane: refused — $P is not a lane worktree \($P/\.worktrees/<slug>\)\$" in_dir "$P" sh "$PL" "$P" main
mkdir "$T/plain"
want "control: a plain directory -> exit 2" 2 "is not a lane worktree" in_dir "$P" sh "$PL" "$T/plain" main
O="$T/other"; git init -q -b main "$O"; git -C "$O" commit -q --allow-empty -m o; git -C "$O" worktree add -q "$O/.worktrees/opus-x" -b opus/x main
want "control: another repo's lane, run from this primary checkout -> exit 2" 2 "is not a lane worktree \($P/\.worktrees/<slug>\)" in_dir "$P" sh "$PL" "$O/.worktrees/opus-x" main
want "control: one argument -> usage, exit 2" 2 '^prune-lane: usage: prune-lane <worktree> <merged-into-ref>$' in_dir "$P" sh "$PL" "$W1"
want "a merged lane (untracked TASK.md and .lane-run.log, an ignored target/) is removed" 0 "^prune-lane: removed $W1 \(branch opus/one, merged into main\); review checkouts removed: 1; freed [0-9]+ MB\$" in_dir "$P" sh "$PL" "$W1" main
check_ "... its worktree is gone" '[ ! -e "$W1" ] && ! git -C "$P" worktree list | grep -q opus-one'
check_ "... its branch is gone" '! git -C "$P" rev-parse -q --verify refs/heads/opus/one >/dev/null'
check_ "... its review checkout and both siblings are gone" '[ ! -e "$T/review-opus-one.Ab12Cd" ] && [ ! -e "$T/review-opus-one.Ab12Cd.head" ] && [ ! -e "$T/review-opus-one.Ab12Cd.review.sha256" ]'
check_ "... a review-opus-one.* directory without a .head sibling is kept" '[ -f "$T/review-opus-one.Zz99Yy/f" ]'
check_ "... another lane's review checkout (review-other.*, review-opus-one.x.*) is kept" '[ -f "$T/review-other.Xy12Zw/f" ] && [ -f "$T/review-other.Xy12Zw.head" ] && [ -f "$T/review-opus-one.x.Qq11Ww/f" ]'
check_ "... the second lane is untouched" '[ -d "$P/.worktrees/opus-two" ]'
rm -rf "$T"; [ $R -eq 0 ] && echo "prune-lane.t: all cases behave" || echo "prune-lane.t: FAILURES"; exit $R
