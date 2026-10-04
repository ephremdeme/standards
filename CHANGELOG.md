# Changelog
Versions are git tags; product repos pin a tag's commit as their `standards` submodule. Earlier tags (v0.1.0–v0.1.15) are recorded in their merge commits only.

- v0.1.17 — rust-ci: the service cluster persists `track_commit_timestamp = on` (ALTER SYSTEM + restart, verified by SHOW) before the schema is migrated, for callers whose tests assert it (exchange D-081 late-fill monitor); correctness.md §3 deadline rule restated on the acceptance stamp (`created_at_us`, trigger-set and role-immutable) instead of the transaction's BEGIN (exchange D-082)
- v0.1.16 — rust-ci: conditional application-role step (APP_DATABASE_URL) for callers shipping scripts/db/app-role.sh
