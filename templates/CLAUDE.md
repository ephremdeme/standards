# <repo> — <one-line purpose>
<Up to ten lines of project context: what it is, who uses it, what "done" means now.>

## Required reading (from this checkout only; standards/ is pinned in-repo)
standards/docs/05-domain-rules.md · standards/docs/06-code-quality.md · standards/docs/07-harness.md (integrator: once per session) · hub/lessons/README.md
Lanes read only their TASK.md and what it lists.

## Process, git and commands
standards/docs/07-harness.md §1–§2 (routing, the bounded loop, lane economy, the gates) and §4 (box mechanics, push and merge) are the rules; the cross-repo rules (shell command shape, Codex from the repo checkout, lessons) are the workspace CLAUDE.md; the shared lessons of every session are `hub/lessons/README.md` (required reading; rewrite a topic there when you learn something, repo memory holds live state only). Git: conventional commits via `git commit -F <file>`, one commit per completed feature (plus squashed WIP); lane branches `<model>/<slug>`; merges only by the integrator from the primary checkout; pushes and merges only through `standards/bin/push-branch` and `standards/bin/merge-pr`; never `git stash`.

`standards/bin/check` · `scripts/verify/mN.sh` · `standards/bin/new-lane.sh <branch> <base>` · `standards/bin/task-lint <worktree>` (before every dispatch) · `standards/bin/classify-risk <base> <head>` · `standards/bin/check-scope <worktree> <base>` · `standards/bin/with-build-lock cargo …` (every cargo command) · `standards/bin/local-gate <repo> <mN> <log>` · `standards/bin/local-mutants <clone> <base> <crate> [--tests …]` · `standards/bin/prune-lane <worktree> <merged-into>` (after every merge) · `standards/bin/push-branch` · `standards/bin/merge-pr` (integrator) · `standards/bin/lane-verify` · `standards/bin/gate-summary` · `standards/bin/close-check`

## Gotchas (maintained via /claude-md-management:revise-claude-md; one line each)
- Codex: run it from this checkout so `.codex/config.toml` pins the model and effort; from any other cwd pass `--model` and `--effort` explicitly (the global `~/.codex/config.toml` defaults to another model).
