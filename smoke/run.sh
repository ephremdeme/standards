#!/bin/sh
# Bootstrap smoke test on disposable local repos. Usage: sh standards/smoke/run.sh (from the workspace; any cwd works)
# Copy of handoff/smoke/run.sh with two fixes: lives inside the standards repo ($H is the standards root), and the
# "red when the code is wrong" control escapes the + in its perl mutation (the original s/a + b/… never matched).
# Prints PASS / FAIL / BLOCKED per claim. GitHub-side controls need a real org and are reported BLOCKED here.
set -u
# User-local toolchains (rustup, cargo-installed tools, gitleaks) so the Rust steps run from any shell (m1.1 O7).
PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"; export PATH
H=$(cd "$(dirname "$0")/.." && pwd); REAL_HOME=$HOME
# The sqlx step of `check` needs a reachable Postgres: take DATABASE_URL from the environment (the instruments and CI
# export it) or from the product repo's git-ignored .env in the current directory, exactly as bin/check does: .env is
# DATA read by bin/read-env, never sourced as shell code (retro review 1).
if [ -z "${DATABASE_URL:-}" ] && [ -r "$PWD/.env" ]; then v=$(sh "$H/bin/read-env" DATABASE_URL "$PWD/.env") && { DATABASE_URL=$v; export DATABASE_URL; }; fi
T=$(mktemp -d); R=0
# Every temp file and the verify lock of the throwaway instrument live under $T: the smoke may itself run inside
# an instrument section that holds ${TMPDIR:-/tmp}/verify.lock.d (m1.1 O7).
TMPDIR=$T; export TMPDIR
# The smoke's git identity and settings live in its own throwaway global config: the user's ~/.gitconfig, or whatever
# GIT_CONFIG_GLOBAL the caller exported, is never written (retro review 16).
GIT_CONFIG_GLOBAL=$T/gitconfig; export GIT_CONFIG_GLOBAL
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }; blk(){ echo "BLOCKED $1"; }
# Expected failures must fail FOR THE RIGHT REASON (retro review 19): exit 1 from our script AND its own diagnostic
# (a required extended regex), not 126/127 (not executable / not found), 2 (usage) or an unrelated failure.
expect_fail(){ [ $# -eq 3 ] || { bad "$1 (smoke bug: expect_fail needs a diagnostic regex)"; return; }
  sh -c "$2" >$T/o 2>&1; rc=$?
  if [ $rc -eq 1 ] && grep -Eq -- "$3" $T/o; then ok "$1"
  elif [ $rc -eq 1 ]; then bad "$1 (failed, but not for its own reason /$3/)"; tail -n 8 $T/o
  elif [ $rc -eq 0 ]; then bad "$1 (expected failure, got success)"
  else bad "$1 (harness error rc=$rc)"; tail -n 5 $T/o; fi; }
expect_ok(){ if sh -c "$2" >$T/o 2>&1; then ok "$1"; else bad "$1"; tail -n 20 $T/o; fi; }
git config --global user.email s@t; git config --global user.name smoke; git config --global protocol.file.allow always
git config --global init.defaultBranch main

# --- 1. standards pinned in-repo --------------------------------------------------------------
# A pinned submodule copy carries a `.git` FILE pointing into the product repo's object store; drop it before `git init`,
# or the smoke's commits would land in the real submodule (m1.1 O7).
cp -r "$H" "$T/standards-src"; rm -rf "$T/standards-src/.git"; chmod +x "$T/standards-src"/bin/*; cd "$T/standards-src" && git init -q && echo "RULE=v1" > PIN && git add -A && git add --chmod=+x bin/* && git commit -qm v1
[ "$(git ls-files -s bin/check | cut -c1-6)" = "100755" ] && ok "scripts committed with executable bit" || bad "scripts not executable in git"
V1=$(git rev-parse HEAD)
mkdir "$T/game" && cd "$T/game" && git init -q && cp "$H/templates/gitignore" .gitignore && git submodule -q add "$T/standards-src" standards && git commit -qm init
cd "$T/standards-src" && echo "RULE=v2" > PIN && git commit -qam v2
cd "$T/game" && git submodule update -q
[ "$(git -C standards rev-parse HEAD)" = "$V1" ] && grep -q v1 standards/PIN && ok "standards pinned: upstream change does not reach product repo until SHA bump" || bad "standards pinning"
if grep -rn '\.\./standards' "$H" --include='*.md' --include='*.json' --include='*.yml' | grep -v smoke >$T/o; then bad "agent-facing files still reference ../standards"; cat $T/o; else ok "no agent-facing file references ../standards"; fi

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
expect_fail "check fails when a unit test fails" "$T/game/standards/bin/check" 'FAIL  web unit tests'
perl -pi -e 's/a - b/a + b/' web/src/math.ts; git commit -qam fix
if command -v gitleaks >/dev/null; then expect_ok "check passes on the fixed frontend (npm ci, typecheck, biome, vitest, audit, budget, gitleaks)" "$T/game/standards/bin/check"; else blk "full check (gitleaks not installed)"; fi
# Retro review 8: check always runs `npm ci` (a pre-existing node_modules is never trusted). A planted marker is gone.
touch web/node_modules/.planted; "$T/game/standards/bin/check" >$T/o 2>&1
grep -q '^PASS  npm ci' $T/o && [ ! -e web/node_modules/.planted ] && ok "check reinstalls node_modules with npm ci even when one exists" || { bad "check reused a pre-existing node_modules"; tail -n 5 $T/o; }
printf 'token = "ghp_R7mQ2xLk9vTz4NcW8pHs3JdY6bFa1GeU5oKi"\n' > leak.txt
expect_fail "check fails when an uncommitted secret is added" "$T/game/standards/bin/check" 'FAIL  secret scan \(uncommitted'
git add leak.txt && git commit -qm leak
expect_fail "check fails when a secret is committed" "$T/game/standards/bin/check" 'FAIL  secret scan \(committed'
git reset -q --hard HEAD~1
# --- 2c. Rust steps of check (m1.1 O7): a minimal crate so fmt, clippy, nextest, sqlx, deny and audit really run
mkdir -p src
printf '[package]\nname = "smoke"\nversion = "0.0.0"\nedition = "2021"\npublish = false\n\n[dependencies]\n' > Cargo.toml
printf 'pub fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn adds() {\n        assert_eq!(super::add(2, 2), 4);\n    }\n}\n' > src/lib.rs
cp "$H/templates/deny.toml" deny.toml
git add -A >/dev/null 2>&1; git commit -qm rust
# sqlx-cli connects even with zero queries: the sqlx step needs the caller's DATABASE_URL (the instruments export
# the dev Postgres; CI exports its service). Without one the Rust steps cannot all run and that is reported, never hidden.
RUST_OK=0
# Labels: only the toolchain case may say "Rust toolchain" (product instruments grep `^BLOCKED Rust toolchain`).
if ! command -v cargo >/dev/null; then blk "Rust toolchain: no cargo on PATH — install rustup user-locally (the crate steps of check and the instrument cannot run)"
elif [ -z "${DATABASE_URL:-}" ]; then blk "database steps of check: export DATABASE_URL to a reachable Postgres, as scripts/verify/*.sh do"
else
  echo "INFO cargo available"
  if "$T/game/standards/bin/check" > "$T/o" 2>&1 && grep -q "PASS  rust tests" "$T/o" && grep -q "PASS  sqlx check" "$T/o"; then ok "check runs the crate steps on a real crate (fmt, clippy, tests, sqlx, deny, audit)"; RUST_OK=1; else bad "crate steps of check"; tail -n 20 "$T/o"; fi
  perl -pi -e 's/a \+ b/a - b/' src/lib.rs; git commit -qam break-rust
  # Red for its own reason: the Rust tests step must be the failing one, not an advisory fetch or anything else.
  if "$T/game/standards/bin/check" > "$T/o" 2>&1; then bad "check passed with a failing crate unit test"
  elif grep -q "FAIL  rust tests" "$T/o"; then ok "check fails when a crate unit test fails (its tests step red)"
  else bad "check failed with a crate unit test broken, but not on its tests step"; tail -n 20 "$T/o"; fi
  git reset -q --hard HEAD~1
fi

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
expect_fail "instrument: a filter matching nothing does NOT count as green (asserts positive count)" "scripts/verify/m0.sh --section wrongname" '\[FAIL\] trap: vitest with a filter that matches nothing'
expect_fail "instrument: an unknown --section runs no checks and is refused (retro review 18)" "scripts/verify/m0.sh --section nonexistent" 'verify: no checks ran \(unknown section\?\)'
perl -pi -e 's/a \+ b/a + b + 1/' web/src/math.ts
expect_fail "instrument: red when the code is wrong" "scripts/verify/m0.sh --section web" '\[FAIL\] web: T1 passes'
git checkout -q -- web/src/math.ts
mkdir "$T/verify.lock.d"; scripts/verify/m0.sh --section web > "$T/lockout" 2>&1; echo "rc=$?" >> "$T/lockout"; rmdir "$T/verify.lock.d"
grep -q "rc=3" "$T/lockout" && grep -q "another verify chain" "$T/lockout" && ok "instrument: second concurrent verify chain is refused" || bad "instrument lock"
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
# case_ <id> <change> <LOW|HIGH> <label> [stderr regex]: the optional regex makes a HIGH red for its OWN reason.
case_(){ git checkout -q -b "c$1" main 2>/dev/null; sh -c "$2"; git add -A; git commit -qm "c$1"; got=$($C main HEAD 2>$T/ce); [ -z "$got" ] && got="(script error)"; git submodule update -q 2>/dev/null
  if [ "$got" = "$3" ] && { [ -z "${5:-}" ] || grep -Eq -- "$5" $T/ce; }; then ok "risk: $4 -> $3"; else bad "risk: $4 (got $got, want $3${5:+ with stderr /$5/})"; cat $T/ce; fi
  git checkout -q main; git submodule update -q; }
git checkout -q main
case_ 1 'mkdir -p docs && echo x > docs/a.md' LOW "docs only"
case_ 2 'mkdir -p web/src/components/player && echo x > web/src/components/player/Btn.tsx' LOW "player UI component"
case_ 2b 'mkdir -p web/src/components/admin && echo x > web/src/components/admin/QuestionCard.tsx' HIGH "admin screen (resolves/voids questions; m1.1 O2)"
case_ 2c 'mkdir -p web/src/components/player/admin && echo x > web/src/components/player/admin/ResolveForm.tsx' HIGH "admin surface nested under a LOW subtree"
case_ 2d 'mkdir -p web/src/i18n/keys && echo x > web/src/i18n/keys/admin.json' HIGH "admin copy (button labels of the admin screens)"
case_ 3 'mkdir -p api/src/payouts && echo x > api/src/payouts/mod.rs' HIGH "brand-new module outside known patterns"
case_ 4 'echo x > justfile' HIGH "justfile"
case_ 5 'echo "// x" >> web/package.json' HIGH "frontend manifest"
case_ 6 'git -C standards fetch -q origin && git -C standards checkout -q origin/main' HIGH "standards submodule pointer bump"
case_ 7 'mkdir -p web/src/components/player && echo x > web/src/components/player/A.tsx && git add -A && git commit -qm pre && mkdir -p api && git mv web/src/components/player/A.tsx api/A.tsx' HIGH "rename from UI into api"
# Retro review 2-4: fail closed, no word splitting or glob expansion, a type-aware and narrower allowlist.
out=$($C DOES_NOT_EXIST HEAD 2>$T/e); rc=$?
[ "$out" = HIGH ] && [ $rc -eq 1 ] && grep -q 'fail closed' $T/e && ok "risk: a diff that cannot be computed (unknown base) -> HIGH, exit 1" || { bad "risk: failed diff (got '$out' rc=$rc, want HIGH rc=1)"; cat $T/e; }
mkdir -p docs && echo x > docs/t.md && printf x > 'x*' && echo x > x.md && printf x > 'NOTES*' && echo x > NOTES.md && git add -A && git commit -qm globs
case_ 8 'echo x >> CLAUDE.md' HIGH "CLAUDE.md edit (no global *.md; instruction files are HIGH)" 'CLAUDE\.md \(agent instruction file\)'
case_ 8b 'mkdir -p docs/sub && echo x > docs/sub/AGENTS.md' HIGH "instruction file nested under docs/" 'docs/sub/AGENTS\.md \(agent instruction file\)'
case_ 8d 'echo x > docs/AGENTS.override.md' HIGH "Codex override instruction file under docs/" 'docs/AGENTS\.override\.md \(agent instruction file\)'
case_ 8c 'echo y >> NOTES.md' LOW "NOTES.md (listed explicitly)"
case_ 9 'ln -s ../justfile docs/link.md' HIGH "symlink added under docs/ (mode 120000)" 'mode 120000'
case_ 9b 'echo x > docs/run.md && chmod +x docs/run.md' HIGH "executable file added under docs/ (mode 100755)" 'mode 100755'
case_ 9c 'rm docs/t.md && ln -s a.md docs/t.md' HIGH "type change file -> symlink under docs/" 'docs/t\.md \(type change\)'
case_ 10 'mkdir -p web/public && echo x > web/public/sw.js' HIGH "web/public/sw.js (only images are LOW there)"
case_ 10b 'mkdir -p web/public && echo x > web/public/logo.png' LOW "image under web/public"
case_ 10c 'mkdir -p web/public && echo x > web/public/logo.svg' HIGH "SVG under web/public (active content)"
case_ 11 'mkdir -p "NOTES.md docs" && echo x > "NOTES.md docs/run.sh"' HIGH "path with a space whose halves look LOW"
case_ 12 'echo x > docs/q\"b.md' HIGH "a path git has to quote (fail closed)" 'a path git had to quote'
case_ 13 'rm -- "x*"' HIGH "deleted file literally named x* next to x.md"
case_ 13b 'rm -- "NOTES*"' HIGH "deleted file literally named NOTES* next to NOTES.md (no glob expansion)"

# --- 4. risk gate: founder approvals must be on the current head ---------------------------------
G="$T/game/standards/bin/risk-gate"
echo '[{"user":{"login":"fa"},"state":"APPROVED","commit_id":"new"}]' > $T/r1.json
echo '[{"user":{"login":"fa"},"state":"APPROVED","commit_id":"old"}]' > $T/r2.json
echo '[{"user":{"login":"bot"},"state":"APPROVED","commit_id":"new"}]' > $T/r3.json
echo '[{"user":{"login":"fa"},"state":"APPROVED","commit_id":"new"},{"user":{"login":"fb"},"state":"APPROVED","commit_id":"new"}]' > $T/r4.json
echo '[{"user":{"login":"fa"},"state":"APPROVED","commit_id":"new"},{"user":{"login":"fa"},"state":"CHANGES_REQUESTED","commit_id":"new"}]' > $T/r5.json
expect_ok   "gate: HIGH + 1 founder approval on head (game, need 1)" "$G HIGH new $T/r1.json 1 fa,fb"
expect_ok   "gate: reviews file given as a bare relative name, as the workflow does" "cd $T && $G HIGH new r1.json 1 fa,fb"
expect_fail "gate: unreadable reviews file fails closed" "$G HIGH new $T/missing.json 1 fa,fb" 'risk-gate: could not count approvals'
expect_fail "gate: approval on an older commit is stale" "$G HIGH new $T/r2.json 1 fa,fb" 'risk-gate: HIGH, only 0/1 founder approvals on current head new'
expect_fail "gate: non-founder (bot) approval does not count" "$G HIGH new $T/r3.json 1 fa,fb" 'risk-gate: HIGH, only 0/1 founder approvals'
expect_fail "gate: exchange needs 2, one approval blocks" "$G HIGH new $T/r1.json 2 fa,fb" 'risk-gate: HIGH, only 1/2 founder approvals'
expect_ok   "gate: exchange with both founders passes" "$G HIGH new $T/r4.json 2 fa,fb"
expect_fail "gate: later 'changes requested' overrides earlier approval" "$G HIGH new $T/r5.json 1 fa,fb" 'risk-gate: HIGH, only 0/1 founder approvals'
expect_ok   "gate: LOW needs no founder" "$G LOW new $T/r3.json 1 fa,fb"

# --- 5. reviewer isolation ---------------------------------------------------------------------
RC="$T/game/standards/bin/review-checkout"; RV="$T/game/standards/bin/review-verify-clean"
BASE=$(git rev-list --max-parents=0 HEAD | tail -1); HEADSHA=$(git rev-parse HEAD)
D=$("$RC" "$T/game" "$BASE" "$HEADSHA" R1) || D=""
[ -s "$D/.review/diff.patch" ] && [ -z "$(git -C "$D" remote)" ] && ok "review checkout: separate clone, no remotes, diff precomputed" || bad "review checkout"
[ -n "$D" ] && [ "$(cat "$D.head" 2>/dev/null)" = "$HEADSHA" ] && [ -s "$D.review.sha256" ] && ok "review checkout: HEAD and the .review/ manifest recorded beside (outside) the checkout" || bad "review checkout records"
expect_ok "review checkout starts clean" "$RV $D | grep -q 'review checkout clean (HEAD $HEADSHA)'"
[ -n "$D" ] && echo tamper >> "$D/web/src/math.ts"
expect_fail "tampering by a reviewer is detected" "$RV $D" 'REVIEWER MODIFIED FILES'
grep -q tamper "$T/game/web/src/math.ts" && bad "tampering reached the task repo" || ok "tampering did not reach the task repo"
# Retro review 7: every way of hiding a change from `git status` is caught.
D2=$("$RC" "$T/game" "$BASE" "$HEADSHA" R2) || D2=""; echo t >> "$D2/web/src/math.ts"; git -C "$D2" commit -qam reviewer-edit
expect_fail "a committed reviewer edit is detected (HEAD moved)" "$RV $D2" 'REVIEWER MOVED HEAD'
D3=$("$RC" "$T/game" "$BASE" "$HEADSHA" R3) || D3=""; git -C "$D3" checkout -q HEAD~1
expect_fail "a checkout to another commit is detected" "$RV $D3" 'REVIEWER MOVED HEAD'
D4=$("$RC" "$T/game" "$BASE" "$HEADSHA" R4) || D4=""; echo '+ looks fine' >> "$D4/.review/diff.patch"
expect_fail "an edited .review/diff.patch is detected" "$RV $D4" 'REVIEW MATERIAL CHANGED'
D5=$("$RC" "$T/game" "$BASE" "$HEADSHA" R5) || D5=""; echo x > "$D5/.env"
expect_fail "a new git-ignored file in the checkout is detected" "$RV $D5" 'REVIEWER MODIFIED FILES'
# Fix round: git errors and hidden edits fail closed.
D6=$("$RC" "$T/game" "$BASE" "$HEADSHA" R6) || D6=""; printf 'garbage' > "$D6/.git/index"
expect_fail "a corrupt index (git status fails) is never reported clean" "$RV $D6" 'REVIEWER MODIFIED FILES: git status failed'
D7=$("$RC" "$T/game" "$BASE" "$HEADSHA" R7) || D7=""; git -C "$D7" update-index --skip-worktree web/src/math.ts; echo hidden >> "$D7/web/src/math.ts"
expect_fail "an edit hidden behind skip-worktree is detected" "$RV $D7" 'REVIEWER MODIFIED FILES: hidden edits'
mkdir "$T/unrelated"; "$RV" "$T/unrelated" >$T/o 2>&1; rc=$?
[ $rc -eq 2 ] && grep -q 'review-verify-clean: refused' $T/o && ! grep -q 'review checkout clean' $T/o && ok "an unrelated directory is refused with exit 2, never reported clean" || { bad "unrelated directory (rc=$rc, want 2)"; cat $T/o; }
# Retro review 16: no rm -rf on a predictable path; the id is validated.
mkdir "$T/review-R9"; echo keep > "$T/review-R9/keep"; D9=$("$RC" "$T/game" "$BASE" "$HEADSHA" R9) || D9=""
[ -f "$T/review-R9/keep" ] && [ -n "$D9" ] && [ "$D9" != "$T/review-R9" ] && ok "review-checkout never deletes a pre-existing review-<id> path (mktemp -d)" || bad "review-checkout reused or deleted a predictable path ($D9)"
"$RC" "$T/game" "$BASE" "$HEADSHA" 'x/../y' >$T/o 2>&1; rc=$?
[ $rc -eq 2 ] && grep -q 'review-checkout: invalid id' $T/o && ok "review-checkout refuses an id outside [A-Za-z0-9_.-] (exit 2)" || { bad "review-checkout id validation (rc=$rc)"; cat $T/o; }
expect_ok "review-verify-clean accepts a relative path to an untouched checkout" "cd $T && $RV ${D9##*/} | grep -q 'review checkout clean (HEAD $HEADSHA)'"
for f in reviewer.md reviewer-lite.md; do
  grep -q '^tools: Read, Glob, Grep$' "$H/agents/$f" && ok "$f has read-only tools (no Bash/Edit/Write)" || bad "$f tools not read-only"; done

