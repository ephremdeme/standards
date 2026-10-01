#!/bin/sh
# Negative control for bin/new-lane.sh's WIP limit (docs/07 §2 7b): a 3rd lane in one repo and a 4th across the
# workspace must be refused FOR THEIR OWN REASON (exit 1 + "wip limit: …"), never 2 (usage) or 126/127.
# Run: sh standards/tests/new-lane-wip.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); R=0
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 4 | sed 's/^/        /'; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# A workspace with two product repos, each carrying a plain copy of standards (templates and bin are what the script needs).
mk_repo(){ git init -q -b main "$1"; cp -r "$S" "$1/standards"; rm -rf "$1/standards/.git"; printf '.worktrees/\n.env\n' > "$1/.gitignore"
  printf 'DATABASE_URL=postgres://placeholder\n' > "$1/.env.example"; git -C "$1" add -A; git -C "$1" commit -qm base; }
mk_repo "$T/a"; mk_repo "$T/b"
NL="standards/bin/new-lane.sh"
lane(){ (cd "$1" && sh "$NL" "$2" main); }
want "repo a: lane 1 accepted" 0 'branch: opus/one' lane "$T/a" opus/one
[ -f "$T/a/.worktrees/opus-one/.env" ] && ok "lane worktree seeded with .env from .env.example" || bad "lane worktree has no .env"
want "repo a: lane 2 accepted" 0 'branch: opus/two' lane "$T/a" opus/two
want "control: repo a lane 3 refused (per-repo limit 2)" 1 'wip limit: 2 lanes already in .*(max 2 per repo)' lane "$T/a" opus/three
[ -d "$T/a/.worktrees/opus-three" ] && bad "refused lane still created a worktree" || ok "refused lane created nothing"
want "repo b: lane 1 accepted (3 across the workspace)" 0 'branch: ds/one' lane "$T/b" ds/one
want "control: repo b lane 2 refused (workspace limit 3)" 1 'wip limit: 3 lanes already across .*(max 3 per workspace)' lane "$T/b" ds/two
git -C "$T/a" worktree remove --force .worktrees/opus-two
want "after removing a lane in repo a, repo b lane 2 accepted" 0 'branch: ds/two' lane "$T/b" ds/two
rm -rf "$T"; [ $R -eq 0 ] && echo "new-lane-wip.t: all cases behave" || echo "new-lane-wip.t: FAILURES"; exit $R
