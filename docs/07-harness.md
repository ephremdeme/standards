# 07 — Harness (read once per session)

## 1. Routing
| Role | Who |
|---|---|
| Coordinator | Claude Fable 5.1, primary checkout. Plans, writes contracts and TASKs, adjudicates, merges into the integration branch, types diffs under ~50 lines itself. |
| HIGH-risk lanes | Claude Opus 5.5 subagent `architect` |
| LOW-risk lanes | DeepSeek V4.1 Flash via `standards/bin/dispatch-deepseek` (Claude Code harness, DeepSeek endpoint; `max` effort for hard LOW lanes). **Game repo only** — the exchange repo has `.no-deepseek`. |
| Reviewer A | `reviewer` (Opus 5.5) for HIGH lanes; `reviewer-lite` (Sonnet 5) for LOW lanes. Never the author's model. |
| Reviewer B (cross-vendor) | Codex via the `codex:codex-rescue` subagent (`--fresh`, adversarial brief) — **HIGH lanes only** |
| Combined review | Coordinator + `/codex:adversarial-review --base main` on the assembled integration branch |
| Independent review | Fresh session on a fresh clone with `standards/prompts/independent-review.md`, attacking every coordinator decision of the milestone |
| Founders | Business-logic review of the milestone PR, decisions, Amharic, device tests |
Founders may override routing in chat; record overrides in `DECISIONS.md`.

## 2. Process
1. **Lane = unit of work and review:** one worktree, one branch `<model>/<slug>`, one self-contained `TASK.md`, disjoint file ownership. Size lanes so one reviewer can review them in one pass. No chains of tiny tasks.
2. **Phase 0 before lanes:** the shared contract (types, schemas, config keys, stubs that fail loudly naming their lane) committed on the integration branch, compiled and tested. Each command/route a lane adds is registered in **its own file**, never a shared table.
3. **Instrument before dispatch:** `scripts/verify/mN.sh` with one section per lane, committed and **proven red per section** (failure named per lane). Chains `mN-1.sh`. Uses `standards/bin/verify-lib.sh` (`expect_out`: real exit code + its own diagnostic regex). A filter that matches no test exits 0 in `cargo test` and vitest (`cargo nextest` exits 4) — so every marker asserts a positive count or an explicit test path.
4. **Verify on committed bytes only.** The coordinator checks the lane branch (`git -C <worktree> status` clean, `git show`, explicit test paths, instrument section) and runs `standards/bin/check-scope <worktree> <base>` (exit 0 = every changed path is owned per TASK §3). Self-reports carry no weight.
5. **Reviews:** LOW lane → Reviewer A. HIGH lane → Reviewer A + Reviewer B. Findings are candidates: reproduce on bytes, then fix with a regression control, or reject with evidence.
6. **Exactly one fix round:** one message with both reviews adjudicated (accept / accept-modified / reject + reason), each with its executed red; a `## Revision` section in TASK.md; one more commit. Items outside the lane's ownership go to the coordinator.
7. **Integrate:** coordinator merges `--no-ff` into `integration/mN` from the primary checkout. After all lanes: combined review + independent review, fixes, instrument green, then **one PR `integration/mN` → `main`** (CI + `risk-gate`; game: 1 founder, exchange: 2 founders). The `risk-gate` check runs the trusted `classify-risk` and `risk-gate` scripts of the pinned standards commit (`standards_ref` of the reusable `.github/workflows/risk-gate.yml`), never the copy in the PR's own `standards` submodule. The fix round after the milestone reviews is itself reviewed: no unreviewed fix commit reaches the PR.
7a. **Merge control is honour-system (D-049, GitHub Free has no rulesets).** The coordinator never merges, and never asks for a merge of, a PR whose `risk-gate` is red. Founders merge milestone PRs only with `risk-gate` and CI green. Every change to this standards repo is itself a PR reviewed by `reviewer` and a founder.
7b. **WIP limit:** at most 3 lanes running at once across the workspace, at most 2 in one repo (game). `new-lane.sh` refuses beyond that; count running lanes before every dispatch.
8. **Decide, don't escalate.** Only decisions with lasting consequences go to founders, **max 4 per batch**, options weighed, recommendation first (`NOTES.md`). Everything else: decide, log in `DECISIONS.md`, build.
9. **State lives in files.** `DECISIONS.md` (append-only), `NOTES.md` (≤150 lines), lane reports in `docs/md-reports/` (≤120 lines). Chat is lost on compaction.

## 3. Founder review of a milestone PR (business logic, not line by line)
Read the milestone report, the specs it implements, the instrument output, and the adjudication tables; answer `standards/HUMAN_REVIEW_CHECKLIST.md`. Line-level scrutiny is delegated to Reviewer A/B, the combined and independent reviews, and machine checks. **Because founders don't read lines, the exchange additionally requires:** property + concurrency tests for every invariant in `standards/specs/correctness.md` §3, and the stdlib-only independent checker (`scripts/verify/ledger-check`) that recomputes balances from exported events without the engine's code.