# --- 5b. DeepSeek dispatch (no network call: dry runs, or a stub `claude` first on PATH) ----------
DD="$T/game/standards/bin/dispatch-deepseek"
out=$(standards/bin/new-lane.sh ds/ui-button main); W="$T/game/.worktrees/ds-ui-button"
( unset DS_API_KEY; sh -c "$DD $W" ) >$T/o 2>&1; [ $? -eq 2 ] && grep -q "DS_API_KEY not set" $T/o && ok "dispatch-deepseek: refuses without a key" || bad "dispatch-deepseek key check"
DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; [ $? -eq 2 ] && grep -q "not Risk: LOW" $T/o && ok "dispatch-deepseek: refuses a lane not marked Risk: LOW" || bad "dispatch-deepseek risk check"
# The smoke writes the lane's TASK itself: header lines 1-3, and a §5 naming the instrument section.
mktask(){ printf 'Branch: ds/ui-button\nBase: %s\nRisk: %s\n\n## 2. What this is\nsmoke lane\n\n## 5. Verify\n- %s\n\n## 6. Commit subject\nchore: smoke\n' "$(git rev-parse main)" "$1" "$2" > "$W/TASK.md"; }
mktask LOW 'scripts/verify/m0.sh --section web'
# Workspace trust (m1.1 O3): keyed by the REPOSITORY ROOT in ~/.claude.json; a fake HOME holds the state file.
mkdir -p "$T/h"; GR=$(cd "$T/game" && pwd -P)
printf '{"projects":{}}\n' > "$T/h/.claude.json"
HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; [ $? -eq 2 ] && grep -q "not a trusted" $T/o && ok "dispatch-deepseek: refuses when the repository root has no accepted workspace dialog" || bad "dispatch-deepseek workspace-dialog refusal"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$GR" > "$T/h/.claude.json"
HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; [ $? -eq 0 ] && grep -q "checks passed" $T/o && ok "dispatch-deepseek: a lane worktree inherits the accepted dialog of its repository root (dry run)" || { bad "dispatch-deepseek workspace-dialog inheritance"; cat $T/o; }
dd_refused(){ # dd_refused <label> <regex>: a dry run with every other check satisfied must still be refused (exit 2)
  HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; rc=$?
  if [ $rc -eq 2 ] && grep -Eq -- "$2" $T/o; then ok "$1"; else bad "$1 (rc=$rc, want 2 + /$2/)"; tail -n 5 $T/o; fi; }
