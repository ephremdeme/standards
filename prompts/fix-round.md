# Fix round (exactly one, blockers only) — send as ONE message to the lane's implementer
The lane review is adjudicated below (docs/07 §2 item 7). For each accepted blocker: write the regression control first, show it red, fix, show it green. For each accepted major: commit one red `fix_<id>` test in the lane's own test binary whose failure text quotes the finding, and leave it red (the consolidated fix lane fixes it). Rejected items: no action.
| # | Source | Finding | Verdict | Required change |
|---|---|---|---|---|
Add a `## Revision` section to TASK.md listing what changed. One commit: `fix(<scope>): address review for <lane>`. Report one line per command (pass or fail, nothing pasted). Anything outside your file ownership: do not touch; list it for the coordinator.
