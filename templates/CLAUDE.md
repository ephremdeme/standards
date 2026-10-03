# <repo> — <one-line purpose>
<Up to ten lines of project context: what it is, who uses it, what "done" means now.>

## Required reading (from this checkout only; standards/ is pinned in-repo)
standards/docs/05-domain-rules.md · standards/docs/06-code-quality.md · standards/docs/07-harness.md (coordinator: once per session)
Lanes read only their TASK.md and what it lists.

## Process
1. The unit of work and review is the lane: one worktree, one branch, one self-contained TASK.md, disjoint file ownership.
2. The milestone instrument is committed and proven red per section before any lane starts. Every guard ships a negative control executed red (a database guard: a trigger-disabled control; a Rust-level guard: a mutant killed at merge).
3. Verify on committed bytes only; self-reports carry no weight.
4. Done is mechanized (instrument, controls, mutation run, CI); a review finding counts only once it is a failing test or check, else it goes to the NOTES backlog; findings are classified by impact — an untested race or a guard without a test is never minor. HIGH lanes get one Opus review, LOW lanes none beyond the instrument; one fix round for blockers only; merge --no-ff into integration/mN when green with no blocker; every coordinator merge edit gets a diff-only Opus review logged in the report (no unreviewed head). One milestone review (Codex, Opus fallback) → one fix lane for blockers and majors, re-verified mechanically → the milestone PR. If a fix creates another serious defect, stop or narrow scope and ask the founder — never merge to satisfy a round limit (standards/docs/07 §2 5–7). The founder merges the milestone PR with CI green after reading the risk-gate HIGH list (informational gate, solo developer).
5. Decide, don't escalate: only lasting decisions go to founders, max 4 per batch, recommendation first.
6. State lives in files: DECISIONS.md, NOTES.md, docs/md-reports/.

## Git
Conventional commits; one commit per completed feature (plus squashed WIP); lane branches `<model>/<slug>`; merges only by the coordinator from the primary checkout; never `git stash`; never push without a founder's word.

## Commands
`standards/bin/check` · `scripts/verify/mN.sh` · `standards/bin/new-lane.sh <branch> <base>` · `standards/bin/classify-risk <base> <head>` · `standards/bin/check-scope <worktree> <base>` · `standards/bin/task-lint <worktree>` · `standards/bin/with-build-lock cargo …` · `standards/bin/prune-lane <worktree> <merged-into>` · `standards/bin/mutants <clone> <base> <crate> [<functions>]` (coordinator)

## Gotchas (maintained via /claude-md-management:revise-claude-md; one line each)
-
