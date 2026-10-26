#!/bin/sh
# Cases for bin/close-check (E4 retrospective A.1): the milestone-close checklist in one read-only call. A fixture repo
# (origin https://github.com/ephremdeme/exchange.git) with ledger/src/x.rs, a close report docs/md-reports/e9.md with
# neither a "full chain:" nor a "Tokens:" line, no mutation ledger (exchange D-469, D-471: close-check has no mutants or
# report row) and docs/md-reports/e9-milestone-review.md; a stub gh first on PATH printing $STUB/pr.json (or exiting 1
# when $STUB/gh-fail exists) and logging its arguments. The all-PASS case (which also asserts that no mutants or report
# row is printed), the same with --log over a green gate log, then one control per row, each in a clone that differs
# from the fixture by that one fact only, each FAIL for its own detail and "FAILED (1 of 4 rows)" where only that row
# can fail. Run: sh tests/close-check.t.sh   -> exit 0 when all cases behave.
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
F="$T/repo"; git init -q -b main "$F"; mkdir -p "$F/ledger/src" "$F/docs/md-reports"
git -C "$F" remote add origin https://github.com/ephremdeme/exchange.git
echo 'fn x() {}' > "$F/ledger/src/x.rs"; echo readme > "$F/README"; git -C "$F" add -A; git -C "$F" commit -qm c1
# The close report has neither a full chain: line nor a Tokens: line, and there is no mutation ledger (exchange D-469).
printf '# e9 close\nThe gate log is the evidence.\n' > "$F/docs/md-reports/e9.md"
git -C "$F" add -A; git -C "$F" commit -qm c2; C2=$(git -C "$F" rev-parse HEAD)
printf '# e9 review\ncodex-last-read: %s\n' "$C2" > "$F/docs/md-reports/e9-milestone-review.md"
git -C "$F" add -A; git -C "$F" commit -qm c3; HD=$(git -C "$F" rev-parse HEAD)
LABELS="founder-approved human-gate-accepted"
prj "$HD" $LABELS
want "all rows PASS -> exit 0, close-check: OK (4 rows)" 0 '^close-check: OK \(4 rows\)$' sh "$CC" "$F" e9 7
check_ "four PASS rows, head first with HEAD's sha, in the documented order, at most 10 lines" \
  '[ "$(printf "%s\n" "$out" | grep -c "^close-check: PASS ")" -eq 4 ] && [ "$(printf "%s\n" "$out" | head -n 1)" = "close-check: PASS head $HD" ] && [ "$(printf "%s\n" "$out" | cut -d" " -f3 | tr "\n" " ")" = "head pr labels codex (4 " ] && [ "$(printf "%s\n" "$out" | wc -l)" -le 10 ]'
check_ "D-471: neither a mutants row nor a report row is printed (no mutation ledger; a report without full chain: or Tokens:)" \
  '! printf "%s\n" "$out" | grep -Eq "^close-check: (PASS|FAIL) (mutants|report)( |$)"'
check_ "gh was asked about ephremdeme/exchange (parsed from origin), with view only" \
  'grep -q "^gh pr view 7 --repo ephremdeme/exchange --json state,isDraft,headRefOid,isCrossRepository$" "$STUB/gh.log" && ! grep -v "^gh pr view " "$STUB/gh.log" | grep -q .'
GL="$T/gate.log"
printf 'check: OK\nverify:e9 — 3 ok, 0 failed\ngate-head: %s\ngate-tree: clean\ngate-verdict: green e9\n' "$HD" > "$GL"
want "with --log over a green gate log whose gate-head = HEAD -> OK (5 rows)" 0 '^close-check: OK \(5 rows\)$' sh "$CC" "$F" e9 7 --log "$GL"
check_ "five PASS rows with --log: head pr labels codex gate" '[ "$(printf "%s\n" "$out" | grep -c "^close-check: PASS ")" -eq 5 ] && [ "$(printf "%s\n" "$out" | cut -d" " -f3 | tr "\n" " ")" = "head pr labels codex gate (5 " ]'
check_ "the fixture tree was not written by close-check" '[ -z "$(git -C "$F" status --porcelain --untracked-files=all)" ]'

