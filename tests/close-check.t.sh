#!/bin/sh
# Cases for bin/close-check (E4 retrospective A.1): the milestone-close checklist in one read-only call. A fixture repo
# (origin https://github.com/ephremdeme/exchange.git) with ledger/src/x.rs and docs/md-reports/{e9.md,e9-mutants.md,
# e9-milestone-review.md}; a stub gh first on PATH printing $STUB/pr.json (or exiting 1 when $STUB/gh-fail exists) and
# logging its arguments. The all-PASS case, the same with --log over a green gate log, then one control per row, each
# in a clone that differs from the fixture by that one fact only (the review re-pointed at the clone's HEAD, so the
# codex row stays green), each FAIL for its own detail and "FAILED (1 of 6 rows)" where only that row can fail.
# Run: sh tests/close-check.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); CC="$S/bin/close-check"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 8 | sed 's/^/        /'; fi; }
check_(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset GH_HOST GH_REPO GH_TOKEN GITHUB_TOKEN
STUB="$T/stub"; mkdir -p "$STUB/bin"; export STUB
printf '#!/bin/sh\necho "gh $*" >> "$STUB/gh.log"\n[ -e "$STUB/gh-fail" ] && exit 1\ncat "$STUB/pr.json"\n' > "$STUB/bin/gh"
chmod +x "$STUB/bin/gh"
# PATH is the stub dir alone, holding links to exactly the tools the judge and close-check use: no real gh is reachable
# even when it shares a directory with git or jq.
for c in git jq sh bash cat grep sed tr cut wc head tail sort uniq mktemp rm dirname basename env mkdir chmod touch ln expr; do
  p=$(command -v "$c") || { echo "close-check.t: $c not found"; exit 1; }
  ln -s "$p" "$STUB/bin/$c" || { echo "close-check.t: cannot link $c"; exit 1; }
done
PATH="$STUB/bin"; export PATH
[ "$(command -v gh)" = "$STUB/bin/gh" ] || { echo "close-check.t: the gh on PATH is not the stub — refusing to run"; exit 1; }
ok "the gh on PATH is the stub and PATH holds no other directory"
# prj <headRefOid> [labels...]: the stub's reply.
prj(){ h=$1; shift; ls=; for l in "$@"; do ls="$ls${ls:+,}{\"name\":\"$l\"}"; done
  printf '{"state":"OPEN","isDraft":false,"headRefOid":"%s","isCrossRepository":false,"labels":[%s]}\n' "$h" "$ls" > "$STUB/pr.json"; }
TOK='Tokens: integrator avg_ctx=120k calls_per_merge=14; lanes avg_ctx=80k requests=31; codex reads=2'
F="$T/repo"; git init -q -b main "$F"; mkdir -p "$F/ledger/src" "$F/docs/md-reports"
git -C "$F" remote add origin https://github.com/ephremdeme/exchange.git
echo 'fn x() {}' > "$F/ledger/src/x.rs"; echo readme > "$F/README"; git -C "$F" add -A; git -C "$F" commit -qm c1
C1=$(git -C "$F" rev-parse HEAD)
printf '# e9 mutants\nrun: %s files: ledger/src/x.rs tested: 5 missed: 0 caught: 4 unviable: 1 timeout: 0\n\nopen survivors: 0\n\n' "$(git -C "$F" rev-parse --short=12 HEAD)" > "$F/docs/md-reports/e9-mutants.md"
printf '# e9 close\nfull chain: green at the merge head\n%s\n' "$TOK" > "$F/docs/md-reports/e9.md"
git -C "$F" add -A; git -C "$F" commit -qm c2; C2=$(git -C "$F" rev-parse HEAD)
printf '# e9 review\ncodex-last-read: %s\n' "$C2" > "$F/docs/md-reports/e9-milestone-review.md"
git -C "$F" add -A; git -C "$F" commit -qm c3; HD=$(git -C "$F" rev-parse HEAD)
LABELS="founder-approved human-gate-accepted"
prj "$HD" $LABELS
want "all rows PASS -> exit 0, close-check: OK (6 rows)" 0 '^close-check: OK \(6 rows\)$' sh "$CC" "$F" e9 7
check_ "six PASS rows, head first with HEAD's sha, in the documented order, at most 10 lines" \
  '[ "$(printf "%s\n" "$out" | grep -c "^close-check: PASS ")" -eq 6 ] && [ "$(printf "%s\n" "$out" | head -n 1)" = "close-check: PASS head $HD" ] && [ "$(printf "%s\n" "$out" | cut -d" " -f3 | tr "\n" " ")" = "head pr labels codex mutants report (6 " ] && [ "$(printf "%s\n" "$out" | wc -l)" -le 10 ]'
check_ "gh was asked about ephremdeme/exchange (parsed from origin), with view only" \
  'grep -q "^gh pr view 7 --repo ephremdeme/exchange --json state,isDraft,headRefOid,isCrossRepository$" "$STUB/gh.log" && ! grep -v "^gh pr view " "$STUB/gh.log" | grep -q .'
GL="$T/gate.log"
printf 'check: OK\nverify:e9 — 3 ok, 0 failed\ngate-head: %s\ngate-tree: clean\ngate-verdict: green e9\n' "$HD" > "$GL"
want "with --log over a green gate log whose gate-head = HEAD -> OK (7 rows)" 0 '^close-check: OK \(7 rows\)$' sh "$CC" "$F" e9 7 --log "$GL"
check_ "seven PASS rows with --log" '[ "$(printf "%s\n" "$out" | grep -c "^close-check: PASS ")" -eq 7 ]'
check_ "the fixture tree was not written by close-check" '[ -z "$(git -C "$F" status --porcelain --untracked-files=all)" ]'

# mk <name>: a clone of the fixture (origin re-pointed at GitHub) in $V; rv: re-point the review at HEAD and commit.
mk(){ V="$T/$1"; git clone -q "$F" "$V" && git -C "$V" remote set-url origin git@github.com:ephremdeme/exchange.git; }
cm(){ git -C "$V" add -A && git -C "$V" commit -qm "$1"; }
rv(){ printf '# e9 review\ncodex-last-read: %s\n' "$(git -C "$V" rev-parse HEAD)" > "$V/docs/md-reports/e9-milestone-review.md"; cm review; prj "$(git -C "$V" rev-parse HEAD)" $LABELS; }
# head
mk head; echo more >> "$V/README"
want "control head: a tracked change -> FAIL head naming it" 1 '^close-check: FAIL head — tracked change: README$' sh "$CC" "$V" e9 7
check_ "control head: only the head row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 6 rows)"'
# pr
prj 0000000000000000000000000000000000000000 $LABELS
want "control pr: a different headRefOid -> FAIL pr" 1 "^close-check: FAIL pr — headRefOid 0{40} is not HEAD $HD\$" sh "$CC" "$F" e9 7
check_ "control pr: only the pr row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 6 rows)"'
prj "$HD" $LABELS; touch "$STUB/gh-fail"
want "control pr: gh exits 1 -> FAIL pr (fail closed)" 1 '^close-check: FAIL pr — gh pr view 7 --repo ephremdeme/exchange failed$' sh "$CC" "$F" e9 7
rm -f "$STUB/gh-fail"
printf '{"state":"OPEN","isDraft":false,"isCrossRepository":false,"labels":[]}\n' > "$STUB/pr.json"
want "control pr: a reply without headRefOid -> FAIL pr (fail closed)" 1 '^close-check: FAIL pr — gh pr view reply lacks' sh "$CC" "$F" e9 7
LJ='"labels":[{"name":"founder-approved"},{"name":"human-gate-accepted"}]'
printf '{"state":"MERGED","isDraft":false,"headRefOid":"%s","isCrossRepository":false,%s}\n' "$HD" "$LJ" > "$STUB/pr.json"
want "control pr: state MERGED -> FAIL pr" 1 '^close-check: FAIL pr — state MERGED, not OPEN$' sh "$CC" "$F" e9 7
printf '{"state":"OPEN","isDraft":true,"headRefOid":"%s","isCrossRepository":false,%s}\n' "$HD" "$LJ" > "$STUB/pr.json"
want "control pr: isDraft true -> FAIL pr" 1 '^close-check: FAIL pr — the PR is a draft$' sh "$CC" "$F" e9 7
printf '{"state":"OPEN","isDraft":false,"headRefOid":"%s","isCrossRepository":true,%s}\n' "$HD" "$LJ" > "$STUB/pr.json"
want "control pr: isCrossRepository true -> FAIL pr" 1 '^close-check: FAIL pr — the PR is from another repository$' sh "$CC" "$F" e9 7
check_ "control pr (cross-repository): only the pr row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 6 rows)"'
# labels
prj "$HD" founder-approved
want "control labels: human-gate-accepted missing -> FAIL labels naming it" 1 '^close-check: FAIL labels — missing: human-gate-accepted$' sh "$CC" "$F" e9 7
check_ "control labels: only the labels row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 6 rows)"'
# codex
mk codex2; X=$(git -C "$V" rev-parse HEAD); echo n > "$V/notes.txt"; cm notes
printf '# e9 review\ncodex-last-read: %s\n' "$X" > "$V/docs/md-reports/e9-milestone-review.md"; cm review
prj "$(git -C "$V" rev-parse HEAD)" $LABELS
check_ "control codex: the review names the commit two commits back" '[ "$(git -C "$V" rev-parse HEAD~2)" = "$X" ]'
want "control codex: a second file changed since codex-last-read -> FAIL codex" 1 "^close-check: FAIL codex — changed since codex-last-read $X: notes.txt\$" sh "$CC" "$V" e9 7
check_ "control codex: only the codex row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 6 rows)"'
mk codex-two; printf 'codex-last-read: %s\n' "$C2" >> "$V/docs/md-reports/e9-milestone-review.md"; cm two
prj "$(git -C "$V" rev-parse HEAD)" $LABELS
want "control codex: two codex-last-read lines -> FAIL codex" 1 '^close-check: FAIL codex — 2 codex-last-read lines in docs/md-reports/e9-milestone-review.md, exactly one required$' sh "$CC" "$V" e9 7
mk codex-side; git -C "$V" checkout -q -b side "$C2"; echo s > "$V/side.txt"; cm side; SD=$(git -C "$V" rev-parse HEAD)
git -C "$V" checkout -q main; printf '# e9 review\ncodex-last-read: %s\n' "$SD" > "$V/docs/md-reports/e9-milestone-review.md"; cm review
prj "$(git -C "$V" rev-parse HEAD)" $LABELS
want "control codex: a codex-last-read that is not an ancestor of HEAD -> FAIL codex" 1 "^close-check: FAIL codex — codex-last-read $SD is not an ancestor of HEAD\$" sh "$CC" "$V" e9 7
mk codex-untracked; git -C "$V" rm -q docs/md-reports/e9-milestone-review.md; cm unreview
printf '# e9 review\ncodex-last-read: %s\n' "$C2" > "$V/docs/md-reports/e9-milestone-review.md"
prj "$(git -C "$V" rev-parse HEAD)" $LABELS
want "control codex: an untracked review file (merge-pr reads it at the sha) -> FAIL codex" 1 '^close-check: FAIL codex — docs/md-reports/e9-milestone-review.md is not a file committed at HEAD$' sh "$CC" "$V" e9 7
check_ "control codex (untracked): only the codex row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 6 rows)"'
# mutants
mk surv; printf '# e9 mutants\nrun: %s files: ledger/src/x.rs tested: 5 missed: 0 caught: 4 unviable: 1 timeout: 0\nopen survivors: 1\n' "$C1" > "$V/docs/md-reports/e9-mutants.md"; cm surv; rv
want "control mutants: open survivors: 1 last -> FAIL mutants" 1 "^close-check: FAIL mutants — last line is 'open survivors: 1', not 'open survivors: 0'\$" sh "$CC" "$V" e9 7
check_ "control mutants (survivors): only the mutants row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 6 rows)"'
mk stale; echo 'fn y() {}' >> "$V/ledger/src/x.rs"; cm later; rv
want "control mutants: a run older than a later ledger/src change -> FAIL mutants" 1 '^close-check: FAIL mutants — run [0-9a-f]{12}: ledger/src changed since the run$' sh "$CC" "$V" e9 7
check_ "control mutants (stale): only the mutants row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 6 rows)"'
mk counts; printf '# e9 mutants\nrun: %s files: ledger/src/x.rs tested: 6 missed: 0 caught: 4 unviable: 1 timeout: 0\nopen survivors: 0\n' "$C1" > "$V/docs/md-reports/e9-mutants.md"; cm counts; rv
want "control mutants: counts that do not add up -> FAIL mutants" 1 '^close-check: FAIL mutants — run [0-9a-f]{40}: tested 6 is not missed \+ caught \+ unviable \+ timeout \(5\)$' sh "$CC" "$V" e9 7
mk malformed; printf '# e9 mutants\nrun: %s files: ledger/src/x.rs tested: 5 missed: 0 caught: 4\nopen survivors: 0\n' "$C1" > "$V/docs/md-reports/e9-mutants.md"; cm malformed; rv
want "control mutants: a malformed run: line is a FAIL, never skipped" 1 '^close-check: FAIL mutants — malformed run line: run: ' sh "$CC" "$V" e9 7
mk nocrate; printf '# e9 mutants\nrun: %s files: ledger/src/x.rs,Cargo.toml tested: 5 missed: 0 caught: 4 unviable: 1 timeout: 0\nopen survivors: 0\n' "$C1" > "$V/docs/md-reports/e9-mutants.md"; cm nocrate; rv
want "control mutants: a files: entry without a <crate>/ prefix is a FAIL, never a vacuous diff" 1 "^close-check: FAIL mutants — run [0-9a-f]{40}: files: entry 'Cargo.toml' has no <crate>/ prefix\$" sh "$CC" "$V" e9 7
mk nosrc; printf '# e9 mutants\nrun: %s files: docs/x.md tested: 5 missed: 0 caught: 4 unviable: 1 timeout: 0\nopen survivors: 0\n' "$C1" > "$V/docs/md-reports/e9-mutants.md"; cm nosrc; rv
want "control mutants: a crate with no src tree at the run (a vacuous diff) -> FAIL mutants" 1 '^close-check: FAIL mutants — run [0-9a-f]{40}: docs/src does not exist at the run$' sh "$CC" "$V" e9 7
mk norun; printf '# e9 mutants\nno runs recorded\nopen survivors: 0\n' > "$V/docs/md-reports/e9-mutants.md"; cm norun; rv
want "control mutants: a ledger with no run: line -> FAIL mutants" 1 '^close-check: FAIL mutants — no run: line in docs/md-reports/e9-mutants.md$' sh "$CC" "$V" e9 7
mk nocommit; printf '# e9 mutants\nrun: deadbeefdeadbeef files: ledger/src/x.rs tested: 5 missed: 0 caught: 4 unviable: 1 timeout: 0\nopen survivors: 0\n' > "$V/docs/md-reports/e9-mutants.md"; cm nocommit; rv
want "control mutants: a run: sha that is not a commit -> FAIL mutants" 1 '^close-check: FAIL mutants — run deadbeefdeadbeef is not a commit here$' sh "$CC" "$V" e9 7
mk nochain; printf '# e9 close\n%s\n' "$TOK" > "$V/docs/md-reports/e9.md"; cm nochain; rv
want "control report: no full chain: line -> FAIL report" 1 "^close-check: FAIL report — docs/md-reports/e9.md: no 'full chain: ' line\$" sh "$CC" "$V" e9 7
mk dirreport; git -C "$V" rm -q docs/md-reports/e9.md; mkdir "$V/docs/md-reports/e9.md"
: > "$V/docs/md-reports/e9.md/full chain: x"; : > "$V/docs/md-reports/e9.md/Tokens: integrator avg_ctx=1k calls_per_merge=1; lanes avg_ctx=1k requests=1; codex reads=1"
cm dirreport; rv
want "control report: a directory named like the report, its entry names the required lines -> FAIL report (blobs only)" 1 '^close-check: FAIL report — docs/md-reports/e9.md is not a file committed at HEAD$' sh "$CC" "$V" e9 7
# report
mk report; printf '# e9 close\nfull chain: green at the merge head\n' > "$V/docs/md-reports/e9.md"; cm report; rv
want "control report: no Tokens line -> FAIL report" 1 '^close-check: FAIL report — docs/md-reports/e9.md: no Tokens: line' sh "$CC" "$V" e9 7
check_ "control report: only the report row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 6 rows)"'
# gate
prj "$HD" $LABELS; GL2="$T/gate2.log"
printf 'check: OK\nverify:e9 — 3 ok, 0 failed\ngate-head: %s\ngate-tree: clean\ngate-verdict: green e9\n' "$C2" > "$GL2"
want "control gate: --log whose gate-head is not HEAD -> FAIL gate" 1 "^close-check: FAIL gate — gate-head $C2 is not HEAD $HD\$" sh "$CC" "$F" e9 7 --log "$GL2"
check_ "control gate: only the gate row fails (1 of 7)" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 7 rows)"'
printf 'check: OK\nverify:e9 — 3 ok, 1 failed\ngate-head: %s\ngate-tree: clean\ngate-verdict: green e9\n' "$HD" > "$GL2"
want "control gate: a red gate log -> FAIL gate with gate-summary's reason" 1 '^close-check: FAIL gate — a verify line with failures: verify:e9 — 3 ok, 1 failed$' sh "$CC" "$F" e9 7 --log "$GL2"
# refusals
git clone -q "$F" "$T/local"
want "refusal: a non-github origin without --repo -> exit 2" 2 "^close-check: refused — origin '.*' is not a github.com URL of ephremdeme/<name>; pass --repo\$" sh "$CC" "$T/local" e9 7
want "the same clone with --repo ephremdeme/exchange is accepted" 0 '^close-check: OK \(6 rows\)$' sh "$CC" "$T/local" e9 7 --repo ephremdeme/exchange
want "refusal: --repo without a slash -> exit 2" 2 "^close-check: refused — --repo 'exchange' is not <owner/repo>\$" sh "$CC" "$F" e9 7 --repo exchange
want "refusal: <mN> E9 -> exit 2" 2 "^close-check: refused — <mN> 'E9' does not match" sh "$CC" "$F" E9 7
want "refusal: <pr> 7a -> exit 2" 2 "^close-check: refused — <pr> '7a' is not a number\$" sh "$CC" "$F" e9 7a
want "refusal: a subdirectory, not the top level -> exit 2" 2 '^close-check: refused — .* is not the top level of its git checkout' sh "$CC" "$F/ledger" e9 7
want "refusal: an unreadable --log -> exit 2" 2 '^close-check: refused — --log .*/none.log is not a readable file$' sh "$CC" "$F" e9 7 --log "$T/none.log"
want "refusal: usage -> exit 2" 2 '^close-check: refused — usage' sh "$CC" "$F" e9
rm -rf "$T"
[ $R -eq 0 ] && echo "close-check.t: all cases behave" || echo "close-check.t: FAILURES"
exit $R
