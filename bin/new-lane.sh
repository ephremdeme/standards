#!/bin/sh
# Usage: standards/bin/new-lane.sh <branch> [base]   (run from the primary checkout; coordinator only)
set -eu
branch=${1:?branch like opus/lock-timing}; base=${2:-HEAD}
slug=$(printf '%s' "$branch" | tr '/' '-')
top=$(git rev-parse --show-toplevel); wt="$top/.worktrees/$slug"
git worktree add -q "$wt" -b "$branch" "$base"
git -C "$wt" submodule update -q --init
sed -e "s|^Branch: .*|Branch: $branch|" -e "s|^Base: .*|Base: $(git rev-parse "$base")|" \
  "$top/standards/templates/TASK.template.md" > "$wt/TASK.md"
echo "lane:   $wt"; echo "branch: $(git -C "$wt" branch --show-current)"; echo "base:   $(git rev-parse "$base")"
echo "main:   $(git rev-parse main 2>/dev/null || echo n/a)"