# Retro review 12: Risk comes from the header (lines 1-3) only.
{ printf 'Branch: ds/ui-button\nBase: %s\nRisk: HIGH\n' "$(git rev-parse main)"; i=4; while [ $i -lt 20 ]; do echo "filler line $i"; i=$((i + 1)); done
  printf 'Risk: LOW\n\n## 5. Verify\n- scripts/verify/m0.sh --section web\n'; } > "$W/TASK.md"
[ "$(sed -n 20p "$W/TASK.md")" = "Risk: LOW" ] || bad "smoke bug: line 20 of the HIGH TASK is not 'Risk: LOW'"
dd_refused "dispatch-deepseek: refuses 'Risk: LOW' on line 20 of a HIGH TASK (header only)" 'not Risk: LOW'
mktask LOW 'scripts/verify/mN.sh --section <lane>'
dd_refused "dispatch-deepseek: refuses a TASK whose §5 names no instrument section" 'names no instrument section'
mktask LOW 'scripts/verify/m0.sh --section web'
# Retro review 13: claude gets an empty environment plus an allowlist; the dry run lists the names (never values).
LEAK_PROBE=1 HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; rc=$?
envline=$(grep 'environment passed to claude' $T/o)
[ $rc -eq 0 ] && printf '%s' "$envline" | grep -qw ANTHROPIC_AUTH_TOKEN && printf '%s' "$envline" | grep -qw HOME && ! printf '%s' "$envline" | grep -qw -e LEAK_PROBE -e DS_API_KEY -e GIT_CONFIG_GLOBAL && ! grep -q dummy $T/o \
  && ok "dispatch-deepseek: an exported LEAK_PROBE (and DS_API_KEY itself) never reaches claude; names listed, values not" || { bad "dispatch-deepseek environment allowlist"; cat $T/o; }
