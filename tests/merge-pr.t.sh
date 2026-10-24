#!/bin/sh
# Cases for bin/merge-pr (exchange D-086/D-088 item 7: the agents' only merge path). A stub `gh` first on PATH serves
# canned JSON per call from files in $G (pr, checks, status, files, activity, timeline, nightly, jobs-<id>, review,
# decisions, compare .json; <key>.err makes that call fail) and records every call in $G/calls and the merge call in
# $G/merge. Every control is refused for its own message AND the stub saw no merge call; every positive case asserts the
# exact merge call. No network: a bogus GH_TOKEN and an empty GH_CONFIG_DIR, and the run aborts unless gh is the stub.
# The --local-log cases (D-109) write the gate log line by line (glog) and make every check-runs, status and nightly
# read fail (nochecks), so a merge proves those endpoints were not needed and the calls log proves they were not read;
# a green log ends, as bin/local-gate writes it, in gate-head, gate-tree: clean and one gate-verdict: green <id>.
# Run: sh standards/tests/merge-pr.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); MP="$S/bin/merge-pr"; T=$(mktemp -d); R=0
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
check_(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
G="$T/gh"; GHSTUB_DIR=$G; export GHSTUB_DIR
refused(){ # refused <label> <regex> <merge-pr args...>: exit 2, its own message, and no merge call reached gh
  label=$1; re=$2; shift 2; out=$(sh "$MP" "$@" 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -Eq -- "^merge-pr: refused — $re" && [ ! -e "$G/merge" ]; then ok "control: $label -> refused, not merged"
  else bad "control: $label (rc=$rc want 2, /$re/, merge call: $([ -e "$G/merge" ] && echo yes || echo none))"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
merged(){ # merged <label> <regex> <merge-pr args...>: exit 0, the success line, and exactly the guarded merge call
  label=$1; re=$2; shift 2; out=$(sh "$MP" "$@" 2>&1); rc=$?
  call="pr merge $2 --repo $1 --merge --match-head-commit $3"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Eqx -- "$re" && [ "$(cat "$G/merge" 2>/dev/null)" = "$call" ]; then ok "$label"
  else bad "$label (rc=$rc want 0, /$re/, merge call: $(cat "$G/merge" 2>/dev/null || echo none))"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
# The stub gh.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/sh
G=${GHSTUB_DIR:?}
printf '%s\n' "$*" >> "$G/calls"
key=
case "$1 ${2:-}" in
  "pr view") key=pr;;
  "pr merge") printf '%s\n' "$*" >> "$G/merge"; if [ -f "$G/merge.err" ]; then cat "$G/merge.err" >&2; exit 1; fi; echo merged; exit 0;;
  "api "*)
    shift; [ "$1" = --paginate ] && shift
    case "$1" in
      repos/*/commits/*/check-runs\?*) key=checks;;
      repos/*/commits/*/status) key=status;;
      repos/*/pulls/*/files\?*) key=files;;
      repos/*/activity\?*) key=activity;;
      repos/*/actions/workflows/nightly.yml/runs\?*) key=nightly;;
      repos/*/actions/runs/*/jobs\?*) id=${1#*/actions/runs/}; key=jobs-${id%%/*};;
      repos/*/issues/*/timeline\?*) key=timeline;;
      repos/*/contents/DECISIONS.md\?ref=*) key=decisions;;
      repos/*/contents/docs/md-reports/*\?ref=*) key=review;;
      repos/*/compare/*) key=compare;;
    esac;;
esac
[ -n "$key" ] || { echo "gh stub: unexpected call: $*" >&2; exit 64; }
if [ -f "$G/$key.err" ]; then cat "$G/$key.err" >&2; exit 1; fi
[ -f "$G/$key.json" ] || { echo "gh stub: no $key.json" >&2; exit 64; }
cat "$G/$key.json"
STUB
chmod 755 "$T/bin/gh"; PATH="$T/bin:$PATH"; export PATH
# Never the real gh: a bogus token and an empty config make any real call fail, and the stub must be the one found.
GH_TOKEN=stub-not-a-token; GH_CONFIG_DIR="$T/ghconfig"; export GH_TOKEN GH_CONFIG_DIR; mkdir -p "$GH_CONFIG_DIR"
[ "$(command -v gh)" = "$T/bin/gh" ] || { echo "FAIL    the stub gh is not first on PATH ($(command -v gh)); aborting"; rm -rf "$T"; exit 1; }
H=$(printf '%040x' 12648430); X=$(printf '%040x' 11259375); Y=$(printf '%040x' 4660)
RV=docs/md-reports/e9-milestone-review.md; IB=integration/e9
# Fixture writers.
pr(){ # pr <state> <isDraft> <head> <base> <headRefName> <isCrossRepository> <changedFiles> [labels...]
  st=$1; dr=$2; hd=$3; bs=$4; hb=$5; xr=$6; cf=$7; shift 7; ls=; for l in "$@"; do ls="$ls${ls:+,}{\"name\":\"$l\"}"; done
  printf '{"state":"%s","isDraft":%s,"headRefOid":"%s","baseRefName":"%s","headRefName":"%s","isCrossRepository":%s,"changedFiles":%s,"labels":[%s]}\n' \
    "$st" "$dr" "$hd" "$bs" "$hb" "$xr" "$cf" "$ls" > "$G/pr.json"; }
files(){ # files <path>...: one page of PR files
  fs=; for f in "$@"; do fs="$fs${fs:+,}{\"filename\":\"$f\",\"status\":\"modified\"}"; done; printf '[%s]\n' "$fs" > "$G/files.json"; }
activity(){ # activity <branch> <after> <timestamp> [activity_type]: the newest entry, then an older push
  printf '[{"activity_type":"%s","ref":"refs/heads/%s","before":"%s","after":"%s","timestamp":"%s","actor":{"login":"ephremdeme"}},{"activity_type":"branch_creation","ref":"refs/heads/%s","before":"%s","after":"%s","timestamp":"2026-10-06T08:00:00Z","actor":{"login":"ephremdeme"}}]\n' \
    "${4:-push}" "$1" "$X" "$2" "$3" "$1" "0000000000000000000000000000000000000000" "$X" > "$G/activity.json"; }
lab(){ # lab <label> <at> [login] [type] [event]: one timeline event
  printf '{"event":"%s","label":{"name":"%s"},"created_at":"%s","actor":{"login":"%s","type":"%s"}}' "${5:-labeled}" "$1" "$2" "${3:-ephremdeme}" "${4:-User}"; }
timeline(){ # timeline <founder-approved at> <human-gate-accepted at>: two pages; the commit is dated 09:00
  printf '[{"event":"committed","sha":"%s","created_at":null,"author":{"date":"2026-10-06T09:00:00Z"},"committer":{"date":"2026-10-06T09:00:00Z"}}]\n' "$H" > "$G/timeline.json"
  printf '[%s,%s]\n' "$(lab founder-approved "$1")" "$(lab human-gate-accepted "$2")" >> "$G/timeline.json"; }
content(){ # content <key> <text>: a contents-API reply holding <text>, base64 wrapped at 76 columns as GitHub does
  b=$(printf '%s' "$2" | base64 | awk '{ printf "%s\\n", $0 }'); printf '{"type":"file","encoding":"base64","content":"%s"}\n' "$b" > "$G/$1.json"; }
compare(){ # compare <status> <path>...
  st=$1; shift; fs=; for f in "$@"; do fs="$fs${fs:+,}{\"filename\":\"$f\",\"status\":\"modified\"}"; done
  printf '{"status":"%s","ahead_by":1,"total_commits":1,"files":[%s]}\n' "$st" "$fs" > "$G/compare.json"; }
checks(){ # checks <name>/<conclusion>...: one page of completed check runs
  n=0; rs=; for c in "$@"; do n=$((n + 1)); rs="$rs${rs:+,}{\"name\":\"${c%/*}\",\"status\":\"completed\",\"conclusion\":\"${c##*/}\"}"; done
  printf '{"total_count":%s,"check_runs":[%s]}\n' "$n" "$rs" > "$G/checks.json"; }