# mk <name>: a clone of the fixture (origin re-pointed at GitHub) in $V; cm <msg>: commit everything in $V.
mk(){ V="$T/$1"; git clone -q "$F" "$V" && git -C "$V" remote set-url origin git@github.com:ephremdeme/exchange.git; }
cm(){ git -C "$V" add -A && git -C "$V" commit -qm "$1"; }
# head
mk head; echo more >> "$V/README"
want "control head: a tracked change -> FAIL head naming it" 1 '^close-check: FAIL head — tracked change: README$' sh "$CC" "$V" e9 7
check_ "control head: only the head row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 4 rows)"'
# pr
prj 0000000000000000000000000000000000000000 $LABELS
want "control pr: a different headRefOid -> FAIL pr" 1 "^close-check: FAIL pr — headRefOid 0{40} is not HEAD $HD\$" sh "$CC" "$F" e9 7
check_ "control pr: only the pr row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 4 rows)"'
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
check_ "control pr (cross-repository): only the pr row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 4 rows)"'
# labels
prj "$HD" founder-approved
want "control labels: human-gate-accepted missing -> FAIL labels naming it" 1 '^close-check: FAIL labels — missing: human-gate-accepted$' sh "$CC" "$F" e9 7
check_ "control labels: only the labels row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 4 rows)"'
# codex
mk codex2; X=$(git -C "$V" rev-parse HEAD); echo n > "$V/notes.txt"; cm notes
printf '# e9 review\ncodex-last-read: %s\n' "$X" > "$V/docs/md-reports/e9-milestone-review.md"; cm review
prj "$(git -C "$V" rev-parse HEAD)" $LABELS
check_ "control codex: the review names the commit two commits back" '[ "$(git -C "$V" rev-parse HEAD~2)" = "$X" ]'
want "control codex: a second file changed since codex-last-read -> FAIL codex" 1 "^close-check: FAIL codex — changed since codex-last-read $X: notes.txt\$" sh "$CC" "$V" e9 7
check_ "control codex: only the codex row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 4 rows)"'
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
check_ "control codex (untracked): only the codex row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 4 rows)"'
mk codex-dir; git -C "$V" rm -q docs/md-reports/e9-milestone-review.md; mkdir "$V/docs/md-reports/e9-milestone-review.md"
: > "$V/docs/md-reports/e9-milestone-review.md/codex-last-read: $C2"; cm dirreview; prj "$(git -C "$V" rev-parse HEAD)" $LABELS
want "control codex: a directory named like the review, its entry names the line -> FAIL codex (blobs only)" 1 '^close-check: FAIL codex — docs/md-reports/e9-milestone-review.md is not a file committed at HEAD$' sh "$CC" "$V" e9 7
# Exchange D-388 (2026-10-24, "Remove the ceremonials and make the whole process leaner"), as merge-pr rule 5b: after
# codex-last-read only docs/**, NOTES.md, DECISIONS.md and BACKLOG.md at the root may change; both sides of a rename.
mk codex-docs; X=$(git -C "$V" rev-parse HEAD); echo d > "$V/docs/data-inventory.md"; echo n > "$V/NOTES.md"; echo d > "$V/DECISIONS.md"; echo b > "$V/BACKLOG.md"; cm docs
printf '# e9 review\ncodex-last-read: %s\n' "$X" > "$V/docs/md-reports/e9-milestone-review.md"; cm review; prj "$(git -C "$V" rev-parse HEAD)" $LABELS
want "codex: docs/**, NOTES.md, DECISIONS.md and BACKLOG.md changed since codex-last-read -> OK (D-388)" 0 '^close-check: OK \(4 rows\)$' sh "$CC" "$V" e9 7
check_ "... the codex row passed with codex-last-read two commits back" '[ "$(git -C "$V" rev-parse HEAD~2)" = "$X" ] && printf "%s\n" "$out" | grep -qx "close-check: PASS codex"'
mk codex-bak; X=$(git -C "$V" rev-parse HEAD); echo n > "$V/NOTES.md.bak"; echo n > "$V/NOTES.md"; cm bak
printf '# e9 review\ncodex-last-read: %s\n' "$X" > "$V/docs/md-reports/e9-milestone-review.md"; cm review; prj "$(git -C "$V" rev-parse HEAD)" $LABELS
want "control codex: NOTES.md.bak changed since codex-last-read -> FAIL codex naming it" 1 "^close-check: FAIL codex — changed since codex-last-read $X: NOTES\.md\.bak\$" sh "$CC" "$V" e9 7
mk codex-rename; mkdir -p "$V/internal"; echo y > "$V/internal/y.go"; cm pre; X=$(git -C "$V" rev-parse HEAD); git -C "$V" mv internal/y.go docs/y.md; cm mv
printf '# e9 review\ncodex-last-read: %s\n' "$X" > "$V/docs/md-reports/e9-milestone-review.md"; cm review; prj "$(git -C "$V" rev-parse HEAD)" $LABELS
want "control codex: internal/y.go renamed to docs/y.md since codex-last-read -> FAIL codex naming internal/y.go" 1 "^close-check: FAIL codex — changed since codex-last-read $X: internal/y\.go\$" sh "$CC" "$V" e9 7
check_ "control codex (rename): only the codex row fails" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 4 rows)"'
# gate
prj "$HD" $LABELS; GL2="$T/gate2.log"
printf 'check: OK\nverify:e9 — 3 ok, 0 failed\ngate-head: %s\ngate-tree: clean\ngate-verdict: green e9\n' "$C2" > "$GL2"
want "control gate: --log whose gate-head is not HEAD -> FAIL gate" 1 "^close-check: FAIL gate — gate-head $C2 is not HEAD $HD\$" sh "$CC" "$F" e9 7 --log "$GL2"
check_ "control gate: only the gate row fails (1 of 5)" 'printf "%s\n" "$out" | tail -n 1 | grep -qx "close-check: FAILED (1 of 5 rows)"'
printf 'check: OK\nverify:e9 — 3 ok, 1 failed\ngate-head: %s\ngate-tree: clean\ngate-verdict: green e9\n' "$HD" > "$GL2"
want "control gate: a red gate log -> FAIL gate with gate-summary's reason" 1 '^close-check: FAIL gate — a verify line with failures: verify:e9 — 3 ok, 1 failed$' sh "$CC" "$F" e9 7 --log "$GL2"
# refusals
git clone -q "$F" "$T/local"
want "refusal: a non-github origin without --repo -> exit 2" 2 "^close-check: refused — origin '.*' is not a github.com URL of ephremdeme/<name>; pass --repo\$" sh "$CC" "$T/local" e9 7
want "the same clone with --repo ephremdeme/exchange is accepted" 0 '^close-check: OK \(4 rows\)$' sh "$CC" "$T/local" e9 7 --repo ephremdeme/exchange
want "refusal: --repo without a slash -> exit 2" 2 "^close-check: refused — --repo 'exchange' is not <owner/repo>\$" sh "$CC" "$F" e9 7 --repo exchange
want "refusal: <mN> E9 -> exit 2" 2 "^close-check: refused — <mN> 'E9' does not match" sh "$CC" "$F" E9 7
want "refusal: <pr> 7a -> exit 2" 2 "^close-check: refused — <pr> '7a' is not a number\$" sh "$CC" "$F" e9 7a
want "refusal: a subdirectory, not the top level -> exit 2" 2 '^close-check: refused — .* is not the top level of its git checkout' sh "$CC" "$F/ledger" e9 7
want "refusal: an unreadable --log -> exit 2" 2 '^close-check: refused — --log .*/none.log is not a readable file$' sh "$CC" "$F" e9 7 --log "$T/none.log"
want "refusal: usage -> exit 2" 2 '^close-check: refused — usage' sh "$CC" "$F" e9
rm -rf "$T"
[ $R -eq 0 ] && echo "close-check.t: all cases behave" || echo "close-check.t: FAILURES"
exit $R
