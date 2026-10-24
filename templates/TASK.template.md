Branch: <model>/<slug>
Base: <sha of integration/mN>
Risk: <set LOW or HIGH — from classify-risk on expected paths; integrator may raise, never lower>

## 1. Read first (nothing else — only the files you edit plus the ones you must understand, one reason each; the contract is in §7)
- standards/docs/05-domain-rules.md, standards/docs/06-code-quality.md
- standards/specs/correctness.md §<n> (if relevant)
- <file> — <why>

## 2. What this is
Complexity: <low | medium | high — the effort the milestone spec's matrix gives this lane; a DeepSeek lane is low or medium>
Tags: <none — or a comma-separated list from: sql authz privacy input crypto destructive checker supply-chain; anything but none means one Opus `reviewer` pass (docs/07 §1); a ds/ lane must be none>
<The behaviour this lane delivers, in plain words. Edge cases and abuse case.>

## 3. Files you own (touch nothing else; read only from the block below — prohibitions go to §4)
```owned
<one repo-relative path or pattern per line; a trailing / owns the directory>
```

## 4. Hard rules for this lane
- <e.g. no new dependencies; uses outbox; lock via DB trigger>
- Standing rules from past reviews (docs/06 "Never"): take row locks fixture → question, never the reverse; every error path fails closed (a failed command, an empty read or a missing file is a refusal, never a pass); validate every value read from config, env or a request before use; a control is red for its own reason (its own assertion message, not just a failed count); `.env` is data, never sourced; risk is judged by what a path does, never by where it sits.

## 5. Verify (three cycles: red batch of the new tests, green batch, controls; then once each at the end — report one line per command)
- standards/bin/check --only <kind>   (<kind> = `standards/bin/owned-paths --kind TASK.md`: web, rust or all; a lane in a Go module (`go.mod` at the top): go)
- scripts/verify/mN.sh --section <lane>   (must go green; the integrator runs every other section at merge)
- <control test name(s) — database guards only — expected red with this assertion message: "…">

## 6. Commit subject
<type(scope): subject>

## 7. Binding facts from the committed contract
- <types, config keys, error codes the lane must use exactly>
- tests: <file and test names the lane writes, one line each — the red batch runs exactly these>
- controls (database guards only): <control test name — what it disables — its assertion message>
