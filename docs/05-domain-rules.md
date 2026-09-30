# 05 — Domain rules (override everything; violating one = blocking finding)

1. **Nothing real-money.** No licence exists. The game has no deposits, prizes, redeemable points, birr symbols, tickets, odds or "real money coming soon" copy. The exchange runs simulated units only.
2. **Rewards are status only** (badges, ranks, streaks). Streak mechanics never move into a real-money product without ELS guidance.
3. **Money is integer santim (`i64`), checked arithmetic.** No floats.
4. **Sports only.** No political markets. No crypto or tokens.
5. **Data stays in Ethiopia.** Production personal data is stored only in approved Ethiopian infrastructure. The only foreign service in the user data flow is Telegram, limited to what the Mini App/bot needs (Telegram ID to open the app and deliver opted-in reminders; message text has no names, picks or personal data). Every flow is listed in `docs/data-flow.md`.
6. **Logs** contain only: timestamp, request ID, route, method, status, latency, error code, IDs of non-person objects (question, group, market). Never user/Telegram IDs, names, usernames, phone, IP, tokens or message text. Support linking uses a keyed pseudonym (HMAC, key rotated monthly).
7. **Agents never see production data, secrets or backups.** Every fixture file starts with the line `# SYNTHETIC — not real user data` (or the language's comment form).
8. **Locks are enforced by the database** per `standards/specs/correctness.md` §1.
9. **Never trust the client.** Telegram initData verified server-side; every admin and group action authorized on the server.
10. **Amharic text comes from humans.** Agents use i18n keys only.
11. **Facts that change** (legal limits, ages, fees) live in config with `as_of` and `review_by` dates; `standards/legal-assumptions.md` lists them. Code never hard-codes them.
