#!/bin/sh
# Bootstrap smoke test on disposable local repos. Usage: sh standards/smoke/run.sh (from the workspace; any cwd works)
# Copy of handoff/smoke/run.sh with two fixes: lives inside the standards repo ($H is the standards root), and the
# "red when the code is wrong" control escapes the + in its perl mutation (the original s/a + b/… never matched).
# Prints PASS / FAIL / BLOCKED per claim. GitHub-side controls need a real org and are reported BLOCKED here.
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); R=0
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }; blk(){ echo "BLOCKED $1"; }
# expected failures must fail FOR THE RIGHT REASON: exit 1 from our script, not 126/127 (not executable / not found) or 2 (usage)
expect_fail(){ sh -c "$2" >/tmp/o 2>&1; rc=$?; if [ $rc -eq 1 ]; then ok "$1"; elif [ $rc -eq 0 ]; then bad "$1 (expected failure, got success)"; else bad "$1 (harness error rc=$rc)"; tail -n 5 /tmp/o; fi; }
expect_ok(){ if sh -c "$2" >/tmp/o 2>&1; then ok "$1"; else bad "$1"; tail -n 20 /tmp/o; fi; }
git config --global user.email s@t; git config --global user.name smoke; git config --global protocol.file.allow always
git config --global init.defaultBranch main

