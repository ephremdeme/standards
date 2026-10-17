#!/bin/sh
# Cases for bin/dispatch-deepseek (exchange D-161, standards v0.1.24): the lane-scoped `.deepseek-lanes` override of
# `.no-deepseek` (read from the TASK's Base commit only, Base on a remote-tracking ref, exact branch match, a malformed
# file refuses every lane, the lane may not change either file) and the instrument id grammar of TASK §5
# (`scripts/verify/<id>.sh --section <name>`, id `[a-z][a-z0-9_]*`). Fixture: a product repo (not from the standards
# root) with a bare origin, `.no-deepseek` on main and `integration/x` carrying `.deepseek-lanes`, pushed; lanes are cut
# from it. Dry runs (DISPATCH_DRY_RUN=1) with a HOME that trusts the fixture's primary; post-run cases with a stub
# `claude` first on PATH; a stub `df` reporting 100 GB free, so no case depends on this machine's disk.
# Run: sh tests/dispatch-deepseek.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); DD="$S/bin/dispatch-deepseek"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
die(){ echo "FAIL    fixture: $1"; rm -rf "$T"; echo "dispatch-deepseek.t: FAILURES"; exit 1; }
# A HOME of our own: git identity, no system git config, the workspace trust file (written below).
HOME=$T/h; export HOME; GIT_CONFIG_NOSYSTEM=1; export GIT_CONFIG_NOSYSTEM
unset DISPATCH_ALLOW_HIGH DISPATCH_DRY_RUN DS_API_KEY
mkdir -p "$HOME" "$T/bin" "$T/stub" "$T/wt" || die "mkdir"
printf '[user]\n\tname = judge\n\temail = judge@t\n[init]\n\tdefaultBranch = main\n' > "$HOME/.gitconfig"
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/stub 209715200 104857600 104857600 50%% /"\n' > "$T/bin/df"
chmod +x "$T/bin/df"; PATH="$T/bin:$PATH"; export PATH

mkrepo(){ # mkrepo <dir> <1: commit .no-deepseek | 0>: a product repo with an instrument dir and the lane brief
  git init -q "$1" && mkdir -p "$1/web" "$1/scripts/verify" "$1/standards/prompts" || return 1
  printf '.lane-run.log\n.lane-check.log\n' > "$1/.gitignore"; echo x > "$1/web/x.txt"
  printf '#!/bin/bash\nexit 0\n' > "$1/scripts/verify/m0.sh"; printf '#!/bin/bash\nexit 0\n' > "$1/scripts/verify/gp.sh"
  echo 'Lane brief for <ABS_WORKTREE>.' > "$1/standards/prompts/dispatch-brief.md"
  if [ "$2" = 1 ]; then : > "$1/.no-deepseek"; fi
  git -C "$1" add -A && git -C "$1" commit -qm base; }
P=$T/prod; mkrepo "$P" 1 || die "product repo"
git init -q --bare "$T/origin.git" && git -C "$P" remote add origin "$T/origin.git" && git -C "$P" push -q origin main || die "origin"
git -C "$P" checkout -q -b integration/x || die "integration/x"
printf '%s\n' '# Lanes that go to DeepSeek despite .no-deepseek (exchange D-161)' '' 'ds/listed D-161' 'ds/g2-lifecycle D-161' \
  'ds/g2.lifecycle D-161' 'ds/high D-161' 'ds/admin D-161' 'ds/post1 D-161' 'ds/post2 D-161' 'ds/post3 D-161' > "$P/.deepseek-lanes"
git -C "$P" add .deepseek-lanes && git -C "$P" commit -qm lanes && git -C "$P" push -q origin integration/x \
  && git -C "$P" checkout -q main || die "integration/x pushed"
IX=$(git -C "$P" rev-parse integration/x) && MAIN=$(git -C "$P" rev-parse main) || die "rev-parse"
P2=$T/plain; mkrepo "$P2" 0 || die "plain repo"; MAIN2=$(git -C "$P2" rev-parse main) || die "rev-parse plain"
PR=$(cd "$P" && pwd -P) && P2R=$(cd "$P2" && pwd -P) || die "pwd -P"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true},"%s":{"hasTrustDialogAccepted":true}}}\n' "$PR" "$P2R" > "$HOME/.claude.json"

lane(){ # lane <repo> <branch> <start>: W = a new worktree on <branch> cut from <start>
  W=$T/wt/$(printf '%s' "$2" | tr '/' '_'); git -C "$1" worktree add -q -b "$2" "$W" "$3" || die "worktree $2"; }