## 4. Box and harness mechanics
- Lane dispatch uses `standards/prompts/dispatch-brief.md` verbatim. Worktrees are created by `standards/bin/new-lane.sh`, never by agents (tool-created worktrees can hang the session; the script is the one path that pins branch, TASK header, submodule and the lane's `.env` — seeded from `.env.example`, placeholders only — together, and it enforces the WIP limit).
- Pre-dispatch: `grep '^Branch:' TASK.md` matches the worktree branch; a deliberately wrong test path exits non-zero there.
- Never `git stash`; never `pkill -f` (only PIDs you started); absolute paths and `git -C`.
- One full verify chain at a time per machine (`verify-lib.sh` takes a lock). Long runs go to the Bash tool's `run_in_background` with output redirected to a log in the scratchpad; the tool reports the exit when it finishes.
- Command shape, for coordinator and lanes alike (auto mode prompts the founder for anything else): files change through Edit/Write only (no heredocs, `python3 -`, `sed -i`, `perl -pi`); one plain command per Bash call (`git -C`, `env -C <dir> <cmd>`), no `cd … &&` chains or loops; no `DATABASE_URL`, secrets or `PATH=` on a command line and no sourcing `.env` (the tools read it); never edit `.claude/settings*.json`. `.env` is data the tools read, never code: only `DATABASE_URL` is taken from it, literally, by `standards/bin/read-env` (`DATABASE_URL=$(sh standards/bin/read-env DATABASE_URL)`); nothing sources or evaluates it.
- Agents die (rate limits, kills). Lanes make one WIP commit as soon as tests pass locally (squashed at merge). Dead = listed running + output stale + no processes from the worktree → stop it, then a fresh agent with `standards/prompts/takeover.md`.
- Never read or tail a subagent's transcript; only its final report enters the coordinator context.
- Check `/usage` before spawning a burst; one 429 can kill every running agent.
- Codex plugin: jobs are tracked per repository/working directory — run `/codex:status` and `/codex:result` from the directory that launched them. `/codex:rescue` **can modify code**: per-lane Codex reviews run inside a disposable review checkout (`standards/bin/review-checkout`) with an explicit "change nothing" brief, followed by `review-verify-clean`. Model and effort come from `.codex/config.toml` (project must be trusted). **Do not enable the Codex review gate** (Stop-hook loop; drains usage).
- `git push` only by the coordinator, as its own command, after a founder's word.

## 5. Isolation
Workers run in a container or separate OS user: their worktree only, no Docker socket, no `~/.ssh`, no GitHub token, no production credentials, network limited to package registries and model endpoints; test Postgres reached over TCP. Reviewers: disposable clone, read-only tools, tamper check. DeepSeek variables exist only inside `dispatch-deepseek` (or the interactive `deepseek` shell function, which runs in a subshell). Permission settings are defence in depth, not the boundary.

## 6. DeepSeek usage
- Official integration: Claude Code pointed at `https://api.deepseek.com/anthropic` with a DeepSeek API key. Metered pay-per-token API, so scripted dispatch is ordinary API use (no coding-plan tool restrictions).
- Model names: `deepseek-flash` (legacy `deepseek-v4-flash` is retired and served by V4.1 Flash); `deepseek-v4-pro` exists but is not used by default. Unknown Claude model names sent to this endpoint are mapped by DeepSeek (opus → v4-pro, sonnet/haiku → flash), so **inside a DeepSeek session every "Claude" subagent is actually DeepSeek.** Reviews and Claude subagents run only from normal `claude` sessions.
- **Code leaves the machine to DeepSeek.** Allowed for game LOW lanes (player UI, docs); admin screens are HIGH (they resolve, void and reissue questions) and never go to DeepSeek (m1.1 O2). Never for the exchange (money core and sellable IP): its repo carries `.no-deepseek` and the script refuses. Never production data (domain rule 7).
- Env vars follow DeepSeek's official Claude Code guide, including `CLAUDE_CODE_AUTO_COMPACT_WINDOW=786432`. Deviation: effort defaults to `high` (guide: `max`); use `max` for hard LOW lanes.
- Lanes run with WebSearch/WebFetch disabled (DeepSeek's web search costs extra tokens and widens prompt-injection surface).
- The `claude-opus*` → `deepseek-v4-pro` mapping is billed at Pro price; lanes force subagents to `deepseek-flash`.
- Keep a small prepaid balance and a spend alert; a leaked key can only burn the balance.
- Verify at bootstrap: inside a `deepseek` session, `/status` shows the DeepSeek base URL; in a normal session it doesn't.