# --- 1. standards pinned in-repo --------------------------------------------------------------
cp -r "$H" "$T/standards-src"; chmod +x "$T/standards-src"/bin/*; cd "$T/standards-src" && git init -q && echo "RULE=v1" > PIN && git add -A && git add --chmod=+x bin/* && git commit -qm v1
[ "$(git ls-files -s bin/check | cut -c1-6)" = "100755" ] && ok "scripts committed with executable bit" || bad "scripts not executable in git"
V1=$(git rev-parse HEAD)
mkdir "$T/game" && cd "$T/game" && git init -q && cp "$H/templates/gitignore" .gitignore && git submodule -q add "$T/standards-src" standards && git commit -qm init
cd "$T/standards-src" && echo "RULE=v2" > PIN && git commit -qam v2
cd "$T/game" && git submodule update -q
[ "$(git -C standards rev-parse HEAD)" = "$V1" ] && grep -q v1 standards/PIN && ok "standards pinned: upstream change does not reach product repo until SHA bump" || bad "standards pinning"
if grep -rn '\.\./standards' "$H" --include='*.md' --include='*.json' --include='*.yml' | grep -v smoke >/tmp/o; then bad "agent-facing files still reference ../standards"; cat /tmp/o; else ok "no agent-facing file references ../standards"; fi

# --- 2. frontend check + acceptance ---------------------------------------------------------------
mkdir -p web/tests/accept web/src && cd web
cat > package.json << 'J'
{ "name":"web","private":true,"type":"module",
  "scripts":{"budget":"node -e \"process.exit(0)\""},
  "devDependencies":{"vitest":"5.0.2","typescript":"7.0.2","@biomejs/biome":"2.5.14"} }
J
echo '{"compilerOptions":{"strict":true,"noEmit":true,"module":"esnext","target":"es2022","moduleResolution":"bundler","types":[]},"include":["src"]}' > tsconfig.json
echo 'export const add = (a: number, b: number): number => a - b;' > src/math.ts
printf 'import { expect, test } from "vitest";\nimport { add } from "../../src/math";\ntest("T1 adds", () => { expect(add(2, 2)).toBe(4); });\n' > tests/accept/T1.test.ts
npm install --no-audit --no-fund --silent >/dev/null 2>&1 && npx biome check --write . >/dev/null 2>&1; cd ..
git add -A >/dev/null 2>&1; git commit -qm web
expect_fail "check fails when a unit test fails" "$T/game/standards/bin/check"
perl -pi -e 's/a - b/a + b/' web/src/math.ts; git commit -qam fix
if command -v gitleaks >/dev/null; then expect_ok "check passes on the fixed frontend (typecheck, biome, vitest, audit, budget, gitleaks)" "$T/game/standards/bin/check"; else blk "full check (gitleaks not installed)"; fi
printf 'token = "ghp_R7mQ2xLk9vTz4NcW8pHs3JdY6bFa1GeU5oKi"\n' > leak.txt
expect_fail "check fails when an uncommitted secret is added" "$T/game/standards/bin/check"
git add leak.txt && git commit -qm leak
expect_fail "check fails when a secret is committed" "$T/game/standards/bin/check"
git reset -q --hard HEAD~1
command -v cargo >/dev/null && echo "INFO rust available" || blk "Rust steps of check and the instrument (no cargo in this sandbox) — run smoke on a dev machine"

# --- 2b. instrument (verify-lib) and lane creation ------------------------------------------------
mkdir -p scripts/verify
cat > scripts/verify/m0.sh << 'V'
#!/usr/bin/env bash
cd "$(git rev-parse --show-toplevel)" && . standards/bin/verify-lib.sh "$@"
if section web; then
  expect_out "web: T1 passes" 0 'Tests +1 passed' -- sh -c 'cd web && npx --no-install vitest run tests/accept/T1.test.ts'
fi
if section wrongname; then
  expect_out "trap: vitest with a filter that matches nothing" 0 'Tests +[1-9][0-9]* passed' -- sh -c 'cd web && npx --no-install vitest run -t does-not-exist tests/accept/T1.test.ts'
fi
verify_done m0
V
chmod +x scripts/verify/m0.sh
expect_ok   "instrument: real passing test is green" "scripts/verify/m0.sh --section web"
expect_fail "instrument: a filter matching nothing does NOT count as green (asserts positive count)" "scripts/verify/m0.sh --section wrongname"
perl -pi -e 's/a \+ b/a + b + 1/' web/src/math.ts
expect_fail "instrument: red when the code is wrong" "scripts/verify/m0.sh --section web"
git checkout -q -- web/src/math.ts
mkdir "${TMPDIR:-/tmp}/verify.lock.d"; scripts/verify/m0.sh --section web > /tmp/lockout 2>&1; echo "rc=$?" >> /tmp/lockout; rmdir "${TMPDIR:-/tmp}/verify.lock.d"
grep -q "rc=3" /tmp/lockout && grep -q "another verify chain" /tmp/lockout && ok "instrument: second concurrent verify chain is refused" || bad "instrument lock"
git add -A >/dev/null; git commit -qm instrument
out=$(standards/bin/new-lane.sh opus/lock-timing main)
W="$T/game/.worktrees/opus-lock-timing"
[ -d "$W" ] && grep -q '^Branch: opus/lock-timing$' "$W/TASK.md" && [ "$(git -C "$W" branch --show-current)" = "opus/lock-timing" ] && ok "new-lane: worktree + TASK Branch line match the branch" || bad "new-lane"
[ -x "$W/standards/bin/check" ] && ok "new-lane: pinned standards present in the worktree" || bad "new-lane standards in worktree"
git status --porcelain | grep -q worktrees && bad ".worktrees not ignored" || ok ".worktrees/ is git-ignored"
( cd "$W" && npx --no-install vitest run nonexistent/path.test.ts >/dev/null 2>&1 ); [ $? -ne 0 ] && ok "pre-dispatch: a wrong test path exits non-zero in the lane" || bad "wrong test path exited 0 (runner not real)"
git worktree remove --force "$W"

# --- 3. risk classification on the actual diff --------------------------------------------------
C="$T/game/standards/bin/classify-risk"
case_(){ git checkout -q -b "c$1" main 2>/dev/null; sh -c "$2"; git add -A; git commit -qm "c$1"; got=$($C main HEAD 2>/dev/null); [ -z "$got" ] && got="(script error)"; git submodule update -q 2>/dev/null; [ "$got" = "$3" ] && ok "risk: $4 -> $3" || bad "risk: $4 (got $got, want $3)"; git checkout -q main; git submodule update -q; }
git checkout -q main
case_ 1 'mkdir -p docs && echo x > docs/a.md' LOW "docs only"
case_ 2 'mkdir -p web/src/components && echo x > web/src/components/Btn.tsx' LOW "UI component"
case_ 3 'mkdir -p api/src/payouts && echo x > api/src/payouts/mod.rs' HIGH "brand-new module outside known patterns"
case_ 4 'echo x > justfile' HIGH "justfile"
case_ 5 'echo "// x" >> web/package.json' HIGH "frontend manifest"
case_ 6 'git -C standards fetch -q origin && git -C standards checkout -q origin/main' HIGH "standards submodule pointer bump"
case_ 7 'mkdir -p web/src/components && echo x > web/src/components/A.tsx && git add -A && git commit -qm pre && mkdir -p api && git mv web/src/components/A.tsx api/A.tsx' HIGH "rename from UI into api"

# --- 4. risk gate: founder approvals must be on the current head ---------------------------------
G="$T/game/standards/bin/risk-gate"
echo '[{"user":{"login":"fa"},"state":"APPROVED","commit_id":"new"}]' > $T/r1.json
echo '[{"user":{"login":"fa"},"state":"APPROVED","commit_id":"old"}]' > $T/r2.json
echo '[{"user":{"login":"bot"},"state":"APPROVED","commit_id":"new"}]' > $T/r3.json
echo '[{"user":{"login":"fa"},"state":"APPROVED","commit_id":"new"},{"user":{"login":"fb"},"state":"APPROVED","commit_id":"new"}]' > $T/r4.json
echo '[{"user":{"login":"fa"},"state":"APPROVED","commit_id":"new"},{"user":{"login":"fa"},"state":"CHANGES_REQUESTED","commit_id":"new"}]' > $T/r5.json
expect_ok   "gate: HIGH + 1 founder approval on head (game, need 1)" "$G HIGH new $T/r1.json 1 fa,fb"
expect_ok   "gate: reviews file given as a bare relative name, as the workflow does" "cd $T && $G HIGH new r1.json 1 fa,fb"
expect_fail "gate: unreadable reviews file fails closed" "$G HIGH new $T/missing.json 1 fa,fb"
expect_fail "gate: approval on an older commit is stale" "$G HIGH new $T/r2.json 1 fa,fb"
expect_fail "gate: non-founder (bot) approval does not count" "$G HIGH new $T/r3.json 1 fa,fb"
expect_fail "gate: exchange needs 2, one approval blocks" "$G HIGH new $T/r1.json 2 fa,fb"
expect_ok   "gate: exchange with both founders passes" "$G HIGH new $T/r4.json 2 fa,fb"
expect_fail "gate: later 'changes requested' overrides earlier approval" "$G HIGH new $T/r5.json 1 fa,fb"
expect_ok   "gate: LOW needs no founder" "$G LOW new $T/r3.json 1 fa,fb"

# --- 5. reviewer isolation ---------------------------------------------------------------------
BASE=$(git rev-list --max-parents=0 HEAD | tail -1); HEADSHA=$(git rev-parse HEAD)
D=$("$T/game/standards/bin/review-checkout" "$T/game" "$BASE" "$HEADSHA" R1) || D=""
[ -s "$D/.review/diff.patch" ] && [ -z "$(git -C "$D" remote)" ] && ok "review checkout: separate clone, no remotes, diff precomputed" || bad "review checkout"
expect_ok "review checkout starts clean" "$T/game/standards/bin/review-verify-clean $D"
[ -n "$D" ] && echo tamper >> "$D/web/src/math.ts"
expect_fail "tampering by a reviewer is detected" "$T/game/standards/bin/review-verify-clean $D"
grep -q tamper "$T/game/web/src/math.ts" && bad "tampering reached the task repo" || ok "tampering did not reach the task repo"
for f in reviewer.md reviewer-lite.md; do
  grep -q '^tools: Read, Glob, Grep$' "$H/agents/$f" && ok "$f has read-only tools (no Bash/Edit/Write)" || bad "$f tools not read-only"; done

# --- 5b. DeepSeek dispatch refusals (no network call needed) -------------------------------------
DD="$T/game/standards/bin/dispatch-deepseek"
out=$(standards/bin/new-lane.sh ds/ui-button main); W="$T/game/.worktrees/ds-ui-button"
( unset DS_API_KEY; sh -c "$DD $W" ) >/tmp/o 2>&1; [ $? -eq 2 ] && grep -q "DS_API_KEY not set" /tmp/o && ok "dispatch-deepseek: refuses without a key" || bad "dispatch-deepseek key check"
DS_API_KEY=dummy sh -c "$DD $W" >/tmp/o 2>&1; [ $? -eq 2 ] && grep -q "not Risk: LOW" /tmp/o && ok "dispatch-deepseek: refuses a lane not marked Risk: LOW" || bad "dispatch-deepseek risk check"
touch .no-deepseek; git add .no-deepseek; git commit -qm nods; git -C "$W" merge -q main 2>/dev/null
perl -pi -e 's/^Risk: .*/Risk: LOW/' "$W/TASK.md"
DS_API_KEY=dummy sh -c "$DD $W" >/tmp/o 2>&1; [ $? -eq 2 ] && grep -q "never sends code to DeepSeek" /tmp/o && ok "dispatch-deepseek: refuses repos marked .no-deepseek (exchange)" || bad "dispatch-deepseek .no-deepseek"
git worktree remove --force "$W"; git rm -q .no-deepseek; git commit -qm rmnods
grep -rq 'deepseek' "$H/agents" && bad "agent files reference deepseek" || ok "Claude reviewer agents contain no DeepSeek routing"
blk "live DeepSeek run (needs DS_API_KEY + claude CLI) — first LOW lane in G0"

# --- 6. needs a real GitHub org --------------------------------------------------------------------
blk "GitHub rulesets (2 approvals on exchange, stale-approval dismissal, risk-gate as required check) — run the G0 merge-control test PRs in the real org"
blk "OS-level isolation (no Docker socket/credentials in worker containers) — verify on the dev machine"
echo; [ $R -eq 0 ] && echo "SMOKE: all runnable checks passed" || echo "SMOKE: FAILURES above"; exit $R