mk(){ # mk [head branch]: a fresh $G in which every gate passes for PR head $H on <head branch> (default integration/e9)
  hb=${1:-$IB}; rm -rf "$G"; mkdir -p "$G"; : > "$G/calls"
  pr OPEN false "$H" main "$hb" false 1 founder-approved human-gate-accepted
  files code.rs
  printf '{"total_count":6,"check_runs":[{"name":"rust / check","status":"completed","conclusion":"success"},{"name":"rust / secrets","status":"completed","conclusion":"success"},{"name":"rust / web","status":"completed","conclusion":"success"}]}\n{"total_count":6,"check_runs":[{"name":"chain (a)","status":"completed","conclusion":"success"},{"name":"chain (b)","status":"completed","conclusion":"success"},{"name":"lint","status":"completed","conclusion":"skipped"}]}\n' > "$G/checks.json"
  printf '{"state":"pending","total_count":0,"statuses":[]}\n' > "$G/status.json"
  activity "$hb" "$H" 2026-10-06T11:00:00Z
  timeline 2026-10-06T12:00:00Z 2026-10-06T15:05:00.5+03:00
  printf '{"total_count":2,"workflow_runs":[{"id":7001,"head_sha":"%s","status":"completed","conclusion":"failure"},{"id":7002,"head_sha":"%s","status":"completed","conclusion":"success"}]}\n' "$H" "$H" > "$G/nightly.json"
  printf '{"total_count":2,"jobs":[{"name":"replay","status":"completed","conclusion":"success"},{"name":"chain","status":"completed","conclusion":"failure"}]}\n' > "$G/jobs-7001.json"
  printf '{"total_count":2,"jobs":[{"name":"replay","status":"completed","conclusion":"success"},{"name":"chain","status":"completed","conclusion":"success"}]}\n' > "$G/jobs-7002.json"
  content review "$(printf 'Milestone review of e9, a longer first line so that the base64 text wraps over several lines\ncodex-last-read: %s\n' "$X")"
  content decisions "$(printf '# Decisions\n- D-090 | 2026-10-06 | a recorded residual | r | t\n')"
  compare ahead "$RV"; }
