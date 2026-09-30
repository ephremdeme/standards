# <repo> — <one-line purpose>
<Up to ten lines of project context: what it is, who uses it, what "done" means now.>

## Required reading (from this checkout only; standards/ is pinned in-repo)
standards/docs/05-domain-rules.md · standards/docs/06-code-quality.md · standards/docs/07-harness.md (coordinator: once per session)
Lanes read only their TASK.md and what it lists.

## Process
1. The unit of work and review is the lane: one worktree, one branch, one self-contained TASK.md, disjoint file ownership.
2. The milestone instrument is committed and proven red per section before any lane starts. Every guard ships a negative control executed red.
3. Verify on committed bytes only; self-reports carry no weight.
4. HIGH lanes get two reviews (same vendor + Codex), LOW lanes one; exactly one fix round; merge --no-ff into integration/mN; combined + independent review before the milestone PR.
5. Decide, don't escalate: only lasting decisions go to founders, max 4 per batch, recommendation first.
6. State lives in files: DECISIONS.md, NOTES.md, docs/md-reports/.

## Git
Conventional commits; one commit per completed feature (plus squashed WIP); lane branches `<model>/<slug>`; merges only by the coordinator from the primary checkout; never `git stash`; never push without a founder's word.

## Commands
`standards/bin/check` · `scripts/verify/mN.sh` · `standards/bin/new-lane.sh <branch> <base>` · `standards/bin/classify-risk <base> <head>`

## Gotchas (maintained via /claude-md-management:revise-claude-md; one line each)
-
