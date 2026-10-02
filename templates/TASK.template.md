Branch: <model>/<slug>
Base: <sha of integration/mN>
Risk: <set LOW or HIGH — from classify-risk on expected paths; coordinator may raise, never lower>

## 1. Read first (nothing else — only the files you edit plus the ones you must understand, one reason each; the contract is in §7)
- standards/docs/05-domain-rules.md, standards/docs/06-code-quality.md
- standards/specs/correctness.md §<n> (if relevant)
- <file> — <why>

## 2. What this is
<The behaviour this lane delivers, in plain words. Edge cases and abuse case.>

## 3. Files you own (touch nothing else)
- <paths>

## 4. Hard rules for this lane
- <e.g. no new dependencies; uses outbox; lock via DB trigger>

## 5. Verify (three cycles: red batch of the new tests, green batch, controls; then once each at the end — report one line per command)
- standards/bin/check
- scripts/verify/mN.sh --section <lane>   (must go green; the coordinator runs every other section at merge)
- <control test name(s) — database guards only — expected red with this assertion message: "…">

## 6. Commit subject
<type(scope): subject>

## 7. Binding facts from the committed contract
- <types, config keys, error codes the lane must use exactly>
- tests: <file and test names the lane writes, one line each — the red batch runs exactly these>
- controls (database guards only): <control test name — what it disables — its assertion message>
