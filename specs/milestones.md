# Milestones (each gets `specs/milestones/mN.md` from `templates/milestone.md` before work starts)

## Game — integration branch per milestone; the founder merges the milestone PR after CI green and the risk-gate HIGH list
| # | Scope | Human gate |
|---|---|---|
| G0 | Repo, pinned standards submodule, `check` + instrument lib, CI + `risk-gate`, informational risk-gate (rulesets not needed while the founder is the only merger), worker containers, threat model, data-flow doc, deploy + encrypted backup + restore drill on staging (fake data), `smoke/run.sh` green incl. Rust | Founders confirm merge-control tests and restore drill |
| G1 | Questions from fixture templates (human approves), lock timing per specs §1, void-and-reissue, freeze, kickoff-change alert + auto-lock, resolve/void with evidence + correction note, repeatable points | Founders run the pick→lock→result flow |
| G2 | Auth (per open login decision), initData verification + abuse controls, sessions, age gate, account recovery, data export/delete | Founders try takeover/abuse cases from the report |
| G3 | Invite groups, accuracy leaderboards, club badge (rankings hidden), participation + hot streaks, opt-in reminders via outbox (specs §2) | — |
| G4 | Pre-match + result share cards, human Amharic via i18n keys, evidence pages, QR/deep links | Native speaker approves every string |
| G5 | Cheap-Android budget, GlitchTip, second restore drill, feed rights, legal screen review, growth metrics, go/no-go | Founders' go/no-go |
Stretch (only if ahead): monthly leagues. January: streak freezes, referral rewards (need abuse controls), Beat the Pundit (needs a signed pundit).

## Exchange — integration branch per milestone; the founder merges after CI green, the ledger checker and the invariant tests (business logic)
| # | Scope |
|---|---|
| E0 | Repo, pinned standards, CI + `risk-gate` (informational), money-model spec accepted, invariant/property tests written red, performance targets, independent ledger checker skeleton |
| E1 | Accounts, available/reserved, simulated deposits/withdrawals, per-market attribution, idempotency with fingerprint, checked math |
| E2 | Lifecycle (open ⇄ paused → closed at `lock_at`), limit orders + max-price guard, reservations (cash and shares), locking order, partial fills, cancel, one YES-priced book with MINT/TRANSFER/BURN fills, self-trade prevention, per-market pause (correctness.md §3 amendment of 2026-10-03) |
| E3 | Resolve YES/NO → finalized → settled, fees, self-exclusion; **BLOCKED until the §3 open values are decided:** void/refund (void policy), settlement timing (correction window), fee calculation (fee rounding; fees on MINT/BURN/settlement; fees on a voided market) |
| E4 | Event export, independent checker green on every run, admin/test tool, API docs, market-maker client (caps, kill switch) |
Pauses if the game slips in late November. Per-operator packaging: future option.
