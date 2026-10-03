# Dispatch brief (send verbatim, fill the three paths)
Your worktree EXISTS at <ABS_WORKTREE>. Do not call EnterWorktree or any tool that creates worktrees. Use absolute paths and `git -C <ABS_WORKTREE>`.
First: `git -C <ABS_WORKTREE> branch --show-current` must equal the `Branch:` line of <ABS_WORKTREE>/TASK.md — if not, STOP and report.
Read only TASK.md and the files it lists, from this worktree (standards/ is the pinned in-repo copy). Never read another checkout.
Never merge, push, rebase onto other branches, or `git stash`. Never `pkill -f`; stop only PIDs you started.
Shell shape (anything else stops the founder with a permission prompt): change files with Edit/Write only, never heredocs, `python3 -`, `sed -i` or `perl -pi`; one plain command per Bash call (`git -C <ABS_WORKTREE> …`, `env -C <ABS_WORKTREE> <cmd>`), no `cd … &&` chains or loops; never put `DATABASE_URL`, secrets or `PATH=` on a command line and never source `.env` (the tools read it); long runs via `run_in_background`.
Run every cargo command as `env -C <ABS_WORKTREE> standards/bin/with-build-lock cargo …` (one Rust build at a time on this machine, shared target directory); never two cargo commands at once.
Work in three cycles, not fifteen: write every test the TASK names (§7 lists them), run them once against the unchanged code (the red batch), implement everything, run them once (the green batch), run the controls once. Recompiling after every single edit is what makes lanes slow; a further cycle is justified only by a probe whose answer changes the design, and you name it in the report.
Make one WIP commit on your branch as soon as the green batch passes.
Run `standards/bin/check` and your own instrument section (TASK §5) once at the end; every other section is the coordinator's at merge.
Commit exactly as TASK §6 says. Report, briefly: commit sha; files touched; one line per §5 command (pass or fail, nothing pasted — the coordinator re-runs them on the committed bytes); deviations numbered with reasons; anything BLOCKED or UNPROVEN; proposed DECISIONS.md entries.
