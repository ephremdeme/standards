# Correctness specs (binding; lanes cite the section they implement)

## 1. Pick lock timing (game)
- `questions.lock_at` (timestamptz, UTC) = `kickoff_at − lock_offset` (open decision, NOTES.md). Status: `draft → open → locked → resolved | voided`.
- **Acceptance point:** a pick is accepted if, *inside the inserting transaction and after acquiring a lock on the question row*, `status = 'open'` and `clock_timestamp() < lock_at`. Never use `now()`/`CURRENT_TIMESTAMP` for this — in PostgreSQL they return the transaction start time, so a request that waited would be judged by its start time.
- Enforce in a `BEFORE INSERT` trigger on `picks` (`SELECT … FROM questions WHERE id = NEW.question_id FOR SHARE`, then the check), so no code path can skip it. Admin changes to `kickoff_at`/`lock_at`/status take `FOR UPDATE` on the same row, so they serialize against picks.
- Store `picks.accepted_at = clock_timestamp()`. `statement_timeout` and `idle_in_transaction_session_timeout` bound how long a pick transaction can hang.
- Kickoff changes: fixture feed change → alert admin; if new `lock_at` is past → auto-lock. Picks accepted after the *real* kickoff because of a late feed update follow the open late-kickoff decision (NOTES.md).
- **Question immutability (replaces "versions"):** once the first pick exists, wording, source, rules and lock time semantics are frozen. A *material* change = **void the question and issue a new one** (new ID); users are notified and may pick again. So a user can hold at most one scoring pick per question: `UNIQUE (user_id, question_id)`. Non-material fixes (typo, Amharic spelling) are allowed only with founder approval and an audit-log entry, never changing meaning. (Open decision; this is the recommended default.)
- **Required tests:** transaction opened before `lock_at` that sleeps past it then inserts → rejected; concurrent pick vs admin freeze; `lock_at` = now+1s boundary; duplicate pick rejected; pick on a voided/locked question rejected; edit of a question with picks rejected unless via void-and-reissue.

## 2. Notifications: transactional outbox
- Any state change that should notify (card open, lock soon, result in, streak at risk) inserts an `outbox` row **in the same transaction**: `id, kind, payload, dedupe_key UNIQUE, status, attempts, next_attempt_at, lease_until, sent_at, last_error`.
- Worker claims rows with `FOR UPDATE SKIP LOCKED`, sets a lease, sends, marks `sent`. Retries with exponential backoff; after N attempts → `dead` + alert.
- Delivery is **at-least-once**. Duplicates are prevented by `dedupe_key` (e.g. `result:<question>:<user>`) and a `sent` check before sending; a crash between the Telegram send and marking `sent` can still duplicate one message — accepted and documented.
- Required tests: crash after commit before send → message still sent; worker crash mid-send → retried; same event twice → one row.