Q='```'
mktask(){ # mktask <branch> <base> <risk> <§5 line> [<owned path>] [nolint: no §7]: writes $W/TASK.md
  { printf '%s\n' "Branch: $1" "Base: $2" "Risk: $3" '' '## 1. Read first' '- nothing' '' '## 2. What this is' 'Complexity: low' \
      'Tags: none' 'judge lane' '' '## 3. Files you own' "${Q}owned" "${5:-web/}" "$Q" '' '## 4. Hard rules' '- none' '' \
      '## 5. Verify' "- $4" '' '## 6. Commit subject' 'chore: judge'
    if [ "${6:-}" != nolint ]; then printf '%s\n' '' '## 7. Binding facts' '- none'; fi; } > "$W/TASK.md"; }
commit_lanes(){ # commit_lanes <printf format>: commits .deepseek-lanes with these bytes on the lane $W
  printf "$1" > "$W/.deepseek-lanes" && git -C "$W" add .deepseek-lanes && git -C "$W" commit -qm lanes || die "commit .deepseek-lanes"; }
run(){ # run [NAME=value ...]: a dry run of the dispatcher on $W; sets out and rc
  out=$(env "$@" DS_API_KEY=dummy DISPATCH_DRY_RUN=1 sh "$DD" "$W" 2>&1); rc=$?; }
real(){ # real <stub claude body>: a real run with a stub claude first on PATH; sets out and rc
  printf '%s\n' '#!/bin/sh' "$1" > "$T/stub/claude"; chmod +x "$T/stub/claude"
  out=$(env DS_API_KEY=dummy PATH="$T/stub:$PATH" sh "$DD" "$W" 2>&1); rc=$?; }
expect(){ # expect <label> <rc> <regex>...: the exit code and every regex (grep -E on the output)
  label=$1; want_rc=$2; shift 2; miss=""
  for re in "$@"; do printf '%s\n' "$out" | grep -Eq -- "$re" || miss="$miss /$re/"; done
  if [ "$rc" -eq "$want_rc" ] && [ -z "$miss" ]; then ok "$label"
  else bad "$label (rc=$rc want $want_rc; missing:${miss:- none})"; printf '%s\n' "$out" | tail -n 4 | sed 's/^/        /'; fi; }
NEVER='^dispatch-deepseek: refused — this repo never sends code to DeepSeek$'
M0='scripts/verify/m0.sh --section web'
ovr(){ echo "^dispatch-deepseek: \\.no-deepseek overridden for $1 by \\.deepseek-lanes at $2 \\(decision D-161\\)\$"; }
malformed(){ echo "^dispatch-deepseek: refused — \\.deepseek-lanes line $1 is not '<branch> D-<number>'\$"; }

# (a) a listed branch: the override line, then every other check, dry run accepted.
lane "$P" ds/listed "$IX"; WL=$W; mktask ds/listed "$IX" LOW "$M0"; run
expect "(a) listed branch, dry run: the override line names branch, Base and decision; checks passed" 0 "$(ovr ds/listed "$IX")" \
  '^dispatch-deepseek: instrument after the run: scripts/verify/m0\.sh --section web$' '^dispatch-deepseek: checks passed \(dry run, nothing dispatched\)$'
mktask ds/listed "$IX" LOW 'scripts/verify/gp.sh --section lifecycle'; run
expect "(a2) listed branch with a gp.sh section: accepted" 0 "$(ovr ds/listed "$IX")" '^dispatch-deepseek: instrument after the run: scripts/verify/gp\.sh --section lifecycle$'

# (b), (c), (m) instrument ids, in a repo without .no-deepseek.
lane "$P2" ds/gp "$MAIN2"
mktask ds/gp "$MAIN2" LOW 'scripts/verify/gp.sh --section lifecycle'; run
expect "(b) scripts/verify/gp.sh --section lifecycle accepted" 0 '^dispatch-deepseek: instrument after the run: scripts/verify/gp\.sh --section lifecycle$' \
  '^dispatch-deepseek: checks after the run: check --only web, scripts/verify/gp\.sh --section lifecycle$' 'checks passed'
