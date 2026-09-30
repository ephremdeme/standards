# Milestones (each gets `specs/milestones/mN.md` from `templates/milestone.md` before work starts)

## Game — integration branch per milestone, 1 founder approves the milestone PR
| # | Scope | Human gate |
|---|---|---|
| G0 | Repo, pinned standards submodule, `check` + instrument lib, CI + `risk-gate`, rulesets + merge-control test PRs, worker containers, threat model, data-flow doc, deploy + encrypted backup + restore drill on staging (fake data), `smoke/run.sh` green incl. Rust | Founders confirm merge-control tests and restore drill |
| G1 | Questions from fixture templates (human approves), lock timing per specs §1, void-and-reissue, freeze, kickoff-change alert + auto-lock, resolve/void with evidence + correction note, repeatable points | Founders run the pick→lock→result flow |
| G2 | Auth (per open login decision), initData verification + abuse controls, sessions, age gate, account recovery, data export/delete | Founders try takeover/abuse cases from the report |
| G3 | Invite groups, accuracy leaderboards, club badge (rankings hidden), participation + hot streaks, opt-in reminders via outbox (specs §2) | — |
| G4 | Pre-match + result share cards, human Amharic via i18n keys, evidence pages, QR/deep links | Native speaker approves every string |
| G5 | Cheap-Android budget, GlitchTip, second restore drill, feed rights, legal screen review, growth metrics, go/no-go | Founders' go/no-go |
Stretch (only if ahead): monthly leagues. January: streak freezes, referral rewards (need abuse controls), Beat the Pundit (needs a signed pundit).

## Exchange — integration branch per milestone, 2 founders approve the milestone PR (business logic)
| # | Scope |
|---|---|
| E0 | Repo, pinned standards, CI + `risk-gate` (2 approvals), money-model spec accepted, invariant/property tests written red, performance targets, independent ledger checker skeleton |
| E1 | Accounts, available/reserved, simulated deposits/withdrawals, per-market attribution, idempotency with fingerprint, checked math |
| E2 | Lifecycle, limit orders + max-price guard, reservations, locking order, partial fills, cancel, pair minting, per-market pause |
| E3 | Resolve YES/NO, fees, self-exclusion; void/refund only after the open void decision |
| E4 | Event export, independent checker green on every run, admin/test tool, API docs, market-maker client (caps, kill switch) |
Pauses if the game slips in late November. Per-operator packaging: future option.
