#!/bin/sh
# Usage: standards/bin/new-lane.sh <branch> [base]   (run from the primary checkout; coordinator only)
set -eu
branch=${1:?branch like opus/lock-timing}; base=${2:-HEAD}
slug=$(printf '%s' "$branch" | tr '/' '-')
top=$(git rev-parse --show-toplevel); wt="$top/.worktrees/$slug"
# WIP limit (docs/07 §2 7b): at most 2 lanes in this repo, at most 3 across the workspace (every sibling
# repo's .worktrees/). A lane is a directory under .worktrees/; remove merged lanes before starting new ones.
lanes_in() { [ -d "$1/.worktrees" ] && find "$1/.worktrees" -mindepth 1 -maxdepth 1 -type d | wc -l || echo 0; }
in_repo=$(lanes_in "$top"); ws=$(dirname "$top"); in_ws=0
for r in "$ws"/*/; do [ -d "$r" ] && in_ws=$((in_ws + $(lanes_in "${r%/}"))); done
[ "$in_repo" -lt 2 ] || { echo "new-lane: refused — wip limit: $in_repo lanes already in $top (max 2 per repo)" >&2; exit 1; }
[ "$in_ws" -lt 3 ] || { echo "new-lane: refused — wip limit: $in_ws lanes already across $ws (max 3 per workspace)" >&2; exit 1; }
git worktree add -q "$wt" -b "$branch" "$base"
# Lanes need the repo's local placeholders (DATABASE_URL of the dev Postgres); .env.example holds no secrets.
[ -f "$top/.env.example" ] && [ ! -f "$wt/.env" ] && cp "$top/.env.example" "$wt/.env"
# The pinned standards come from the primary checkout's own copy (no network, works before the tag is pushed).
git -C "$wt" -c protocol.file.allow=always -c "submodule.standards.url=$top/standards" submodule update -q --init
sed -e "s|^Branch: .*|Branch: $branch|" -e "s|^Base: .*|Base: $(git rev-parse "$base")|" \
  "$top/standards/templates/TASK.template.md" > "$wt/TASK.md"
echo "lane:   $wt"; echo "branch: $(git -C "$wt" branch --show-current)"; echo "base:   $(git rev-parse "$base")"
echo "main:   $(git rev-parse main 2>/dev/null || echo n/a)"