# Retro review 14: the run's real outcome decides. A stub `claude` first on PATH stands in for the model.
mkdir -p "$T/stub"
for f in .cargo .rustup .npm .local; do [ -e "$REAL_HOME/$f" ] && ln -s "$REAL_HOME/$f" "$T/h/$f"; done
[ -n "${DATABASE_URL:-}" ] && printf 'DATABASE_URL=%s\n' "$DATABASE_URL" > "$W/.env"
WB=$(git -C "$W" rev-parse HEAD)
dd_outcome(){ # dd_outcome <label> <stub body> <rc> <regex>
  printf '#!/bin/sh\n%s\n' "$2" > "$T/stub/claude"; chmod +x "$T/stub/claude"
  HOME=$T/h DS_API_KEY=dummy PATH="$T/stub:$PATH" sh -c "$DD $W" >$T/o 2>&1; rc=$?
  if [ $rc -eq "$3" ] && grep -Eq -- "$4" $T/o; then ok "$1"; else bad "$1 (rc=$rc, want $3 + /$4/)"; tail -n 8 $T/o; fi
  git -C "$W" reset -q --hard "$WB"; rm -f "$W/dirty.txt"; }
SG='git -c user.name=stub -c user.email=stub@t'
dd_outcome "dispatch-deepseek: a failing claude run is a failure, named" 'exit 1' 1 'claude failed \(rc=1\)'
dd_outcome "dispatch-deepseek: a run that commits nothing is a failure, named" 'exit 0' 1 'dispatch-deepseek: no commit'
dd_outcome "dispatch-deepseek: a run that leaves the tree dirty is a failure, named" "$SG commit -q --allow-empty -m stub && echo x > dirty.txt" 1 'dispatch-deepseek: dirty tree'
dd_outcome "dispatch-deepseek: a run that commits a trivial instrument section is refused, named" "printf 'if section web; then expect_out trivial 0 . -- true; fi\n' >> scripts/verify/m0.sh && $SG commit -qam judge" 1 'dispatch-deepseek: lane changed its own judge'
dd_outcome "dispatch-deepseek: a commit that breaks check is a failure, named" "perl -pi -e 's/a \\+ b/a - b/' web/src/math.ts && $SG commit -qam break" 1 'dispatch-deepseek: check failed'
grep -q '^FAIL  web unit tests' "$W/.lane-check.log" && ok "dispatch-deepseek: ... and check failed on the broken unit test (its own reason)" || { bad "dispatch-deepseek check failure was not the broken unit test"; grep -E '^(FAIL|BLOCKED)' "$W/.lane-check.log"; }
if [ $RUST_OK -eq 1 ]; then
  mktask LOW 'scripts/verify/m0.sh --section wrongname'
  dd_outcome "dispatch-deepseek: a green check with a red instrument section is a failure, named" "echo x > stub.md && git add stub.md && $SG commit -qm docs" 1 'dispatch-deepseek: instrument section failed'
  mktask LOW 'scripts/verify/m0.sh --section web'
  dd_outcome "dispatch-deepseek: commit + clean tree + green check + green section -> exit 0" "echo x > stub.md && git add stub.md && $SG commit -qm docs" 0 'dispatch-deepseek: OK'
