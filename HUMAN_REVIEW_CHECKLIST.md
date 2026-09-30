# Founder review of a milestone PR — business logic, not line by line (≈30–60 min)

Read: the milestone report (docs/md-reports/), specs/milestones/mN.md, the spec sections it implements, the instrument output in the report.

## Every milestone
- [ ] I can say in two sentences what users (or operators) can now do that they couldn't before.
- [ ] Every acceptance row in mN.md has a green instrument marker, and each guard shows its negative control red.
- [ ] The adjudication tables: rejected findings have a reason I accept; nothing important is marked UNPROVEN or BLOCKED without a plan.
- [ ] No new foreign service, personal data in logs, or betting-looking copy (domain rules 1, 5, 6).
- [ ] Decisions the coordinator took this milestone (DECISIONS.md) — I agree, or I add a superseding entry.

## Game milestones touching picks, results, points, groups
- [ ] A slow request can't sneak a pick past the lock (specs §1 tests listed in the report).
- [ ] Resolving or voiding twice can't double-count points; users see corrections.
- [ ] Someone outside a group or without admin rights can't read or change it (the report names the tests).

## Exchange milestones (both founders)
- [ ] The business rules match what we decided (order matching, fees, void policy, limits) — walk through one example trade end-to-end in the report.
- [ ] The independent ledger checker ran green on every test run, and its negative control (a deliberately broken ledger) ran red.
- [ ] Concurrency tests exist for overspending and double settlement.

If any answer is "no" or "not sure": request changes with the question written in the PR.