## 3. Exchange money model (before E1 code)
- **Balances:** per account `available` and `reserved` (santim), `CHECK (≥ 0)`; every change is ledger entries summing to zero; stored balances must equal the sum of entries (checked by tests and the replay check).
- **Reservations:** placing a buy reserves `price × qty + max_fee` from available in the same transaction; cancel/fill releases or consumes it. This — not balanced entries alone — prevents concurrent overspending.
- **Locking order:** lock the market row `FOR UPDATE` (serializes matching per market), then account rows in ascending account id. One order of acquisition everywhere prevents deadlocks.
- **Idempotency with fingerprint:** every command carries a client key. Store `(account_id, idempotency_key, command_type, request_hash, result, created_at)` atomically with the effect, `UNIQUE (account_id, idempotency_key)`. `request_hash` = hash of the normalized input. Same key + same hash → return the stored result; same key + different hash or type → **409 conflict**, never the earlier result.
- **Collateral:** a matched YES@p + NO@(100−p) pair moves 100 santim per contract into the market escrow account. After settlement, escrow must be exactly 0.
- **Fees:** integer santim; rounding rule is an open decision; property tests prove rounding never creates or destroys money.
- **Overflow and limits:** checked arithmetic everywhere; config limits for max order quantity, max notional, max position, max market exposure.
- **Crash recovery:** no in-memory authority; all state changes are transactional; restart reads the DB; events via outbox; replay check rebuilds all balances from the ledger and must match.
- **Per-market cash-flow attribution** from E1 (every entry tagged with market and account), so any void policy is implementable.
- **Amendment (founder, 2026-10-03; binding from E2 — positions, fill types, lifecycle, self-trade, fees).** The E1 rules above stand; where this amendment is more specific it wins. Two clarifications are marked *(clarification)*: they keep the amendment consistent with the E1 bullets and change no rule.
  - Positions: per (account, market, outcome) `available_shares`, `reserved_shares`, CHECK (>= 0), changed only by ledger entries. A sell order reserves shares; cancel/fill releases or consumes them. *(clarification)* "Entries summing to zero" above is per unit: the cash entries of a transaction sum to zero; share entries are not zero-sum (MINT creates a YES/NO pair, BURN destroys one) and are governed by the pairs invariant below.
  - One order book per market priced in YES (1..99). Buy NO@q == sell YES@(100-q). Fill types: MINT (YES buyer + NO buyer: both pay into escrow, 100 per pair), TRANSFER (share seller -> buyer, cash between them, escrow unchanged), BURN (YES seller + NO seller: pair destroyed, escrow pays p and 100-p). Fills at the resting order's price; excess reservation released.
  - Invariants at every commit: total YES = total NO = pairs_outstanding; escrow = 100 x pairs_outstanding; sum of all cash (accounts + escrow + fee account) unchanged except by deposits/withdrawals.
  - Trading closes at lock_at (DB-enforced, clock_timestamp()); closing cancels open orders and releases reservations in the same transaction. *(clarification)* The acceptance point follows §1: inside the inserting transaction, after the market row lock, `status = 'open'` and `clock_timestamp() < lock_at`; never `now()`.
  - Lifecycle: open -> closed -> resolved -> finalized (after correction window, config) -> settled | voided. Payouts only at settlement. Settlement cancels remaining orders first, then pays 100 per winning share from escrow; escrow must end at 0.
  - Self-trade prevention: an incoming order that would match the same account's resting order is cancelled.
  - Fees (rounding = open decision): paid by the taker on fill notional, posted to a fee account; state whether MINT/BURN/settlement/void charge or refund fees.
  - Withdrawals use available balance only. Prices outside 1..99 rejected.
  - Required tests add: concurrent double-sell of the same shares rejected; burn keeps both invariants; trading after lock_at rejected; settlement before finalization rejected; self-trade cancelled; checker verifies YES = NO = pairs and escrow = 100 x pairs on every run.
  - Open values (the exchange's NOTES "Needs you now"; one DECISIONS entry each when answered): void policy (A/B/C below), fee rounding, correction window length, fees on a voided market. Work that depends on them (E3 void/refund, settlement timing, fee calculation) is BLOCKED in `specs/milestones/` until answered.
- **Void/refund after secondary trading = an open decision — E3 void/refund is blocked until decided.** Reversing all market cash flows is **not automatically safe**: a trader may have used a resale gain in another market or withdrawn it, so a reversal could create negative balances. Each void policy must be paired with a fund-release rule:
  | Policy | Needs a fund-release restriction? | Can create negative balances? | Fairness |
  |---|---|---|---|
  | A. Reverse all market cash flows | **Yes** — resale proceeds stay locked (not withdrawable or usable elsewhere) until the market settles | Only if the restriction is missing | Everyone returns to pre-market state |
  | B. Pay 50 santim per share to both sides from escrow | No — paid from existing escrow, which exactly covers it | No | Simple; some traders lose vs their entry price |
  | C. Refund current holders' cost basis | Yes, and escrow may not cover it | Possible | Complex; disputes likely |
  Required test for whichever is chosen: void after multi-hop resale where proceeds were used elsewhere → no negative balance, escrow ends at 0.
- Required tests (property + concurrency): conservation; no negative available/reserved; concurrent orders from one account can't overspend; idempotent retries; replay equivalence; price-time priority; escrow zero after settlement.


## 4. Test dates
Tests derive times from config and the database clock (e.g. `lock_at = clock_timestamp() + interval`), never calendar literals, so tests don't rot.

## 5. Independent ledger checker (exchange)
`scripts/verify/ledger-check` — stdlib only, no engine code — reads the exported event log and recomputes every balance, escrow and invariant. The instrument runs it after every exchange test run and compares with the ledger.