else blk "dispatch-deepseek instrument-section outcomes: needs the full check green on the smoke crate (cargo + DATABASE_URL)"; fi
touch .no-deepseek; git add .no-deepseek; git commit -qm nods; git -C "$W" merge -q main 2>/dev/null
dd_refused "dispatch-deepseek: refuses repos marked .no-deepseek (exchange)" 'never sends code to DeepSeek'
# Retro review 12: the marker is judged on the PRIMARY checkout's committed tree, not on the lane's files.
git -C "$W" rm -q .no-deepseek; git -C "$W" commit -qm drop-marker
dd_refused "dispatch-deepseek: refuses when the lane deleted .no-deepseek but the primary HEAD has it" 'never sends code to DeepSeek'
git worktree remove --force "$W"; git rm -q .no-deepseek; git commit -qm rmnods
grep -rq 'deepseek' "$H/agents" && bad "agent files reference deepseek" || ok "Claude reviewer agents contain no DeepSeek routing"
blk "live DeepSeek run (needs DS_API_KEY + claude CLI) — first LOW lane in G0"

# --- 6. needs a real GitHub org --------------------------------------------------------------------
blk "GitHub rulesets (2 approvals on exchange, stale-approval dismissal, risk-gate as required check) — run the G0 merge-control test PRs in the real org"
blk "reusable risk-gate and CI workflows (pinned standards checkout, gitleaks CLI, web job) — run on a real PR in the org"
blk "OS-level isolation (no Docker socket/credentials in worker containers) — verify on the dev machine"
echo; [ $R -eq 0 ] && echo "SMOKE: all runnable checks passed" || echo "SMOKE: FAILURES above"; exit $R
