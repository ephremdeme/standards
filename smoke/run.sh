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
# The build environment of a caller (an instrument section or with-build-lock exports the product repo's shared
# CARGO_TARGET_DIR, its BUILD_LOCK_TOKEN and RUSTC_WRAPPER) never reaches the smoke's own builds: they would build into,
# and re-stamp, the caller's shared target (review round of opus/process-amendments).
SMOKE_OUTER_TARGET=${CARGO_TARGET_DIR:-}; SMOKE_OUTER_STAMP=$(cat "${SMOKE_OUTER_TARGET:-/nonexistent}/.standards-worktree" 2>/dev/null || echo none)
unset CARGO_TARGET_DIR BUILD_LOCK_TOKEN RUSTC_WRAPPER
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
# Expected successes that must also SAY the right thing (an informational gate always exits 0, so exit 0 alone proves
# nothing): exit 0 AND every given extended regex found in the output; a red names the rc and each missing regex.
expect_ok_out(){ [ $# -ge 3 ] || { bad "$1 (smoke bug: expect_ok_out needs at least one regex)"; return; }
  eo_l=$1; eo_c=$2; shift 2; sh -c "$eo_c" >$T/o 2>&1; rc=$?; eo_miss=""
  for eo_re in "$@"; do grep -Eq -- "$eo_re" $T/o || eo_miss="$eo_miss /$eo_re/"; done
  if [ $rc -eq 0 ] && [ -z "$eo_miss" ]; then ok "$eo_l"; else bad "$eo_l (rc=$rc, want 0${eo_miss:+; missing$eo_miss})"; tail -n 8 $T/o; fi; }
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
# C6: lane checks match the lane. `--only web` skips the Rust block and runs the web steps; `--only rust` skips the
# front end (run with an empty HOME and a PATH without cargo, so nothing is built: the Rust block is BLOCKED there).
if command -v gitleaks >/dev/null; then
  expect_ok_out "check --only web: the Rust block is skipped, the web steps run" "$T/game/standards/bin/check --only web" '^SKIP  rust \(--only web\)$' '^PASS  web unit tests$'
else blk "check --only web (gitleaks not installed)"; fi
mkdir -p "$T/nohome"; env HOME="$T/nohome" PATH=/usr/bin:/bin "$T/game/standards/bin/check" --only rust > "$T/o" 2>&1; rc=$?
if [ $rc -eq 1 ] && grep -q '^SKIP  frontend (--only rust)$' "$T/o" && ! grep -q 'web unit tests' "$T/o"; then ok "check --only rust: the front-end block is skipped"
else bad "check --only rust: the front-end block is skipped (rc=$rc, want 1 + SKIP  frontend (--only rust))"; tail -n 8 "$T/o"; fi
"$T/game/standards/bin/check" --only bogus > "$T/o" 2>&1; rc=$?
if [ $rc -eq 2 ] && grep -q '^check: usage: check \[--only rust|web|all\]$' "$T/o"; then ok "control: check --only bogus -> usage, exit 2"
else bad "control: check --only bogus -> usage, exit 2 (rc=$rc)"; tail -n 4 "$T/o"; fi
# C5 shared target: cargo keys workspace crates by their path relative to the workspace root and trusts mtimes, so a
# raw shared CARGO_TARGET_DIR runs another worktree's compiled tests as this one's; with-build-lock cleans the workspace
# crates when the building worktree changes. Test `t` passes in A and fails in B.
if command -v cargo >/dev/null; then
  HZ="$T/hz"; git init -q "$HZ"; mkdir -p "$HZ/src"; printf '.worktrees/\n/target/\n' > "$HZ/.gitignore"
  printf '[package]\nname = "hz"\nversion = "0.0.0"\nedition = "2021"\npublish = false\n\n[dependencies]\n' > "$HZ/Cargo.toml"
  printf 'pub fn v() -> i32 {\n    1\n}\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn t() {\n        assert_eq!(super::v(), 1, "hazard-assert");\n    }\n}\n' > "$HZ/src/lib.rs"
  git -C "$HZ" add -A; git -C "$HZ" commit -qm a; HZR=$(cd "$HZ" && pwd -P)
  git -C "$HZ" worktree add -q "$HZ/.worktrees/a" -b la main; git -C "$HZ" worktree add -q "$HZ/.worktrees/b" -b lb main
  HA="$HZR/.worktrees/a"; HB="$HZR/.worktrees/b"
  perl -pi -e 's/^    1$/    2/' "$HB/src/lib.rs"; git -C "$HB" commit -qam b
  WBL="$T/game/standards/bin/with-build-lock"
  if (cd "$HA" && "$WBL" cargo test -q) > "$T/o" 2>&1; then ok "shared target: with-build-lock cargo test is green in worktree A"; else bad "shared target: with-build-lock cargo test in A"; tail -n 8 "$T/o"; fi
  touch -d '2000-01-01 00:00:00' "$HB/src/lib.rs" "$HB/Cargo.toml"
  if (cd "$HB" && CARGO_TARGET_DIR="$HZR/target/shared" cargo test -q) > "$T/o" 2>&1; then ok "control: a raw shared CARGO_TARGET_DIR runs A's compiled test green for B (the hazard is real)"
  else bad "control: a raw shared CARGO_TARGET_DIR did not reproduce the hazard (B's own test ran)"; tail -n 8 "$T/o"; fi
  (cd "$HB" && "$WBL" cargo test -q) > "$T/o" 2>&1; rc=$?
  if [ $rc -ne 0 ] && grep -q 'hazard-assert' "$T/o"; then ok "guard: with-build-lock cargo test in B is red (B's own test ran after the switch clean)"
  else bad "guard: with-build-lock cargo test in B (rc=$rc, want non-zero + B's assertion 'hazard-assert')"; tail -n 8 "$T/o"; fi
  # Every profile is cleaned on a switch, not only dev: A's release test binary must not run as B's.
  if (cd "$HA" && "$WBL" cargo test --release -q) > "$T/o" 2>&1; then ok "shared target: with-build-lock cargo test --release is green in worktree A"; else bad "shared target: release build in A"; tail -n 8 "$T/o"; fi
  touch -d '2000-01-01 00:00:00' "$HB/src/lib.rs" "$HB/Cargo.toml"
  (cd "$HB" && "$WBL" cargo test --release -q) > "$T/o" 2>&1; rc=$?
  if [ $rc -ne 0 ] && grep -q 'hazard-assert' "$T/o"; then ok "guard: with-build-lock cargo test --release in B is red (the release profile was cleaned on the switch)"
  else bad "guard: with-build-lock cargo test --release in B ran A's release binary (rc=$rc)"; tail -n 8 "$T/o"; fi
  if [ -n "$SMOKE_OUTER_TARGET" ]; then
    now=$(cat "$SMOKE_OUTER_TARGET/.standards-worktree" 2>/dev/null || echo none)
    if [ "$now" = "$SMOKE_OUTER_STAMP" ] && ! ls -d "$SMOKE_OUTER_TARGET"/*/.fingerprint/hz-* >/dev/null 2>&1; then ok "the caller's exported CARGO_TARGET_DIR was neither built into nor re-stamped"
    else bad "the smoke built into or re-stamped the caller's CARGO_TARGET_DIR ($SMOKE_OUTER_TARGET)"; fi
  fi
else blk "shared-target hazard and its guard (needs cargo)"; fi

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
# The stderr lines are risk-gate's input (it prints them as the HIGH list): exactly one `high: <path>…` line per path.
git checkout -q -b c14 main; mkdir -p api/src/payouts web/src/components/admin
echo x > api/src/payouts/mod.rs; echo x > web/src/components/admin/QuestionCard.tsx; git add -A; git commit -qm c14
got=$($C main HEAD 2>$T/ce); nh=$(grep -c '^high: ' $T/ce)
if [ "$got" = HIGH ] && grep -q '^high: api/src/payouts/mod\.rs$' $T/ce && grep -q '^high: web/src/components/admin/QuestionCard\.tsx (admin surface)$' $T/ce && [ "$nh" -eq 2 ]; then
  ok "classify: one high: line per HIGH path on stderr (the gate's input contract)"
else bad "classify: one high: line per HIGH path on stderr (got $got, $nh high: lines, want HIGH and 2)"; cat $T/ce; fi
git checkout -q main

# --- 4. risk gate: informational — lists HIGH paths, never blocks (solo developer, 2026-10-02) ---
G="$T/game/standards/bin/risk-gate"; GH=0123456789abcdef0123456789abcdef01234567
# Reasons files in classify-risk's stderr format: one `high: <path> [(<reason>)]` line per HIGH path.
printf 'high: api/src/payouts/mod.rs\nhigh: web/src/components/admin/QuestionCard.tsx (admin surface)\n' > $T/g2.txt
: > $T/g0.txt; rm -f $T/summary.md $T/missing.txt
expect_ok_out "gate: HIGH PR → summary lists the HIGH paths, exit 0" "$G HIGH $GH $T/g2.txt" \
  'review these paths before merging \(2 paths' '^  api/src/payouts/mod\.rs$' '^  web/src/components/admin/QuestionCard\.tsx \(admin surface\)$'
expect_ok_out "gate: LOW PR → exit 0, no list" "$G LOW $GH $T/g0.txt" "^risk-gate: LOW — no HIGH paths in $GH\$"
expect_ok_out "gate: unreadable reasons file still exits 0 and says so" "$G HIGH $GH $T/missing.txt" \
  "^risk-gate: HIGH — reasons unavailable, review the whole diff of $GH\$" '^risk-gate: informational'
expect_ok_out "gate: GITHUB_STEP_SUMMARY receives the list" "GITHUB_STEP_SUMMARY=$T/summary.md $G HIGH $GH $T/g2.txt >/dev/null && cat $T/summary.md" \
  '^### risk-gate$' '^- api/src/payouts/mod\.rs$' '^- web/src/components/admin/QuestionCard\.tsx \(admin surface\)$'
expect_ok_out "gate: empty level with a HIGH reasons file prints HIGH" "$G '' $GH $T/g2.txt" \
  "^risk-gate: HIGH — reasons unavailable, review the whole diff of $GH\$" "^risk-gate: unknown level '' treated as HIGH\$"
expect_ok_out "gate: LOW contradicted by high: lines prints HIGH with the note" "$G LOW $GH $T/g2.txt" \
  '^risk-gate: HIGH — ' '^risk-gate: level LOW contradicts the reasons file' '^  api/src/payouts/mod\.rs$'

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
# Dispatch runs task-lint, whose disk floor (15 GB) reads `df -Pk`: a stub df reporting 100 GB goes first on PATH for
# every dispatch case; one case puts a 7 GB stub first instead (C5). No bypass variable exists.
mkdir -p "$T/df100" "$T/df7"
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/stub 209715200 104857600 104857600 50%% /"\n' > "$T/df100/df"
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/stub 209715200 202375168 7340032 97%% /"\n' > "$T/df7/df"
chmod +x "$T/df100/df" "$T/df7/df"; PATH="$T/df100:$PATH"; export PATH
out=$(standards/bin/new-lane.sh ds/ui-button main); W="$T/game/.worktrees/ds-ui-button"
( unset DS_API_KEY; sh -c "$DD $W" ) >$T/o 2>&1; [ $? -eq 2 ] && grep -q "DS_API_KEY not set" $T/o && ok "dispatch-deepseek: refuses without a key" || bad "dispatch-deepseek key check"
DS_API_KEY=dummy sh -c "$DD $W medium" >$T/o 2>&1; [ $? -eq 2 ] && grep -q "effort must be max or high, not 'medium'" $T/o && ok "dispatch-deepseek: refuses an effort other than max or high" || bad "dispatch-deepseek effort check"
grep -q '^wt=.*effort=\${2:-max}$' "$DD" && grep -q 'EFFORT_LEVEL="\${DS_EFFORT:-max}"' "$T/game/standards/templates/deepseek.sh" && ok "dispatch-deepseek and templates/deepseek.sh default to max effort" || bad "DeepSeek effort default is not max in both entry points"
DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; [ $? -eq 2 ] && grep -q "not Risk: LOW" $T/o && ok "dispatch-deepseek: refuses a lane not marked Risk: LOW" || bad "dispatch-deepseek risk check"
# The smoke writes the lane's TASK itself: header lines 1-3 with a full base sha, headings 1-7, the owned-paths block in
# §3 and a §5 naming the instrument section (task-lint, C7).
# mktask <risk> <§5 line> [<owned paths, one per line; NONE = no block; default web/src/components/>] [<extra line, in
# §3 outside the block and in §4>]
mktask(){ { printf 'Branch: ds/ui-button\nBase: %s\nRisk: %s\n\n## 1. Read first\n- nothing\n\n## 2. What this is\nsmoke lane\n\n## 3. Files you own\n%s\n' "$(git rev-parse main)" "$1" "${4:-}"
  if [ "${3:-web/src/components/}" != NONE ]; then printf '```owned\n%s\n```\n' "${3:-web/src/components/}"; fi
  printf '\n## 4. Hard rules\n- none\n%s\n\n## 5. Verify\n- %s\n\n## 6. Commit subject\nchore: smoke\n\n## 7. Binding facts\n- none\n' "${4:-}" "$2"; } > "$W/TASK.md"; }
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
# Founder override D-073 (2026-10-02): a HIGH TASK goes to DeepSeek only with DISPATCH_ALLOW_HIGH=1, never when its
# §3 owns an admin surface (m1.1 O2). mktaskh <risk> <§3 path> writes a TASK whose owned-paths block holds that path.
mktaskh(){ mktask "$1" 'scripts/verify/m0.sh --section web' "$2"; }
mktaskh HIGH 'web/src/components/player/Btn.tsx'
dd_refused "dispatch: HIGH TASK refused without the override" 'not Risk: LOW'
DISPATCH_ALLOW_HIGH=1 HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; rc=$?
if [ $rc -eq 0 ] && grep -q '^dispatch-deepseek: HIGH lane sent to DeepSeek under founder decision D-073 (Opus contract + Opus review mandatory)$' $T/o && grep -q 'checks passed' $T/o; then
  ok "dispatch: HIGH TASK accepted with DISPATCH_ALLOW_HIGH=1 (dry run)"
else bad "dispatch: HIGH TASK accepted with DISPATCH_ALLOW_HIGH=1 (dry run) (rc=$rc, want 0 + the D-073 line)"; tail -n 5 $T/o; fi
mktaskh HIGH 'web/src/components/admin/QuestionCard.tsx'
DISPATCH_ALLOW_HIGH=1 HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; rc=$?
if [ $rc -eq 2 ] && grep -q 'admin surface in TASK §3 cannot go to DeepSeek even with DISPATCH_ALLOW_HIGH' $T/o; then
  ok "dispatch: HIGH TASK owning an admin path refused even with the override"
else bad "dispatch: HIGH TASK owning an admin path refused even with the override (rc=$rc, want 2 + /admin surface in TASK §3/)"; tail -n 5 $T/o; fi
dd_refused_env(){ # dd_refused_env <label> <NAME=value> <regex>: like dd_refused with one extra variable set
  env "$2" HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; rc=$?
  if [ $rc -eq 2 ] && grep -Eq -- "$3" $T/o; then ok "$1"; else bad "$1 (rc=$rc, want 2 + /$3/)"; tail -n 5 $T/o; fi; }
mktask HIGH 'scripts/verify/m0.sh --section web' NONE
dd_refused_env "dispatch: HIGH TASK without an owned-paths block refused by task-lint even with the override" DISPATCH_ALLOW_HIGH=1 '^task-lint: FAIL owned: TASK §3 has no owned-paths block'
grep -q '^dispatch-deepseek: refused — task-lint failed (see above)$' $T/o && ok "dispatch: ... with the dispatch refusal line naming task-lint" || { bad "dispatch: task-lint refusal line missing"; tail -n 5 $T/o; }
# NOTES-19 defect 2: the admin refusal reads the owned-paths block only; a §4 "never touch" line is not ownership.
mktask LOW 'scripts/verify/m0.sh --section web' 'web/src/components/' '- never touch web/src/admin/'
HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; rc=$?
if [ $rc -eq 0 ] && grep -q 'checks passed' $T/o; then ok "dispatch: defect 2: a 'never touch web/src/admin/' line (§3 prose and §4) is not admin ownership (dry run accepted)"
else bad "dispatch: defect 2: a 'never touch web/src/admin/' line refused the lane (rc=$rc)"; tail -n 5 $T/o; fi
# C6: the post-run check is scoped by the block's kind (owned-paths --kind).
dd_kind(){ # dd_kind <owned lines> <kind>
  mktask LOW 'scripts/verify/m0.sh --section web' "$1"
  HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; rc=$?
  if [ $rc -eq 0 ] && grep -q "^dispatch-deepseek: checks after the run: check --only $2, scripts/verify/m0.sh --section web\$" $T/o && grep -q '^dispatch-deepseek: instrument after the run: scripts/verify/m0.sh --section web$' $T/o; then ok "dispatch: a $2 block -> check --only $2 after the run (dry run)"
  else bad "dispatch: a $2 block -> check --only $2 after the run (rc=$rc)"; tail -n 5 $T/o; fi; }
dd_kind 'web/src/components/' web
dd_kind 'api/src/users/' rust
dd_kind "$(printf 'web/src/components/\napi/src/users/')" all
# C5 disk floor, enforced by task-lint before every dispatch: a 7 GB stub df refuses the lane.
mktask LOW 'scripts/verify/m0.sh --section web'
env PATH="$T/df7:$PATH" HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; rc=$?
if [ $rc -eq 2 ] && grep -q '^task-lint: FAIL disk: 7.0 GB free on the filesystem of .*, below the 15 GB floor' $T/o && grep -q '^dispatch-deepseek: refused — task-lint failed (see above)$' $T/o; then ok "control: dispatch below the 15 GB disk floor is refused by task-lint (exit 2)"
else bad "control: dispatch below the 15 GB disk floor (rc=$rc, want 2 + task-lint: FAIL disk)"; tail -n 5 $T/o; fi
mktaskh HIGH 'web/src/components/player/Btn.tsx'
dd_refused_env "dispatch: DISPATCH_ALLOW_HIGH=true is not the override (exactly 1)" DISPATCH_ALLOW_HIGH=true 'not Risk: LOW'
dd_refused_env "dispatch: DISPATCH_ALLOW_HIGH=yes is not the override (exactly 1)" DISPATCH_ALLOW_HIGH=yes 'not Risk: LOW'
mktaskh LOW 'web/src/components/admin/QuestionCard.tsx'
dd_refused "dispatch: LOW TASK owning an admin path refused" 'admin surface in TASK §3'
mktask LOW 'scripts/verify/m0.sh --section web'
# Retro review 13: claude gets an empty environment plus an allowlist; the dry run lists the names (never values).
LEAK_PROBE=1 HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; rc=$?
envline=$(grep 'environment passed to claude' $T/o)
[ $rc -eq 0 ] && printf '%s' "$envline" | grep -qw ANTHROPIC_AUTH_TOKEN && printf '%s' "$envline" | grep -qw HOME && ! printf '%s' "$envline" | grep -qw -e LEAK_PROBE -e DS_API_KEY -e GIT_CONFIG_GLOBAL && ! grep -q dummy $T/o \
  && ok "dispatch-deepseek: an exported LEAK_PROBE (and DS_API_KEY itself) never reaches claude; names listed, values not" || { bad "dispatch-deepseek environment allowlist"; cat $T/o; }
BUILD_LOCK_TOKEN=probe HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh -c "$DD $W" >$T/o 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q 'environment passed to claude' $T/o && ! grep 'environment passed to claude' $T/o | grep -qw BUILD_LOCK_TOKEN \
  && ok "dispatch-deepseek: BUILD_LOCK_TOKEN goes to the judges only, never to claude (names list unchanged)" || { bad "dispatch-deepseek: BUILD_LOCK_TOKEN in claude's environment"; cat $T/o; }
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
# §3 owns a parent directory, so the early text check passes; the committed diff is what is judged (review blocker).
mktaskh LOW 'web/src/components/'
dd_outcome "dispatch: a lane that commits an admin file under a parent-directory ownership is a failure, named" \
  "mkdir -p web/src/components/admin && echo x > web/src/components/admin/X.tsx && git add web/src/components/admin/X.tsx && $SG commit -qm admin" 1 'dispatch-deepseek: lane changed an admin surface'
mktask LOW 'scripts/verify/m0.sh --section web'
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

# --- 5d. DeepSeek standards-docs lanes (docs/07 §1, DeepSeek scope 3): the standards repo, known by its root commit -----
# A clone of $H keeps the real root commit; the working-tree bytes of $H's TRACKED files are committed on top, so these
# cases judge the bytes being smoked, and an untracked file of the caller's checkout (a lane's TASK.md) never enters the
# fixture. A fixture doc linking to docs/07 is committed too (the deletion case). Prose-only allow-list before and after
# the run; the judges are TASK §5's tests/*.t.sh and tests/docs.t.sh, taken from the pre-run commit.
SD="$T/std"; SW="$T/std-wt"; SROOT=4e78d67036ddafaa07c9dac9bb74249c4dd2e895
if git clone -q "$H" "$SD" >/dev/null 2>&1 && git -C "$SD" rev-list --max-parents=0 HEAD | grep -qx "$SROOT"; then
  git -C "$H" ls-files -z | (cd "$H" && tar --null -T - -cf -) | (cd "$SD" && tar -xf -)
  printf '# Links\nSee [the harness](07-harness.md).\n' > "$SD/docs/links.md"
  git -C "$SD" add -A >/dev/null 2>&1; git -C "$SD" commit -qm "smoke: the working tree under test" --allow-empty
  git -C "$SD" worktree add -q "$SW" -b ds/docs-lane; SDR=$(cd "$SD" && pwd -P); SWB=$(git -C "$SW" rev-parse HEAD)
  printf '{"projects":{"%s":{"hasTrustDialogAccepted":true},"%s":{"hasTrustDialogAccepted":true}}}\n' "${GR:-/nonexistent}" "$SDR" > "$T/h/.claude.json"
  mkstd(){ # mkstd <owned lines> <§5 line>: a standards lane TASK (header, headings 1-7, the owned-paths block)
    printf 'Branch: ds/docs-lane\nBase: %s\nRisk: LOW\n\n## 1. Read first\n- docs/07-harness.md\n\n## 2. What this is\nsmoke docs lane\n\n## 3. Files you own\n```owned\n%s\n```\n\n## 4. Hard rules\n- none\n\n## 5. Verify\n- %s\n\n## 6. Commit subject\ndocs: smoke\n\n## 7. Binding facts\n- none\n' "$SWB" "$1" "$2" > "$SW/TASK.md"; }
  sd_run(){ # sd_run <label> <rc> <dry: 1|0> <regex>...: exit code and every regex; a dry run or a stub claude run
    sd_l=$1; sd_rc=$2; sd_dry=$3; shift 3
    HOME=$T/h DS_API_KEY=dummy DISPATCH_DRY_RUN=$sd_dry PATH="$T/stub:$PATH" sh -c "${SD_DD:-$DD} $SW" >$T/o 2>&1; rc=$?; sd_miss=""
    for sd_re in "$@"; do grep -Eq -- "$sd_re" $T/o || sd_miss="$sd_miss /$sd_re/"; done
    if [ $rc -eq "$sd_rc" ] && [ -z "$sd_miss" ]; then ok "$sd_l"; else bad "$sd_l (rc=$rc, want $sd_rc${sd_miss:+; missing$sd_miss})"; tail -n 8 $T/o; fi
    git -C "$SW" reset -q --hard "$SWB"; }
  ALLOW='outside the standards docs allow-list'
  mkstd "$(printf 'docs/07-harness.md\nCHANGELOG.md\ntemplates/milestone.md')" 'sh tests/owned-paths.t.sh'
  sd_run "standards: a docs lane (docs/07, CHANGELOG.md, templates/milestone.md; judge sh tests/owned-paths.t.sh) is accepted (dry run)" 0 1 \
    '^dispatch-deepseek: standards docs lane \(root 4e78d67\)' \
    '^dispatch-deepseek: judges after the run \(from the pre-run commit\): sh tests/owned-paths\.t\.sh, sh tests/docs\.t\.sh --judge <every docs/\*\*/\*\.md and README\.md>$' \
    '^dispatch-deepseek: checks passed \(dry run, nothing dispatched\)$'
  mkstd 'templates/X.MD' 'sh tests/owned-paths.t.sh'
  sd_run "standards: case variant templates/X.MD (one segment, .md suffix in any case) is accepted (dry run)" 0 1 '^dispatch-deepseek: checks passed \(dry run, nothing dispatched\)$'
  SD_DD="$SW/bin/dispatch-deepseek"; mkstd 'docs/07-harness.md' 'sh tests/owned-paths.t.sh'
  sd_run "control: the lane's own copy of the dispatcher (inside the lane worktree) is refused" 2 1 "^dispatch-deepseek: refused — this dispatcher lies inside the lane worktree"
  SD_DD=""
  sd_own(){ # sd_own <owned path>: refused before dispatch, the message naming exactly that path
    mkstd "$1" 'sh tests/owned-paths.t.sh'; sd_re=$(printf '%s' "$1" | sed 's/[].[*^$\\+?(){}|]/\\&/g')
    sd_run "control: standards: a lane owning $1 is refused before dispatch" 2 1 "^dispatch-deepseek: refused — TASK §3 owns $sd_re, $ALLOW"; }
  for p in 'docs/0*' 'templates/*.md' 'templates/a/b.md' 'CHANGELOG.md*' 'README.md*' 'Docs/x.md' 'DOCS/05-domain-rules.md' \
    'docs/CLAUDE.md' 'templates/CLAUDE.md' 'docs/sub/AGENTS.override.md' 'docs/.gitattributes' 'docs/.claude/x.md' \
    'docs//05-domain-rules.md' 'docs/./05-domain-rules.md'; do sd_own "$p"; done
  mkstd 'bin/x' 'sh tests/owned-paths.t.sh'
  sd_run "control: standards: a lane owning bin/x is refused before dispatch" 2 1 "^dispatch-deepseek: refused — TASK §3 owns bin/x, $ALLOW"
  mkstd 'docs/05-domain-rules.md' 'sh tests/owned-paths.t.sh'
  sd_run "control: standards: a lane owning docs/05-domain-rules.md is refused before dispatch" 2 1 "^dispatch-deepseek: refused — TASK §3 owns docs/05-domain-rules\.md, $ALLOW"
  mkstd 'templates/deepseek.sh' 'sh tests/owned-paths.t.sh'
  sd_run "control: standards: a lane owning templates/deepseek.sh is refused before dispatch" 2 1 "^dispatch-deepseek: refused — TASK §3 owns templates/deepseek\.sh, $ALLOW"
  mkstd 'templates/claude-settings.json' 'sh tests/owned-paths.t.sh'
  sd_run "control: standards: a lane owning templates/claude-settings.json (not prose) is refused before dispatch" 2 1 "^dispatch-deepseek: refused — TASK §3 owns templates/claude-settings\.json, $ALLOW"
  mkstd 'docs/' 'sh tests/owned-paths.t.sh'
  sd_run "control: standards: a lane owning all of docs/ (docs/05 included) is refused before dispatch" 2 1 "^dispatch-deepseek: refused — TASK §3 owns docs/\*, $ALLOW"
  mkstd 'docs/07-harness.md' 'scripts/verify/m0.sh --section web'
  sd_run "control: standards: a §5 naming an instrument section instead of a judge is refused" 2 1 '^dispatch-deepseek: refused — TASK §5 names no judge \(sh tests/<name>\.t\.sh\)'
  mkstd 'docs/07-harness.md' 'sh tests/nope.t.sh'
  sd_run "control: standards: a §5 judge that does not exist at HEAD is refused" 2 1 "^dispatch-deepseek: refused — TASK §5 judge tests/nope\.t\.sh does not exist at $SWB\$"
  # After the run (a stub claude first on PATH stands in for the model).
  mkstd "$(printf 'docs/07-harness.md\nCHANGELOG.md')" 'sh tests/owned-paths.t.sh'
  printf '#!/bin/sh\n%s\n' "echo 'exit 0' >> tests/owned-paths.t.sh && $SG commit -qam judge" > "$T/stub/claude"; chmod +x "$T/stub/claude"
  sd_run "control: standards: a run that changes tests/owned-paths.t.sh is refused after the run" 1 0 "^dispatch-deepseek: lane changed a path $ALLOW" '^tests/owned-paths\.t\.sh$'
  printf '#!/bin/sh\n%s\n' "echo '# x' >> templates/ci-caller.yml && $SG commit -qam ci" > "$T/stub/claude"
  sd_run "control: standards: a run that changes templates/ci-caller.yml (not prose) is refused after the run" 1 0 "^dispatch-deepseek: lane changed a path $ALLOW" '^templates/ci-caller\.yml$'
  printf '#!/bin/sh\n%s\n' "git mv bin/check docs/check.md && $SG commit -qm mv" > "$T/stub/claude"
  sd_run "control: standards: a rename from bin/ into docs/ is refused after the run (both sides judged)" 1 0 "^dispatch-deepseek: lane changed a path $ALLOW" '^bin/check$'
  printf '#!/bin/sh\n%s\n' "echo 'See [x](nowhere.md).' >> docs/07-harness.md && $SG commit -qam docs" > "$T/stub/claude"
  sd_run "control: standards: a run that adds a broken link to docs/07 fails the docs judge" 1 0 '^dispatch-deepseek: docs judge failed' '^docs: FAIL docs/07-harness\.md:[0-9]+: broken relative link nowhere\.md$'
  printf '#!/bin/sh\n%s\n' "echo x >> docs/05-domain-rules.md && $SG commit -qam d05" > "$T/stub/claude"
  sd_run "control: standards: a run that changes docs/05-domain-rules.md is refused after the run (whatever §3 owned)" 1 0 "^dispatch-deepseek: lane changed a path $ALLOW" '^docs/05-domain-rules\.md$'
  printf '#!/bin/sh\n%s\n' "ln -s 07-harness.md docs/x.md && git add docs/x.md && $SG commit -qm link" > "$T/stub/claude"
  sd_run "control: standards: a run that commits a symlink docs/x.md is refused after the run" 1 0 '^dispatch-deepseek: lane committed a file mode other than 100644' '^120000 docs/x\.md$'
  printf '#!/bin/sh\n%s\n' "echo x > docs/run.md && chmod +x docs/run.md && git add --chmod=+x docs/run.md && $SG commit -qm exe" > "$T/stub/claude"
  sd_run "control: standards: a run that commits an executable docs/run.md (100755) is refused after the run" 1 0 '^dispatch-deepseek: lane committed a file mode other than 100644' '^100755 docs/run\.md$'
  printf '#!/bin/sh\n%s\n' "git rm -q docs/07-harness.md && $SG commit -qm rm" > "$T/stub/claude"
  sd_run "control: standards: deleting docs/07 that an unchanged doc links to fails the docs judge (every doc judged)" 1 0 '^dispatch-deepseek: docs judge failed' '^docs: FAIL docs/links\.md:2: broken relative link 07-harness\.md$'
  printf '#!/bin/sh\n%s\n' "echo 'See [06](06-code-quality.md).' >> docs/07-harness.md && $SG commit -qam docs" > "$T/stub/claude"
  sd_run "standards: a docs commit with green judges -> exit 0" 0 0 '^dispatch-deepseek: OK — new commit [0-9a-f]{40}, clean tree, every changed path in the docs allow-list, tests/owned-paths\.t\.sh and tests/docs\.t\.sh --judge green$'
  git -C "$SD" worktree remove --force "$SW"
else blk "standards docs lanes: $H is not a git checkout with the standards root commit $SROOT"; fi

# --- 5c. reusable Rust CI: the application role (v0.1.16, game m2.2 A6) -----------------------------
# A caller that ships scripts/db/app-role.sh gets the role created right after the migrations, before the tests; the
# job env carries APP_DATABASE_URL beside DATABASE_URL. A static check of the file: the run itself needs a real PR.
RCI="$H/.github/workflows/rust-ci.yml"
if grep -q '^      APP_DATABASE_URL: postgres://game_app:game_app@localhost:5432/postgres$' "$RCI" \
  && grep -A3 -F -- '- run: cargo sqlx migrate run && cargo sqlx prepare --workspace --check' "$RCI" \
    | grep -A2 -F -- "- if: hashFiles('scripts/db/app-role.sh') != ''" \
    | grep -A1 '^        name: application database role (callers that ship scripts/db/app-role\.sh)$' \
    | grep -q '^        run: bash scripts/db/app-role\.sh$'; then
  ok "rust-ci: APP_DATABASE_URL in the job env and the guarded app-role step directly after the migrations"
else bad "rust-ci: APP_DATABASE_URL in the job env and the guarded app-role step directly after the migrations (missing in $RCI)"; fi

# --- 6. needs a real GitHub org --------------------------------------------------------------------
blk "GitHub rulesets — not needed while the founder is the only merger (risk-gate is informational); revisit when a collaborator joins"
blk "reusable risk-gate and CI workflows (pinned standards checkout, gitleaks CLI, web job) — run on a real PR in the org"
blk "OS-level isolation (no Docker socket/credentials in worker containers) — verify on the dev machine"
echo; [ $R -eq 0 ] && echo "SMOKE: all runnable checks passed" || echo "SMOKE: FAILURES above"; exit $R