EX=ephremdeme/exchange; GA=ephremdeme/game; KE=ephremdeme/kefa; MS="--milestone e9"; LB=opus/x
# Rule 1: arguments.
H8=$(printf '%s' "$H" | cut -c1-8)
mk; refused "a short SHA" "$H8 is not a full 40-character lowercase hex SHA\$" $EX 12 "$H8"
mk; refused "an upper-case SHA" "[0-9A-F]{40} is not a full 40-character lowercase hex SHA\$" $EX 12 "$(printf '%s' "$H" | tr a-f A-F)"
mk; refused "a foreign owner" 'someone/exchange is not ephremdeme/\{exchange,standards,game,kefa\}$' someone/exchange 12 "$H"
mk; refused "an unlisted ephremdeme repository" 'ephremdeme/payments is not ephremdeme/' ephremdeme/payments 12 "$H"
mk; refused "hub (no CI)" 'ephremdeme/hub has no CI; merge-pr does not merge its PRs$' ephremdeme/hub 12 "$H"
mk; refused "a PR number that is not a number" '12x is not a PR number$' $EX 12x "$H"
mk; refused "--residual without --milestone" '--residual applies to milestone PRs only$' $EX 12 "$H" --residual D-090
mk; refused "--smoke-log outside standards" '--smoke-log applies to ephremdeme/standards only$' $EX 12 "$H" --smoke-log "$T/none"
mk; refused "a milestone id with a path in it" "e9/\.\. is not a milestone id\$" $EX 12 "$H" --milestone e9/..
# A milestone id needs no digit (exchange gp, PR #23, 2026-10-20: `gp` was refused although local-gate accepts it); it
# still starts with a lowercase letter and holds only lowercase letters, digits and dots.
mk integration/9x; refused "a milestone id starting with a digit" "9x is not a milestone id\$" $EX 12 "$H" --milestone 9x
mk integration/Gp; refused "an upper-case milestone id" "Gp is not a milestone id\$" $EX 12 "$H" --milestone Gp
mk integration/go-port; refused "a milestone id with a hyphen" "go-port is not a milestone id\$" $EX 12 "$H" --milestone go-port
mk integration/go-port; refused "a digit-less id on another integration branch" '--milestone gp does not match the head branch integration/go-port \(integration/gp expected\)$' $EX 12 "$H" --milestone gp
mk; refused "a residual id that is not D-NNN" 'D-9x is not a decision id \(D-NNN\)$' $EX 12 "$H" $MS --residual D-9x
# Rule 2: the PR.
mk; pr CLOSED false "$H" main $IB false 1; refused "a closed PR" 'PR #12 is CLOSED, not OPEN$' $EX 12 "$H" $MS
mk; pr OPEN true "$H" main $IB false 1; refused "a draft PR" 'PR #12 is a draft$' $EX 12 "$H" $MS
mk; pr OPEN false "$H" main $IB true 1 founder-approved human-gate-accepted; refused "a cross-repository PR" 'PR #12 comes from another repository \(isCrossRepository\)$' $EX 12 "$H" $MS
mk; pr OPEN false "$X" main $IB false 1; refused "a head mismatch" "PR #12 head is $X, not $H\$" $EX 12 "$H" $MS
mk; pr OPEN false "$H" integration/e8 $IB false 1; refused "a base that is not main" 'PR #12 base is integration/e8, not main$' $EX 12 "$H" $MS
mk; printf '{"state":"OPEN","headRefOid":"%s"}\n' "$H" > "$G/pr.json"; refused "pr view JSON without the other fields" 'gh pr view returned unreadable JSON$' $EX 12 "$H"
mk; echo 'HTTP 502: Bad Gateway' > "$G/pr.err"; refused "gh pr view failing" 'gh pr view failed: HTTP 502: Bad Gateway$' $EX 12 "$H"
mk; refused "an integration branch without --milestone" "PR #12 head branch $IB is a milestone branch: --milestone e9 is required\$" $EX 12 "$H"
mk integration/e8; refused "--milestone not matching the integration branch" '--milestone e9 does not match the head branch integration/e8 \(integration/e9 expected\)$' $EX 12 "$H" $MS
mk $LB; refused "--milestone on a lane branch" '--milestone e9 does not match the head branch opus/x \(integration/e9 expected\)$' $EX 12 "$H" $MS
# Rule 3: checks on the exact SHA, pinned names per repository, the legacy commit status.
mk $LB; checks; refused "zero check runs" "no check runs on $H\$" $EX 12 "$H"
mk $LB; printf '{"total_count":1,"check_runs":[{"name":"chain (b)","status":"in_progress","conclusion":null}]}\n' > "$G/checks.json"
refused "one pending check run" "check run 'chain \(b\)' on $H is in_progress, not completed\$" $EX 12 "$H"
mk $LB; checks "rust / check/success" "rust / secrets/success" "rust / web/success" "chain (a)/success" "lint/failure"
refused "an unpinned check run failed" "check run 'lint' on $H concluded failure\$" $EX 12 "$H"
mk $LB; checks "rust / check/success" "rust / secrets/success" "rust / web/success" "chain (a)/success" "lint/timed_out"
refused "an unpinned check run timed out" "check run 'lint' on $H concluded timed_out\$" $EX 12 "$H"
mk $LB; checks "rust / check/success" "rust / secrets/success" "chain (a)/success"
refused "a pinned check run missing (exchange rust / web)" "pinned check run 'rust / web' is missing on $H\$" $EX 12 "$H"
mk $LB; checks "rust / check/success" "rust / secrets/success" "rust / web/success"
refused "no chain (*) run on exchange" "pinned check run 'chain \(\*\)' is missing on $H\$" $EX 12 "$H"
mk $LB; checks "rust / check/success" "rust / secrets/skipped" "rust / web/success" "chain (a)/success"
refused "a pinned check run skipped" "pinned check run 'rust / secrets' on $H concluded skipped, not success\$" $EX 12 "$H"
mk $LB; checks "rust / check/failure" "rust / secrets/success" "rust / web/success" "chain (a)/success"
refused "a pinned check run failed" "pinned check run 'rust / check' on $H concluded failure, not success\$" $EX 12 "$H"
mk $LB; checks "rust / check/success" "rust / secrets/success" "rust / web/success" "chain (a)/success" "chain (b)/neutral"
refused "one chain (*) run neutral while another succeeded" "pinned check run 'chain \(b\)' on $H concluded neutral, not success\$" $EX 12 "$H"
mk $LB; checks "rust / check/success" "rust / secrets/success" "chain (a)/success"
refused "a pinned check run missing (game rust / web)" "pinned check run 'rust / web' is missing on $H\$" $GA 12 "$H"
mk $LB; printf '{"total_count":3,"check_runs":[{"name":"a","status":"completed","conclusion":"success"},{"name":"b","status":"completed","conclusion":"success"}]}\n' > "$G/checks.json"
refused "a page of check runs missing (2 of 3 read)" "check runs on $H: incomplete \(2 of 3 read\)\$" $EX 12 "$H"
mk $LB; : > "$G/checks.json"; refused "an empty check-runs reply" "check runs on $H: unreadable JSON\$" $EX 12 "$H"
mk $LB; echo 'HTTP 403: API rate limit exceeded' > "$G/checks.err"; refused "the check-runs API failing" 'gh api check-runs failed: HTTP 403: API rate limit exceeded$' $EX 12 "$H"
mk $LB; printf '{"state":"failure","total_count":1,"statuses":[{"context":"ci/legacy","state":"failure"}]}\n' > "$G/status.json"
refused "a failed legacy commit status" "commit status on $H is failure \(1 status\(es\)\)\$" $EX 12 "$H"
mk $LB; printf '{"state":"pending","total_count":1,"statuses":[{"context":"ci/legacy","state":"pending"}]}\n' > "$G/status.json"
refused "a pending legacy commit status" "commit status on $H is pending \(1 status\(es\)\)\$" $EX 12 "$H"
mk $LB; echo 'HTTP 500: boom' > "$G/status.err"; refused "the commit-status API failing" 'gh api commit status failed: HTTP 500: boom$' $EX 12 "$H"
# Rule 3, standards: the smoke log instead of PR CI.
SL="$T/smoke.log"; ST=ephremdeme/standards
mk $LB; refused "standards without a smoke log" 'ephremdeme/standards has no PR CI: --smoke-log <path> is required$' $ST 9 "$H"
mk $LB; printf 'PASS    a\nFAIL    b\nsmoke-head: %s\n' "$H" > "$SL"; refused "a smoke log with a FAIL line" "smoke log $SL has 1 FAIL line\(s\)\$" $ST 9 "$H" --smoke-log "$SL"
mk $LB; printf 'all good\nsmoke-head: %s\n' "$H" > "$SL"; refused "a smoke log without a PASS line" "smoke log $SL has no PASS line\$" $ST 9 "$H" --smoke-log "$SL"
mk $LB; printf 'PASS    a\nsmoke-head: %s\n' "$X" > "$SL"; refused "a smoke log for another SHA" "smoke log $SL is for $X, not $H\$" $ST 9 "$H" --smoke-log "$SL"
mk $LB; printf 'PASS    a\nsmoke-head: %s\nsmoke-head: %s\n' "$H" "$X" > "$SL"; refused "a smoke log naming two heads" "smoke log $SL is for $X, not $H\$" $ST 9 "$H" --smoke-log "$SL"
mk $LB; printf 'PASS    a\n' > "$SL"; refused "a smoke log without a smoke-head line" "smoke log $SL has no smoke-head line\$" $ST 9 "$H" --smoke-log "$SL"
mk $LB; refused "a smoke log that does not exist" "smoke log $T/none is not a readable file\$" $ST 9 "$H" --smoke-log "$T/none"
# Rule 3, exchange and game: the local gate log (bin/local-gate) instead of the check runs and the status (D-109).
LL="$T/local.log"; GHL="gate-head: $H"; V8='verify:e8 — 4 ok, 0 failed'; V9='verify:e9 — 5 ok, 0 failed'
glog(){ printf '%s\n' "$@" > "$LL"; }   # glog <line>...: the local gate log, exactly these lines
nochecks(){ # a read of the check runs, the commit status or the nightly runs fails loudly
  echo 'HTTP 599: check runs must not be read' > "$G/checks.err"; echo 'HTTP 599: the status must not be read' > "$G/status.err"
  echo 'HTTP 599: nightly runs must not be read' > "$G/nightly.err"; }