mktask ds/gp "$MAIN2" LOW 'scripts/verify/e4.sh --section ledger'; run
expect "(b2) scripts/verify/e4.sh --section ledger accepted" 0 '^dispatch-deepseek: instrument after the run: scripts/verify/e4\.sh --section ledger$'
mktask ds/gp "$MAIN2" LOW 'scripts/verify/m2_2.sh --section web'; run
expect "(b3) scripts/verify/m2_2.sh --section web still accepted" 0 '^dispatch-deepseek: instrument after the run: scripts/verify/m2_2\.sh --section web$'
mktask ds/gp "$MAIN2" LOW "$M0"; run
expect "(c) scripts/verify/m0.sh --section web still accepted" 0 '^dispatch-deepseek: instrument after the run: scripts/verify/m0\.sh --section web$' 'checks passed'
NOINST="^dispatch-deepseek: refused — TASK §5 names no instrument section \\(scripts/verify/<id>\\.sh --section <name>, <id> as local-gate's: \\[a-z\\]\\[a-z0-9_\\]\\*\\)\$"
mktask ds/gp "$MAIN2" LOW 'scripts/verify/GP.sh --section lifecycle'; run
expect "(m) control: id GP (upper case) -> names no instrument section" 2 "$NOINST"
mktask ds/gp "$MAIN2" LOW 'scripts/verify/../x.sh --section lifecycle'; run
expect "(m2) control: id ../x -> names no instrument section" 2 "$NOINST"
mktask ds/gp "$MAIN2" LOW 'scripts/verify/9x.sh --section lifecycle'; run
expect "(m3) control: id 9x (starts with a digit) -> names no instrument section" 2 "$NOINST"

# (d) an unlisted branch keeps the old refusal.
lane "$P" ds/other "$IX"; mktask ds/other "$IX" LOW "$M0"; run
expect "(d) control: unlisted branch -> never sends code to DeepSeek" 2 "$NEVER"
# (e) the listing only in the worktree (untracked) is never read.
lane "$P" ds/untracked "$IX"; mktask ds/untracked "$IX" LOW "$M0"; printf 'ds/untracked D-161\n' > "$W/.deepseek-lanes"; run
expect "(e) control: .deepseek-lanes listing the lane only untracked in the worktree -> refused" 2 "$NEVER"
# (f) the listing committed on the lane after Base is never read.
lane "$P" ds/selfcommit "$MAIN"; commit_lanes 'ds/selfcommit D-161\n'; mktask ds/selfcommit "$MAIN" LOW "$M0"; run
expect "(f) control: .deepseek-lanes committed on the lane after Base (none at Base) -> refused" 2 "$NEVER"
lane "$P" ds/selfedit "$IX"; commit_lanes 'ds/listed D-161\nds/selfedit D-161\n'; mktask ds/selfedit "$IX" LOW "$M0"; run
expect "(f2) control: the lane edits Base's .deepseek-lanes to list itself -> refused" 2 "$NEVER"
# (g) Base moved to a commit only the lane has: no remote-tracking ref contains it.
lane "$P" ds/movebase "$MAIN"; commit_lanes 'ds/movebase D-161\n'; HB=$(git -C "$W" rev-parse HEAD); mktask ds/movebase "$HB" LOW "$M0"; run
expect "(g) control: Base on no remote-tracking ref -> its own message" 2 \
  "^dispatch-deepseek: refused — \\.deepseek-lanes is read from Base $HB, which no remote-tracking branch contains\$"
# (h) exact match only: prefix, suffix, extension and regex lookalikes stay refused; the listed names themselves pass.
for b in ds/g2-life ds/g2xlifecycle s/g2-lifecycle ds/g2-lifecycle-x; do
  lane "$P" "$b" "$IX"; mktask "$b" "$IX" LOW "$M0"; run
  expect "(h) control: lane $b (ds/g2-lifecycle and ds/g2.lifecycle listed) -> refused" 2 "$NEVER"
done
lane "$P" ds/g2.lifecycle "$IX"; mktask ds/g2.lifecycle "$IX" LOW "$M0"; run
expect "(h0) the listed ds/g2.lifecycle itself: accepted" 0 "$(ovr ds/g2.lifecycle "$IX")" 'checks passed'
# (i) malformed lines refuse every lane, listed or not, each with its own line number.
mal(){ # mal <n> <label> <file bytes as a printf format> <lane line number>
  lane "$P" "ds/mal$1" "$MAIN"; commit_lanes "$3"; mb=$(git -C "$W" rev-parse HEAD); mktask "ds/mal$1" "$mb" LOW "$M0"; run
  expect "(i) control: $2 -> line $4 named" 2 "$(malformed "$4")"; }
