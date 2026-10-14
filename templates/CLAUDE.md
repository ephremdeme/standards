# <repo> — <one-line purpose>
<Up to ten lines of project context: what it is, who uses it, what "done" means now.>

## Required reading (from this checkout only; standards/ is pinned in-repo)
standards/docs/05-domain-rules.md · standards/docs/06-code-quality.md · standards/docs/07-harness.md (integrator: once per session)
Lanes read only their TASK.md and what it lists.

## Process
1. The unit of work and review is the lane: one worktree, one branch, one self-contained TASK.md, disjoint file ownership (the owned-paths block of TASK §3). The **integrator** — a fresh Opus session per phase, at most three per milestone — owns lanes, merges, dispositions and NOTES; it writes no code.
2. Phase 0 before lanes: the shared contract and the instrument `scripts/verify/mN.sh`, committed and proven red per section on committed bytes; the Codex plan review (plus one re-read) before the first dispatch. Every guard ships a negative control executed red.
3. Verify on committed bytes only (`check-scope`, explicit test paths, the lane's instrument section); self-reports carry no weight.
4. Done is mechanized: instrument, controls, `local-mutants` at close, the `local-gate` log as CI. A finding counts only as a failing test or check, fixed red-first; findings are classified by impact — an untested race or a guard without a test is never minor. A per-lane Opus review runs only for a lane whose TASK §2 `Tags:` line is not `none`; one in-lane fix round for blockers only; majors go to the one consolidated fix lane (a test-gap major: the mutation path), each under a red `fix_<id>` test that lane commits first. Merge `--no-ff` into `integration/mN` when green with no blocker. Then the Codex integrated review → fix lane → fix-delta read → close-delta read (five Codex reads per milestone with the plan review and its re-read). The milestone PR goes through `merge-pr --local-log <log> --milestone mN` after the `founder-approved` label and the human gate (the founder reads business logic, not lines). If a fix creates another serious defect, stop or narrow scope and ask the founder — never merge to satisfy a round limit (standards/docs/07 §2 items 7–8).
5. Decide, don't escalate: only lasting decisions go to founders, max 4 per batch, recommendation first.
6. State lives in files: DECISIONS.md, NOTES.md, BACKLOG.md, docs/md-reports/.

## Git
Conventional commits; one commit per completed feature (plus squashed WIP); lane branches `<model>/<slug>`; merges only by the integrator from the primary checkout; pushes only through `standards/bin/push-branch`, merges only through `standards/bin/merge-pr`; never `git stash`.

## Commands
`standards/bin/check` · `scripts/verify/mN.sh` · `standards/bin/new-lane.sh <branch> <base>` · `standards/bin/task-lint <worktree>` (before every dispatch) · `standards/bin/classify-risk <base> <head>` · `standards/bin/check-scope <worktree> <base>` · `standards/bin/with-build-lock cargo …` (every cargo command) · `standards/bin/local-gate <repo> <mN> <log>` · `standards/bin/local-mutants <clone> <base> <crate> [--tests …]` · `standards/bin/prune-lane <worktree> <merged-into>` (after every merge) · `standards/bin/push-branch` · `standards/bin/merge-pr` (integrator)

## Gotchas (maintained via /claude-md-management:revise-claude-md; one line each)
-