mk $LB; glog 'check: OK' "$V9" "$GHL"; refused "--local-log on standards" '--local-log applies to ephremdeme/\{exchange,game,kefa\} only \(ephremdeme/standards uses --smoke-log\)$' $ST 9 "$H" --local-log "$LL"
mk $LB; printf 'PASS    a\nsmoke-head: %s\n' "$H" > "$SL"
refused "--local-log together with --smoke-log (exchange)" '--local-log and --smoke-log cannot be given together$' $EX 12 "$H" --local-log "$LL" --smoke-log "$SL"
refused "--smoke-log together with --local-log (standards)" '--local-log and --smoke-log cannot be given together$' $ST 9 "$H" --smoke-log "$SL" --local-log "$LL"
mk $LB; nochecks; refused "a local log that does not exist" "local log $T/none is not a readable file\$" $EX 12 "$H" --local-log "$T/none"
mk $LB; nochecks; : > "$LL"; refused "an empty local log" "local log $LL is empty\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'PASS  rust fmt' 'check: OK' 'FAIL  rust tests' 'check: FAILED' "$V9" "$GHL"
refused "a local log with check: FAILED" "local log $LL has 1 check: FAILED line\(s\)\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' '[ok]   a' '[FAIL] b (rc=1, wanted 0, /x/)' "$V9" "$GHL"
refused "a local log with a [FAIL] line" "local log $LL has 1 \[FAIL\] line\(s\)\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' "$V8" 'verify:e9 — 4 ok, 1 failed' "$GHL"
refused "a local log with a verify line of 1 failed" "local log $LL has 1 verify line\(s\) with failures \(first: verify:e9 — 4 ok, 1 failed\)\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog "$V9" "$GHL"; refused "a local log without check: OK" "local log $LL has no check: OK line\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' "$GHL"
refused "a local log without a verify line" "local log $LL has no passing verify line \(verify:<id> — N ok, 0 failed with N >= 1\)\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' 'verify:e9 — 0 ok, 0 failed' "$GHL"
refused "a local log whose only verify line has 0 ok" "local log $LL has no passing verify line \(verify:<id> — N ok, 0 failed with N >= 1\)\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' 'verify:e9 - 5 ok, 0 failed' "$GHL"
refused "a local log whose verify line has a hyphen, not the em dash" "local log $LL has no passing verify line \(verify:<id> — N ok, 0 failed with N >= 1\)\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' "$V9" 'gate-tree: clean'; refused "a local log without gate-head" "local log $LL has no gate-head line\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' "$V9" "gate-head: $X"; refused "a local log for another SHA" "local log $LL is for $X, not $H\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' "$V9" "$GHL" "gate-head: $X"; refused "a local log naming two heads" "local log $LL is for $X, not $H\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' "$V9" "gate-head: $H8"
refused "a local log whose gate-head is not 40 lowercase hex" "local log $LL has a gate-head line that is not 'gate-head: <40 lowercase hex>': gate-head: $H8\$" $GA 12 "$H" --local-log "$LL"
# The tree at the end and the gate's own verdict (review blocker and major): chained instruments print green verify
# lines of their own before the outer run dies, so only gate-verdict says the gate passed.
GT='gate-tree: clean'; GV9='gate-verdict: green e9'
mk $LB; nochecks; glog 'check: OK' "$V9" "$GHL" 'gate-tree: dirty (README)' "$GV9"
refused "a local log with gate-tree: dirty" "local log $LL has gate-tree: dirty \(README\), not gate-tree: clean\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' "$V9" "$GHL" "$GV9"
refused "a local log without gate-tree" "local log $LL has no gate-tree: clean line\$" $GA 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' 'verify:m0 — 3 ok, 0 failed' 'verify: another verify chain is running on this machine; wait (stale? rmdir /tmp/verify.lock.d)' "$GHL" "$GT"
refused "the review's log: a chained green verify:m0, the verify lock refusing the outer run, no verdict" "local log $LL has no gate-verdict: green line\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' "$V9" "$GHL" "$GT" 'gate-verdict: red — scripts/verify/e9.sh exited 3'
refused "a local log whose gate verdict is red" "local log $LL has a red gate verdict \(gate-verdict: red — scripts/verify/e9\.sh exited 3\)\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' "$V9" "$GHL" "$GT" "$GV9" "$GV9"
refused "a local log with two gate-verdict: green lines" "local log $LL has 2 gate-verdict lines \(exactly one gate-verdict: green <id> expected\)\$" $EX 12 "$H" --local-log "$LL"
mk $LB; nochecks; glog 'check: OK' "$V8" "$GHL" "$GT" "$GV9"
refused "a gate verdict whose id has no passing verify line" "local log $LL has no verify:e9 — N ok, 0 failed line for its gate-verdict: green e9\$" $EX 12 "$H" --local-log "$LL"
mk; nochecks; glog 'check: OK' "$V8" "$GHL" "$GT" 'gate-verdict: green e8'
refused "a milestone local log whose gate verdict names another milestone" "local log $LL has gate-verdict: green e8, not e9 \(the full chain of e9 is required\)\$" $EX 12 "$H" $MS --local-log "$LL"
check_ "control: ... the nightly runs were not read" '[ -s "$G/calls" ] && ! grep -q nightly "$G/calls"'
# Founder approval forced by the paths a PR changes (.github/**, .claude/**, CODEOWNERS).
mk $LB; pr OPEN false "$H" main $LB false 2; files code.rs .github/workflows/ci.yml
refused "a .github change without founder-approved" 'label founder-approved is not on PR #12 \(required: changes \.github/workflows/ci\.yml\)$' $EX 12 "$H"
mk $LB; pr OPEN false "$H" main $LB false 1; files .claude/settings.json
refused "a .claude change without founder-approved" 'label founder-approved is not on PR #12 \(required: changes \.claude/settings\.json\)$' $EX 12 "$H"
mk $LB; pr OPEN false "$H" main $LB false 1; files docs/CODEOWNERS
refused "a CODEOWNERS change without founder-approved" 'label founder-approved is not on PR #12 \(required: changes docs/CODEOWNERS\)$' $EX 12 "$H"
mk $LB; pr OPEN false "$H" main $LB false 1; printf '[{"filename":"ci.yml","previous_filename":".github/workflows/ci.yml","status":"renamed"}]\n' > "$G/files.json"
refused "a file renamed out of .github without founder-approved" 'label founder-approved is not on PR #12 \(required: changes \.github/workflows/ci\.yml\)$' $EX 12 "$H"
mk $LB; files .github/workflows/ci.yml; activity $LB "$H" 2026-10-06T12:30:00Z
refused "a .github change with founder-approved older than the last push" "label founder-approved was last added at 2026-10-06T12:00:00Z, not after the last push of $LB at 2026-10-06T12:30:00Z\$" $EX 12 "$H"
mk $LB; pr OPEN false "$H" main $LB false 2; refused "a files list shorter than changedFiles" 'PR #12 lists 1 of 2 changed files \(incomplete\)$' $EX 12 "$H"
mk $LB; echo 'HTTP 502: Bad Gateway' > "$G/files.err"; refused "the PR-files API failing" 'gh api pull files failed: HTTP 502: Bad Gateway$' $EX 12 "$H"
# Rule 4: milestone PRs.
mk; printf '{"total_count":0,"workflow_runs":[]}\n' > "$G/nightly.json"; refused "no nightly run" "no nightly\.yml run on $H\$" $EX 12 "$H" $MS
mk; printf '{"total_count":1,"workflow_runs":[{"id":7009,"head_sha":"%s"}]}\n' "$X" > "$G/nightly.json"; refused "a nightly run on another SHA only" "no nightly\.yml run on $H\$" $EX 12 "$H" $MS
mk; printf '{"total_count":1,"jobs":[{"name":"chain","status":"completed","conclusion":"failure"}]}\n' > "$G/jobs-7002.json"
refused "nightly chain failed (in every run on the SHA)" "no nightly\.yml run on $H has every chain job concluded success \(7002: completed/failure; 7001: completed/failure\)\$" $EX 12 "$H" $MS
mk; printf '{"total_count":2,"jobs":[{"name":"chain","status":"completed","conclusion":"success"},{"name":"chain","status":"completed","conclusion":"failure"}]}\n' > "$G/jobs-7002.json"
refused "one of two chain jobs failed" "no nightly\.yml run on $H has every chain job concluded success \(7002: completed/success,completed/failure; 7001: completed/failure\)\$" $EX 12 "$H" $MS
mk; printf '{"total_count":1,"jobs":[{"name":"chain","status":"in_progress","conclusion":null}]}\n' > "$G/jobs-7002.json"
refused "nightly chain still running" "no nightly\.yml run on $H has every chain job concluded success \(7002: in_progress/null; 7001: completed/failure\)\$" $EX 12 "$H" $MS
mk; printf '{"total_count":1,"jobs":[{"name":"replay","status":"completed","conclusion":"success"}]}\n' > "$G/jobs-7002.json"
refused "a nightly run without a chain job" "no nightly\.yml run on $H has every chain job concluded success \(7002: no chain job; 7001: completed/failure\)\$" $EX 12 "$H" $MS
mk; printf '{"total_count":3,"jobs":[{"name":"chain","status":"completed","conclusion":"success"}]}\n' > "$G/jobs-7002.json"
refused "a page of nightly jobs missing" "jobs of run 7002: incomplete \(1 of 3 read\)\$" $EX 12 "$H" $MS
mk; echo 'HTTP 500: boom' > "$G/jobs-7002.err"; refused "the nightly jobs API failing" 'gh api jobs of run 7002 failed: HTTP 500: boom$' $EX 12 "$H" $MS
mk; echo 'HTTP 404: Not Found' > "$G/review.err"; refused "no milestone review file on GitHub at the SHA" "gh api contents of $RV at $H failed: HTTP 404: Not Found\$" $EX 12 "$H" $MS
mk; printf '{"type":"file","encoding":"none","content":""}\n' > "$G/review.json"; refused "a review file the contents API does not return as base64" "contents of $RV at $H: unreadable \(not a base64 file\)\$" $EX 12 "$H" $MS
mk; content review "Milestone review without the line"; refused "codex-last-read missing" "$RV at $H has no codex-last-read line\$" $EX 12 "$H" $MS
mk; content review "$(printf 'codex-last-read: %s\n' "$Y")"; compare diverged "$RV" other.txt
refused "codex-last-read a different SHA (not an ancestor)" "codex-last-read $Y is not $H or an ancestor of it \(compare: diverged\)\$" $EX 12 "$H" $MS
OA=' \(only docs/\*\*, NOTES\.md, DECISIONS\.md and BACKLOG\.md may change\)$'   # exchange D-388: docs may follow the read
mk; compare ahead "$RV" code.rs; refused "code changed after codex-last-read" "commits after codex-last-read $X change code\.rs$OA" $EX 12 "$H" $MS
mk; i=0; set --; while [ $i -lt 300 ]; do i=$((i + 1)); set -- "$@" "$RV"; done; compare ahead "$@"; set --
refused "a compare reply of 300 files (possibly truncated)" "compare $X\.\.\.$H lists 300 files \(possibly truncated\)\$" $EX 12 "$H" $MS
mk; echo 'HTTP 404: No common ancestor' > "$G/compare.err"; refused "the compare API failing" 'gh api compare failed: HTTP 404: No common ancestor$' $EX 12 "$H" $MS
# Exchange D-388 (2026-10-24, "make the whole process leaner"): the cross-model read need not follow the last docs
# commit. After codex-last-read the compare may list docs/** (the review file among them), NOTES.md, DECISIONS.md and
# BACKLOG.md at the root; any other path, a path with .. or a leading /, and either side of a rename is refused.
mk; compare ahead docs/data-inventory.md NOTES.md DECISIONS.md BACKLOG.md
merged "docs/**, NOTES.md, DECISIONS.md and BACKLOG.md after codex-last-read" "merge-pr: OK $EX#12 $H merged milestone e9" $EX 12 "$H" $MS
check_ "... the compare from codex-last-read to the head was read" 'grep -Fqx "api repos/$EX/compare/$X...$H" "$G/calls"'
mk; compare ahead "$RV" docs/data-inventory.md internal/x.go; refused "Go code after codex-last-read beside docs" "commits after codex-last-read $X change internal/x\.go$OA" $EX 12 "$H" $MS
mk; compare ahead "$RV" docs/../internal/x.go; refused "a path that only looks like docs/ (docs/../internal/x.go)" "commits after codex-last-read $X change docs/\.\./internal/x\.go$OA" $EX 12 "$H" $MS
mk; compare ahead "$RV" /docs/x.md; refused "a docs path with a leading /" "commits after codex-last-read $X change /docs/x\.md$OA" $EX 12 "$H" $MS
mk; compare ahead "$RV" NOTES.md.bak; refused "a root file that only starts like NOTES.md (NOTES.md.bak)" "commits after codex-last-read $X change NOTES\.md\.bak$OA" $EX 12 "$H" $MS
mk; printf '{"status":"ahead","ahead_by":1,"total_commits":1,"files":[{"filename":"%s","status":"modified"},{"filename":"docs/y.md","previous_filename":"internal/y.go","status":"renamed"}]}\n' "$RV" > "$G/compare.json"
refused "code renamed into docs/ after codex-last-read (previous_filename internal/y.go)" "commits after codex-last-read $X change internal/y\.go$OA" $EX 12 "$H" $MS
mk; pr OPEN false "$H" main $IB false 1 human-gate-accepted; refused "founder-approved missing on a milestone PR" "label founder-approved is not on PR #12 \(required: milestone branch $IB\)\$" $EX 12 "$H" $MS
mk; activity $IB "$H" 2026-10-06T12:10:00Z
refused "founder-approved added before the last push" "label founder-approved was last added at 2026-10-06T12:00:00Z, not after the last push of $IB at 2026-10-06T12:10:00Z\$" $EX 12 "$H" $MS
mk; activity $IB "$H" 2026-10-06T12:30:00Z
refused "a commit back-dated before the label but pushed after it" "label founder-approved was last added at 2026-10-06T12:00:00Z, not after the last push of $IB at 2026-10-06T12:30:00Z\$" $EX 12 "$H" $MS
mk; activity $IB "$H" 2026-10-06T13:00:00Z force_push
refused "a force push after the label" "label founder-approved was last added at 2026-10-06T12:00:00Z, not after the last push of $IB at 2026-10-06T13:00:00Z\$" $EX 12 "$H" $MS
mk; printf '[%s,%s]\n' "$(lab founder-approved 2026-10-06T12:00:00Z 'github-actions[bot]' Bot)" "$(lab human-gate-accepted 2026-10-06T12:00:00Z)" > "$G/timeline.json"
refused "founder-approved applied by github-actions[bot]" 'label founder-approved has no labeled event by the User ephremdeme in the timeline of PR #12$' $EX 12 "$H" $MS
mk; printf '[%s,%s,%s,%s]\n' "$(lab founder-approved 2026-10-06T12:00:00Z)" "$(lab founder-approved 2026-10-06T12:30:00Z ephremdeme User unlabeled)" "$(lab founder-approved 2026-10-06T12:40:00Z 'github-actions[bot]' Bot)" "$(lab human-gate-accepted 2026-10-06T12:00:00Z)" > "$G/timeline.json"
refused "founder-approved removed, then re-added by a bot" 'label founder-approved was removed at 2026-10-06T12:30:00Z, after its last add by ephremdeme$' $EX 12 "$H" $MS
mk; activity $IB "$X" 2026-10-06T11:00:00Z; refused "the newest push to the branch is another SHA" "the newest push to $IB is $X, not $H\$" $EX 12 "$H" $MS
mk; printf '[]\n' > "$G/activity.json"; refused "no push activity for the branch" "no push activity for refs/heads/$IB\$" $EX 12 "$H" $MS
mk; echo 'HTTP 403: Forbidden' > "$G/activity.err"; refused "the activity API failing" 'gh api activity failed: HTTP 403: Forbidden$' $EX 12 "$H" $MS
mk; printf '[{"event":"labeled","label":{"name":"founder-approved"},"created_at":"yesterday","actor":{"login":"ephremdeme","type":"User"}}]\n' > "$G/timeline.json"
refused "an unparseable date in the timeline" 'the timeline of PR #12 is unreadable$' $EX 12 "$H" $MS
mk; echo 'HTTP 404: Not Found' > "$G/timeline.err"; refused "the timeline API failing" 'gh api timeline failed: HTTP 404: Not Found$' $EX 12 "$H" $MS
mk; pr OPEN false "$H" main $IB false 1 founder-approved; refused "human gate missing" 'human gate: label human-gate-accepted is not on PR #12 and no --residual was given$' $EX 12 "$H" $MS
mk; timeline 2026-10-06T12:00:00Z 2026-10-06T13:30:00+03:00
refused "human gate accepted before the last push (UTC+3 stamp)" "label human-gate-accepted was last added at 2026-10-06T10:30:00Z, not after the last push of $IB at 2026-10-06T11:00:00Z\$" $EX 12 "$H" $MS
mk; pr OPEN false "$H" main $IB false 1 founder-approved; refused "a residual id not in DECISIONS.md" "residual D-099 is not a decision \(- D-099 \|\) in DECISIONS\.md at $H\$" $EX 12 "$H" $MS --residual D-099
# Rule 5 and the positive cases.
mk $LB; echo 'GraphQL: Head branch was modified. Review and try the merge again.' > "$G/merge.err"
want "gh pr merge failing after the checks passed -> exit 1 naming gh's message" 1 '^merge-pr: gh pr merge failed — GraphQL: Head branch was modified' sh "$MP" $EX 12 "$H"
mk $LB; pr OPEN false "$H" main $LB false 1; merged "a lane PR on exchange (no label needed)" "merge-pr: OK $EX#12 $H merged" $EX 12 "$H"
check_ "... check runs, status and files were read for the exact SHA/PR, paginated" 'grep -Fqx "api --paginate repos/$EX/commits/$H/check-runs?per_page=100" "$G/calls" && grep -Fqx "api repos/$EX/commits/$H/status" "$G/calls" && grep -Fqx "api --paginate repos/$EX/pulls/12/files?per_page=100" "$G/calls"'
check_ "... no label evidence was read for it" '! grep -q -e activity -e timeline "$G/calls"'
mk $LB; checks "rust / check/success" "rust / secrets/success" "rust / web/success"; merged "a lane PR on game (three pinned runs, no chain)" "merge-pr: OK $GA#12 $H merged" $GA 12 "$H"
mk $LB; printf 'PASS    a\nPASS    b\nsmoke-head: %s\n' "$H" > "$SL"; merged "standards with a smoke log" "merge-pr: OK $ST#9 $H merged" $ST 9 "$H" --smoke-log "$SL"
check_ "... standards reads no check runs" '! grep -q check-runs "$G/calls"'
mk $LB; files .github/workflows/ci.yml; merged "a .github change with a fresh founder-approved" "merge-pr: OK $EX#12 $H merged" $EX 12 "$H"
check_ "... the push time was read from the activity of its branch" 'grep -Fqx "api repos/$EX/activity?ref=refs/heads/$LB&per_page=100" "$G/calls"'
mk; merged "a milestone merge with both labels" "merge-pr: OK $EX#12 $H merged milestone e9" $EX 12 "$H" $MS
check_ "... the nightly runs, the review file and the compare were read for the exact SHA" 'grep -Fqx "api --paginate repos/$EX/actions/workflows/nightly.yml/runs?head_sha=$H&per_page=100" "$G/calls" && grep -Fqx "api repos/$EX/contents/$RV?ref=$H" "$G/calls" && grep -Fqx "api repos/$EX/compare/$X...$H" "$G/calls"'
mk; pr OPEN false "$H" main $IB false 1 founder-approved; merged "a milestone merge with a recorded residual" "merge-pr: OK $EX#12 $H merged milestone e9" $EX 12 "$H" $MS --residual D-090
greenlog(){ glog 'Mem: 7900 total' 'PASS  rust fmt' 'check: OK' '[ok]   a' "$V8" "$V9" "$GHL" "$GT" "$GV9"; }
mk $LB; pr OPEN false "$H" main $LB false 1; nochecks; greenlog
merged "a lane PR on exchange with a green local gate log" "merge-pr: OK $EX#12 $H merged" $EX 12 "$H" --local-log "$LL"
check_ "... merged without reading the check runs or the commit status" '[ -e "$G/merge" ] && ! grep -q -e check-runs -e /status "$G/calls"'
mk $LB; pr OPEN false "$H" main $LB false 1; nochecks; greenlog
merged "a lane PR on game with a green local gate log" "merge-pr: OK $GA#12 $H merged" $GA 12 "$H" --local-log "$LL"
check_ "... merged without reading the check runs or the commit status" '[ -e "$G/merge" ] && ! grep -q -e check-runs -e /status "$G/calls"'
# kefa (no GitHub Actions): the local gate log only; never the pinned rust / ... check runs.
mk $LB; pr OPEN false "$H" main $LB false 1
refused "a lane PR on kefa without --local-log" 'ephremdeme/kefa has no PR CI: --local-log <path> is required$' $KE 12 "$H"
check_ "... no merge happened and no check runs were read" '[ ! -e "$G/merge" ] && ! grep -q -e check-runs -e /status "$G/calls"'
mk $LB; printf 'PASS    a\nsmoke-head: %s\n' "$H" > "$SL"
refused "a lane PR on kefa with --smoke-log" '--smoke-log applies to ephremdeme/standards only$' $KE 12 "$H" --smoke-log "$SL"
mk $LB; pr OPEN false "$H" main $LB false 1; nochecks; greenlog
merged "a lane PR on kefa with a green local gate log" "merge-pr: OK $KE#12 $H merged" $KE 12 "$H" --local-log "$LL"
check_ "... merged without reading the check runs or the commit status" '[ -e "$G/merge" ] && ! grep -q -e check-runs -e /status "$G/calls"'
mk integration/k1; compare ahead docs/md-reports/k1-milestone-review.md; nochecks
glog 'check: OK' 'verify:k1 — 5 ok, 0 failed' "$GHL" "$GT" 'gate-verdict: green k1'
merged "a kefa milestone merge (k1) with a local gate log" "merge-pr: OK $KE#12 $H merged milestone k1" $KE 12 "$H" --milestone k1 --local-log "$LL"
check_ "... the review file read is k1's" 'grep -Fqx "api repos/$KE/contents/docs/md-reports/k1-milestone-review.md?ref=$H" "$G/calls"'
mk $LB; pr OPEN false "$H" main $LB false 1; nochecks; glog 'check: OK' 'verify:m2_2 — 5 ok, 0 failed' "$GHL" "$GT" 'gate-verdict: green m2_2'
merged "a lane PR on game whose gate is m2_2 (an id with _)" "merge-pr: OK $GA#12 $H merged" $GA 12 "$H" --local-log "$LL"
mk; nochecks; greenlog; merged "a milestone merge with a local gate log" "merge-pr: OK $EX#12 $H merged milestone e9" $EX 12 "$H" $MS --local-log "$LL"
check_ "... no nightly run, check run or status read; the review file and both labels' timing were" '[ -e "$G/merge" ] && ! grep -q -e nightly -e check-runs -e /status "$G/calls" && grep -Fqx "api repos/$EX/contents/$RV?ref=$H" "$G/calls" && grep -q timeline "$G/calls"'
mk integration/gp; compare ahead docs/md-reports/gp-milestone-review.md; nochecks
glog 'check: OK' 'verify:gp — 407 ok, 0 failed' "$GHL" "$GT" 'gate-verdict: green gp'
merged "a milestone merge whose id has no digit (gp)" "merge-pr: OK $EX#12 $H merged milestone gp" $EX 12 "$H" --milestone gp --local-log "$LL"
check_ "... the review file read is gp's" 'grep -Fqx "api repos/$EX/contents/docs/md-reports/gp-milestone-review.md?ref=$H" "$G/calls"'
want "two arguments -> usage, exit 2" 2 '^merge-pr: usage: merge-pr ' sh "$MP" $EX 12
rm -rf "$T"; [ $R -eq 0 ] && echo "merge-pr.t: all cases behave" || echo "merge-pr.t: FAILURES"; exit $R
