#!/bin/sh
# Cases for bin/targeted-gate (v0.1.32: the hotfix and small-change gate, merged through merge-pr --targeted-log). A
# scratch repository, a stub `free` in $HOME/.cargo/bin and a stub `gitleaks` in $HOME/.local/bin (check puts both
# first on PATH), switched by files in $CTL outside the tree (leak-detect: the committed-history scan fails;
# leak-stdin: the uncommitted + untracked scan fails). The secret scans are the real bin/check --only secrets. A
# refusal is exit 2 with its own message, nothing run and no log written; a red run is exit 1 with the whole log, which
# still ends in gate-head, gate-tree and its red gate-verdict. At the end the gate's own red and green logs go through
# bin/merge-pr --targeted-log with a stub gh (end to end).
# Run: sh standards/tests/targeted-gate.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); TG="$S/bin/targeted-gate"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
unset VERIFY_FAIL_TAIL DATABASE_URL
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
check_(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
CTL="$T/ctl"; mkdir -p "$CTL" "$T/h/.cargo/bin" "$T/h/.local/bin" "$T/logs" "$T/plain"; export CTL HOME="$T/h"
printf '#!/bin/sh\necho "Mem: stub free $*"\n' > "$T/h/.cargo/bin/free"; chmod +x "$T/h/.cargo/bin/free"
cat > "$T/h/.local/bin/gitleaks" << 'GL'
#!/bin/sh
echo "gitleaks-stub: $1"
if [ "$1" = stdin ]; then cat > /dev/null; fi
if [ -e "$CTL/leak-$1" ]; then echo "leak found"; exit 1; fi
exit 0
GL
chmod +x "$T/h/.local/bin/gitleaks"
P="$T/repo"; git init -q -b main "$P"; echo readme > "$P/README"; git -C "$P" add -A; git -C "$P" commit -qm fixture
HD=$(git -C "$P" rev-parse HEAD); PP=$(cd "$P" && pwd -P)
echo 'the lane contract' > "$P/TASK.md"   # an untracked TASK.md at the top: the one dirt the gate allows
n=0; nl(){ n=$((n + 1)); L="$T/logs/$n.log"; }   # a fresh log path per run
reset(){ rm -f "$CTL"/*; }
tail3(){ printf 'gate-head: %s\ngate-tree: %s\ngate-verdict: %s' "$HD" "$1" "$2"; }   # tail3 <tree> <verdict>
RAN='touch "$CTL/ran"'   # a first command that leaves a mark, so a refusal proves nothing ran
# Refusals: exit 2, their own message, nothing run, no log written.
nl; want "control: one argument -> usage, exit 2" 2 '^targeted-gate: usage: targeted-gate <repo-dir> <log> <cmd> \[<cmd> \.\.\.\]$' sh "$TG" "$P"
nl; want "control: no command -> refused" 2 '^targeted-gate: refused — no command given \(targeted-gate <repo-dir> <log> <cmd> \[<cmd> \.\.\.\]\)$' sh "$TG" "$P" "$L"
check_ "control: ... no log written" '[ ! -e "$L" ]'
reset; nl; want "control: a command naming .env -> refused" 2 "^targeted-gate: refused — the command 'cat \.env' names \.env \(\.env is data; no gate command reads it\)\$" sh "$TG" "$P" "$L" "$RAN" 'cat .env'
check_ "control: ... no log written and the first command did not run" '[ ! -e "$L" ] && [ ! -e "$CTL/ran" ]'
reset; nl; want "control: a command with a newline -> refused" 2 '^targeted-gate: refused — a command contains a newline$' sh "$TG" "$P" "$L" "$RAN" "$(printf 'echo a\necho b')"
check_ "control: ... no log written and the first command did not run" '[ ! -e "$L" ] && [ ! -e "$CTL/ran" ]'
reset; nl; want "control: an empty command -> refused" 2 '^targeted-gate: refused — an empty command$' sh "$TG" "$P" "$L" "$RAN" ''
nl; echo dirt >> "$P/README"
want "control: a dirty tree at the start (a modified tracked file) -> refused naming it" 2 "^targeted-gate: refused — the tree of $P is not clean \(first: README\)\$" sh "$TG" "$P" "$L" "$RAN"
check_ "control: ... no log written and nothing ran" '[ ! -e "$L" ] && [ ! -e "$CTL/ran" ]'
git -C "$P" checkout -q -- README
nl; echo j > "$P/junk.txt"
want "control: an untracked file beside TASK.md -> refused naming it" 2 "^targeted-gate: refused — the tree of $P is not clean \(first: junk\.txt\)\$" sh "$TG" "$P" "$L" "$RAN"
rm -f "$P/junk.txt"
mkdir -p "$P/sub"; nl; want "control: a subdirectory, not the top level -> refused" 2 "^targeted-gate: refused — $P/sub is not the top level of a git checkout with a commit\$" sh "$TG" "$P/sub" "$L" "$RAN"
rmdir "$P/sub"
nl; want "control: a directory outside git -> refused" 2 "^targeted-gate: refused — $T/plain is not the top level of a git checkout with a commit\$" sh "$TG" "$T/plain" "$L" "$RAN"
nl; echo old > "$L"; want "control: an existing log -> refused" 2 "^targeted-gate: refused — $L exists; the gate writes a fresh log only\$" sh "$TG" "$P" "$L" "$RAN"
check_ "control: ... the existing log is untouched and nothing ran" '[ "$(cat "$L")" = old ] && [ ! -e "$CTL/ran" ]'
nl; want "control: a log in a missing directory -> refused" 2 "^targeted-gate: refused — cannot create the log $T/missing/1\.log\$" sh "$TG" "$P" "$T/missing/1.log" "$RAN"
# A green run: two ok commands, both secret scans PASS, the tree clean, HEAD unmoved.
reset; nl; want "green: two ok commands -> exit 0" 0 "^targeted-gate: OK $HD $L\$" sh "$TG" "$P" "$L" 'pwd -P' 'echo second'; LGREEN=$L
check_ "... the log starts with free -m, found first in \$HOME/.cargo/bin" '[ "$(head -n 1 "$L")" = "Mem: stub free -m" ]'
check_ "... each command ran from the repo top after its targeted: line, then its targeted-result: ok line" '[ "$(sed -n 2,7p "$L")" = "$(printf "targeted: pwd -P\n%s\ntargeted-result: ok pwd -P\ntargeted: echo second\nsecond\ntargeted-result: ok echo second" "$PP")" ]'
check_ "... then check --only secrets: both secret scans PASS, nothing else run, check: OK" 'grep -qx "PASS  secret scan (committed history)" "$L" && grep -qx "PASS  secret scan (uncommitted + untracked)" "$L" && grep -qx "SKIP  go (--only secrets)" "$L" && grep -qx "SKIP  rust (--only secrets)" "$L" && grep -qx "check: OK" "$L"'
check_ "... it ends with gate-head, gate-tree: clean and gate-verdict: green targeted, its only verdict line" '[ "$(tail -n 3 "$L")" = "$(tail3 clean "green targeted")" ] && [ "$(grep -c "^gate-verdict:" "$L")" -eq 1 ]'
# One failing command: red, and the other commands still ran.
reset; nl; want "red: one failing command -> exit 1 naming it" 1 "^targeted-gate: RED $HD — the command 'exit 3' exited 3 \(log $L\)\$" sh "$TG" "$P" "$L" 'echo before' 'exit 3' 'echo after'; LRED=$L
check_ "... the failure is logged and the command after it still ran" 'grep -qx "targeted-result: FAILED (exit 3) exit 3" "$L" && grep -qx "after" "$L" && grep -qx "targeted-result: ok echo after" "$L" && grep -qx "targeted-result: ok echo before" "$L"'
check_ "... the secret scans still ran and the log ends with the red verdict" 'grep -qx "PASS  secret scan (committed history)" "$L" && [ "$(tail -n 3 "$L")" = "$(tail3 clean "red — the command '"'"'exit 3'"'"' exited 3")" ]'
# A dirty tree at the end (a tracked file modified by a command).
reset; nl; want "red: a command modifies a tracked file -> exit 1" 1 "^targeted-gate: RED $HD — the tree is not clean at the end \(first: README\) \(log $L\)\$" sh "$TG" "$P" "$L" 'echo dirt >> README'
check_ "... the log ends with gate-tree: dirty (README) and the red verdict, though the command was ok" 'grep -qx "targeted-result: ok echo dirt >> README" "$L" && [ "$(tail -n 2 "$L")" = "$(printf "gate-tree: dirty (README)\ngate-verdict: red — the tree is not clean at the end (first: README)")" ]'
git -C "$P" checkout -q -- README
# The secret scans: either one failing is red.
reset; touch "$CTL/leak-detect"; nl
want "red: the committed-history scan fails -> exit 1" 1 "^targeted-gate: RED $HD — the secret scan \(committed history\) did not pass \(log $L\)\$" sh "$TG" "$P" "$L" 'echo one'
check_ "... the log has its FAIL line" 'grep -qx "FAIL  secret scan (committed history)" "$L" && grep -qx "check: FAILED" "$L"'
reset; touch "$CTL/leak-stdin"; nl
want "red: the uncommitted + untracked scan fails -> exit 1" 1 "^targeted-gate: RED $HD — the secret scan \(uncommitted \+ untracked\) did not pass \(log $L\)\$" sh "$TG" "$P" "$L" 'echo one'
# A command whose output carries a line merge-pr refuses: the gate is red too, so green always means mergeable.
reset; nl; want "red: an ok command printing a FAIL line -> exit 1" 1 "^targeted-gate: RED $HD — the log has 1 FAIL line\(s\) \(log $L\)\$" sh "$TG" "$P" "$L" 'echo "FAIL  something"'
reset; nl; want "red: an ok command printing a gate-verdict line -> exit 1" 1 "^targeted-gate: RED $HD — a command printed 1 gate-head, gate-tree or gate-verdict line\(s\) \(log $L\)\$" sh "$TG" "$P" "$L" 'echo "gate-verdict: green targeted"'
# End to end: the gate's own red and green logs through merge-pr --targeted-log. A stub gh serves an open hotfix PR #12
# on exchange whose head is the fixture's HEAD and its one file, and records the merge call; any other call fails.
GB="$T/ghbin"; mkdir -p "$GB" "$T/ghconf"
cat > "$GB/gh" << 'GH'
#!/bin/sh
case "$*" in
  "pr view 12 --repo ephremdeme/exchange --json "*)
    printf '{"state":"OPEN","isDraft":false,"headRefOid":"%s","baseRefName":"main","headRefName":"opus/hotfix-x","isCrossRepository":false,"changedFiles":1,"labels":[]}\n' "$GHSTUB_HEAD";;
  "api --paginate repos/ephremdeme/exchange/pulls/12/files?per_page=100") echo '[{"filename":"internal/x.go","status":"modified"}]';;
  "pr merge 12 --repo ephremdeme/exchange --merge --match-head-commit "*) printf '%s\n' "$*" > "$GHSTUB_MERGE"; echo merged;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 64;;
esac
GH
chmod +x "$GB/gh"
[ "$(env PATH="$GB:$PATH" sh -c 'command -v gh')" = "$GB/gh" ] || { echo "FAIL    the stub gh is not first on PATH; aborting"; rm -rf "$T"; exit 1; }
mp(){ rm -f "$T/merge"; env PATH="$GB:$PATH" GH_TOKEN=stub-not-a-token GH_CONFIG_DIR="$T/ghconf" GHSTUB_HEAD="$HD" GHSTUB_MERGE="$T/merge" \
  sh "$S/bin/merge-pr" ephremdeme/exchange 12 "$HD" --targeted-log "$1"; }
want "end to end: the gate's red log -> merge-pr --targeted-log refuses it" 2 "^merge-pr: refused — targeted log $LRED has 1 targeted-result: FAILED line\(s\)\$" mp "$LRED"
check_ "... no merge call" '[ ! -e "$T/merge" ]'
want "end to end: the gate's green log -> merge-pr --targeted-log merges" 0 "^merge-pr: OK ephremdeme/exchange#12 $HD merged\$" mp "$LGREEN"
check_ "... exactly the guarded merge call" '[ "$(cat "$T/merge" 2>/dev/null)" = "pr merge 12 --repo ephremdeme/exchange --merge --match-head-commit $HD" ]'
# HEAD moved during the run (last: it moves the fixture's HEAD).
reset; nl; want "red: HEAD moved during the run -> exit 1" 1 "^targeted-gate: RED $HD — HEAD moved from $HD to [0-9a-f]{40} during the run \(log $L\)\$" sh "$TG" "$P" "$L" 'git commit -q --allow-empty -m moved'
check_ "... the log names both heads and gate-tree: dirty (HEAD moved)" '[ "$(grep -c "^gate-head: " "$L")" -eq 2 ] && grep -qx "gate-head: $(git -C "$P" rev-parse HEAD)" "$L" && grep -qx "gate-tree: dirty (HEAD moved)" "$L"'
reset; rm -rf "$T"; [ $R -eq 0 ] && echo "targeted-gate.t: all cases behave" || echo "targeted-gate.t: FAILURES"; exit $R
