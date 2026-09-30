Branch: <model>/<slug>
Base: <sha of integration/mN>
Risk: <set LOW or HIGH — from classify-risk on expected paths; coordinator may raise, never lower>

## 1. Read first (nothing else)
- standards/docs/05-domain-rules.md, standards/docs/06-code-quality.md
- standards/specs/correctness.md §<n> (if relevant)
- <contract files from phase 0>

## 2. What this is
<The behaviour this lane delivers, in plain words. Edge cases and abuse case.>

## 3. Files you own (touch nothing else)
- <paths>

## 4. Hard rules for this lane
- <e.g. no new dependencies; uses outbox; lock via DB trigger>

## 5. Verify (run once at the end; paste output verbatim)
- standards/bin/check
- scripts/verify/mN.sh --section <lane>   (must go green; other sections byte-identical)
- <negative control command, expected red + its diagnostic>

## 6. Commit subject
<type(scope): subject>

## 7. Binding facts from the committed contract
- <types, config keys, error codes the lane must use exactly>