mal 1 'a line without a D-number' 'ds/other D-7\nds/x\n' 2
mal 2 'two spaces' 'ds/x  D-7\n' 1
mal 3 'a trailing space' '# ok\nds/x D-7 \n' 2
mal 4 'a CRLF line end' 'ds/x D-7\r\n' 1
mal 5 'D- without digits' 'ds/x D-\n' 1
mal 6 'the lane listed on line 1, a bad line 3' 'ds/mal6 D-161\n\nds/x D-\n' 3
mal 7 'a line of spaces only' 'ds/x D-7\n  \n' 2
mal 8 'a branch that is not <model>/<slug>' 'ds/x/y D-7\n' 1
# (j) a branch listed twice.
lane "$P" ds/dup "$MAIN"; commit_lanes 'ds/a D-1\nds/dup D-2\nds/a D-3\n'; HB=$(git -C "$W" rev-parse HEAD); mktask ds/dup "$HB" LOW "$M0"; run
expect "(j) control: a branch listed twice -> its own message" 2 '^dispatch-deepseek: refused — \.deepseek-lanes lists ds/a more than once$'
# (k), (l) every other refusal still applies to a listed lane.
lane "$P" ds/high "$IX"; mktask ds/high "$IX" HIGH "$M0"; run
expect "(k) control: listed + Risk: HIGH without DISPATCH_ALLOW_HIGH=1 -> not Risk: LOW" 2 \
  '^dispatch-deepseek: refused — TASK is not Risk: LOW \(the header'
lane "$P" ds/admin "$IX"; mktask ds/admin "$IX" HIGH "$M0" web/admin/x.txt; run DISPATCH_ALLOW_HIGH=1
expect "(l) control: listed + an admin path in §3 with DISPATCH_ALLOW_HIGH=1 -> the admin refusal" 2 \
  '^dispatch-deepseek: refused — admin surface in TASK §3 cannot go to DeepSeek even with DISPATCH_ALLOW_HIGH$'
# (p) the old refusal for every case that cannot be an override (smoke 5b: the lane deleted the marker; TASK not linting).
lane "$P" ds/nolint "$IX"; mktask ds/nolint "$IX" LOW "$M0" web/ nolint; run
expect "(p) control: unlisted lane whose TASK does not lint (no §7) -> never sends code to DeepSeek" 2 "$NEVER"
lane "$P" ds/drop "$IX"; git -C "$W" rm -q .no-deepseek && git -C "$W" commit -qm drop || die "drop marker"; mktask ds/drop "$IX" LOW "$M0"; run
expect "(p2) control: unlisted lane that deleted .no-deepseek (primary HEAD has it) -> never sends code to DeepSeek" 2 "$NEVER"
W=$WL; mktask ds/listed integration/x LOW "$M0"; run
expect "(p3) control: listed lane whose Base: is not a full sha -> never sends code to DeepSeek" 2 "$NEVER"
mv "$W/TASK.md" "$T/TASK.keep"; run
expect "(p4) control: no TASK.md -> never sends code to DeepSeek" 2 "$NEVER"
mv "$T/TASK.keep" "$W/TASK.md"

# (n), (o) post-run: a lane that changes .deepseek-lanes or .no-deepseek changed its own judge.
lane "$P" ds/post1 "$IX"; mktask ds/post1 "$IX" LOW "$M0"
real 'echo "ds/evil D-1" >> .deepseek-lanes && git add .deepseek-lanes && git commit -qm lanes'
expect "(n) post-run: a commit changing .deepseek-lanes -> exit 1, lane changed its own judge" 1 '^\.deepseek-lanes$' '^dispatch-deepseek: lane changed its own judge$'
lane "$P" ds/post2 "$IX"; mktask ds/post2 "$IX" LOW "$M0"
real 'git rm -q .no-deepseek && git commit -qm drop'
expect "(o) post-run: a commit deleting .no-deepseek -> exit 1, lane changed its own judge" 1 '^\.no-deepseek$' '^dispatch-deepseek: lane changed its own judge$'
lane "$P" ds/post3 "$IX"; mktask ds/post3 "$IX" LOW "$M0"
real 'git mv .no-deepseek web/marker && git commit -qm rename'
expect "(o2) post-run: a commit renaming .no-deepseek away -> exit 1, lane changed its own judge" 1 '^\.no-deepseek$' '^dispatch-deepseek: lane changed its own judge$'

rm -rf "$T"; [ $R -eq 0 ] && echo "dispatch-deepseek.t: all cases behave" || echo "dispatch-deepseek.t: FAILURES"; exit $R
