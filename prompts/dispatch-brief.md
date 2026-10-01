# Dispatch brief (send verbatim, fill the three paths)
Your worktree EXISTS at <ABS_WORKTREE>. Do not call EnterWorktree or any tool that creates worktrees. Use absolute paths and `git -C <ABS_WORKTREE>`.
First: `git -C <ABS_WORKTREE> branch --show-current` must equal the `Branch:` line of <ABS_WORKTREE>/TASK.md — if not, STOP and report.
Read only TASK.md and the files it lists, from this worktree (standards/ is the pinned in-repo copy). Never read another checkout.
Never merge, push, rebase onto other branches, or `git stash`. Never `pkill -f`; stop only PIDs you started.
Shell shape (anything else stops the founder with a permission prompt): change files with Edit/Write only, never heredocs, `python3 -`, `sed -i` or `perl -pi`; one plain command per Bash call (`git -C <ABS_WORKTREE> …`, `env -C <ABS_WORKTREE> <cmd>`), no `cd … &&` chains or loops; never put `DATABASE_URL`, secrets or `PATH=` on a command line and never source `.env` (the tools read it); long runs via `run_in_background`.
Make one WIP commit on your branch as soon as tests pass locally.
Run `standards/bin/check` and your instrument section (TASK §5) once at the end, not repeatedly.
Commit exactly as TASK §6 says. Report: files touched; every §5 command with output verbatim; each new guard's executed red; deviations numbered with reasons; anything BLOCKED or UNPROVEN.
