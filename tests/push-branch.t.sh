#!/bin/sh
# Cases for bin/push-branch (exchange D-086/D-088: the agents' only push path): one branch or one standards release tag,
# fast-forward only, explicit refspec; every other request is refused for its own reason and pushes nothing.
# No network: origin keeps its real URL git@github.com:ephremdeme/<repo>.git, and GIT_SSH_COMMAND (set here, in the
# test's environment only) is a fake ssh that runs git-upload-pack / git-receive-pack against $T/<owner>-<repo>.git.
# The root-commit table is replaced by PUSH_BRANCH_ROOTS_FILE (fixture roots; the script warns when it is set), except
# in ONE case: roots(), extracted from the script and run alone (no push), must name game's real root commit.
# Run: sh standards/tests/push-branch.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); PB="$S/bin/push-branch"; T=$(mktemp -d); R=0
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
check_(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
refused(){ # refused <label> <regex> <repo-dir> <ref>: exit 2 with its own message
  l=$1; r=$2; shift 2; want "control: $l -> refused" 2 "^push-branch: refused — $r" sh "$PB" "$@"; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# The fake ssh: "<host> <git-upload-pack|git-receive-pack> '<owner>/<repo>.git'" -> that command on $T/<owner>-<repo>.git.
cat > "$T/fake-ssh" <<'SSH'
#!/bin/sh
for a; do last=$a; done
case "$last" in "git-upload-pack '"*|"git-receive-pack '"*) ;; *) echo "fake-ssh: unexpected: $*" >&2; exit 1;; esac
cmd=${last%% *}; p=${last#* \'}; p=${p%\'}; p=${p%.git}
case "$p" in */*/*|*..*|'') echo "fake-ssh: bad path $p" >&2; exit 1;; esac
exec "$cmd" "$FAKE_SSH_ROOT/${p%%/*}-${p#*/}.git"
SSH
chmod 755 "$T/fake-ssh"
FAKE_SSH_ROOT=$T; GIT_SSH_COMMAND="$T/fake-ssh"; GIT_SSH_VARIANT=simple; export FAKE_SSH_ROOT GIT_SSH_COMMAND GIT_SSH_VARIANT
U=git@github.com:ephremdeme/standards.git
B="$T/ephremdeme-standards.git"; git init -q --bare -b main "$B"
D="$T/someoneelse-standards.git"; git init -q --bare -b main "$D"   # a decoy a redirect would reach
W="$T/w"; git init -q -b main "$W"; echo a > "$W/f"; git -C "$W" add f; git -C "$W" commit -qm one
git -C "$W" remote add origin "$U"; git -C "$W" push -q origin refs/heads/main:refs/heads/main
W=$(cd "$W" && pwd -P); WROOT=$(git -C "$W" rev-list --max-parents=0 main)
GROOT=5b469d2caa001c168e63498d32ad7637fee837f9   # game's real root commit (git -C <game> rev-list --max-parents=0 HEAD, 2026-10-06)
printf 'standards %s\nexchange %s\nhub 1111111111111111111111111111111111111111\ngame %s\n' "$WROOT" "$WROOT" "$GROOT" > "$T/roots"
printf 'game %s\n' "$WROOT" > "$T/roots-game"   # a fixture whose game row is this checkout's root (and no other row)
G="$T/ephremdeme-game.git"; git init -q --bare -b main "$G"
PUSH_BRANCH_ROOTS_FILE="$T/roots"; export PUSH_BRANCH_ROOTS_FILE
commit_on(){ # commit_on <branch> <start> <file>: one commit on <branch> (created at <start> when new); W stays on main, clean
  if git -C "$W" rev-parse -q --verify "refs/heads/$1" >/dev/null; then git -C "$W" switch -q "$1"; else git -C "$W" switch -q -c "$1" "$2"; fi
  echo "$3" > "$W/$3"; git -C "$W" add "$3"; git -C "$W" commit -qm "$3"; git -C "$W" switch -q main; }
remote_ref(){ git -C "${2:-$B}" rev-parse -q --verify "$1" 2>/dev/null || echo none; }

# Rule 3: the ref itself.
refused "main" "main is never pushed by an agent\$" "$W" main
refused "HEAD" "HEAD is never pushed by an agent\$" "$W" HEAD
refused "a src:dst refspec (opus/a:main)" 'opus/a:main contains ":"' "$W" opus/a:main
refused "a forced refspec (+opus/x)" '\+opus/x contains "\+"' "$W" +opus/x
refused "a range (opus/a..b)" 'opus/a\.\.b contains "\.\."' "$W" opus/a..b
refused "whitespace (opus/a b)" 'opus/a b contains whitespace' "$W" "opus/a b"
refused "a non-allowed prefix (feature/x)" 'feature/x is not an integration/, opus/, fable/ or ds/ branch nor a vN\.N\.N tag$' "$W" feature/x
refused "an upper-case lane name (opus/X)" 'opus/X is not an integration/, opus/, fable/ or ds/ branch nor a vN\.N\.N tag$' "$W" opus/X
refused "an invalid ref name (opus/x.lock)" 'opus/x\.lock is not a valid ref name$' "$W" opus/x.lock
refused "a four-part tag (v1.2.3.4)" 'v1\.2\.3\.4 is not an integration/, opus/, fable/ or ds/ branch nor a vN\.N\.N tag$' "$W" v1.2.3.4
# Rule 1: the repository and its origin.
mkdir "$W/sub"
refused "a subdirectory, not the top level" "$W/sub is not the top level of a git repository\$" "$W/sub" opus/new
commit_on opus/new main n1
git -C "$W" remote set-url origin git@github.com:someoneelse/standards.git
refused "origin owned by someone else" 'origin URL git@github\.com:someoneelse/standards\.git is not github\.com/ephremdeme/\{exchange,standards,game,hub\}$' "$W" opus/new
git -C "$W" remote set-url origin https://github.com/ephremdeme/payments.git
refused "origin an unlisted ephremdeme repository" 'origin URL https://github\.com/ephremdeme/payments\.git is not github' "$W" opus/new
git -C "$W" remote set-url origin "$U"; git -C "$W" config remote.origin.pushurl git@github.com:someoneelse/standards.git
refused "a push URL owned by someone else" 'origin push URL git@github\.com:someoneelse/standards\.git is not github' "$W" opus/new
git -C "$W" config --unset remote.origin.pushurl
git -C "$W" config url.git@github.com:someoneelse/.pushInsteadOf git@github.com:ephremdeme/
refused "a pushInsteadOf redirect to another owner" 'origin push URL git@github\.com:someoneelse/standards\.git is not github' "$W" opus/new
git -C "$W" config --unset url.git@github.com:someoneelse/.pushInsteadOf
git -C "$W" config url.git@github.com:someoneelse/.insteadOf git@github.com:ephremdeme/
refused "an insteadOf redirect to another owner" 'origin URL git@github\.com:someoneelse/standards\.git is not github' "$W" opus/new
git -C "$W" config --unset url.git@github.com:someoneelse/.insteadOf
check_ "control: ... the decoy repository got nothing" '[ -z "$(git -C "$D" for-each-ref)" ]'
git -C "$W" remote set-url origin git@github.com:ephremdeme/hub.git
refused "a checkout pushed into another repository (origin pointed at hub)" 'opus/new does not descend from the root commit of ephremdeme/hub \(1111111111111111111111111111111111111111\)$' "$W" opus/new
git -C "$W" remote set-url origin git@github.com:ephremdeme/game.git
refused "a checkout not from game's root whose origin says ephremdeme/game" "opus/new does not descend from the root commit of ephremdeme/game \\($GROOT\\)\$" "$W" opus/new
check_ "control: ... the game repository got nothing" '[ -z "$(git -C "$G" for-each-ref)" ]'
want "a checkout from the game row's root is pushed to ephremdeme/game (fixture game row = this root)" 0 "^push-branch: OK opus/new $(git -C "$W" rev-parse opus/new)\$" env PUSH_BRANCH_ROOTS_FILE="$T/roots-game" sh "$PB" "$W" opus/new
check_ "... origin game has it at the local tip" '[ "$(remote_ref refs/heads/opus/new "$G")" = "$(git -C "$W" rev-parse opus/new)" ]'
git -C "$W" remote set-url origin git@github.com:ephremdeme/hub.git
want "control: a repository whose root commit is not in the table (fixture without a hub row) -> refused" 2 '^push-branch: refused — the root commit of ephremdeme/hub is unknown here; push hub from its own session$' env PUSH_BRANCH_ROOTS_FILE="$T/roots-game" sh "$PB" "$W" opus/new
# The one case on the REAL table (PUSH_BRANCH_ROOTS_FILE unset): roots() alone, extracted from the script, never pushes.
roots_fn=$(awk '/^roots\(\) \{/,/^}$/' "$PB")
check_ "the real table: roots game prints exactly game's root commit $GROOT" '[ "$(env -u PUSH_BRANCH_ROOTS_FILE sh -c "$roots_fn; roots game" 2>&1)" = "$GROOT" ]'
git -C "$W" remote set-url origin "$U"
git -C "$W" replace "$(git -C "$W" rev-parse opus/new)" "$(git -C "$W" rev-parse main)"
refused "a replace ref" "$W has replace refs \(refs/replace/[0-9a-f]{40}\)\$" "$W" opus/new
git -C "$W" replace -d "$(git -C "$W" rev-parse opus/new)" >/dev/null
echo "$(git -C "$W" rev-parse opus/new)" > "$W/.git/info/grafts"
refused "an info/grafts file" "$W has an info/grafts file \(history substitution\)\$" "$W" opus/new
rm -f "$W/.git/info/grafts"
git clone -q --depth 1 "file://$B" "$T/shallow"; git -C "$T/shallow" remote set-url origin "$U"; git -C "$T/shallow" branch -q opus/sh
refused "a shallow clone" "$(cd "$T/shallow" && pwd -P) is a shallow clone\$" "$T/shallow" opus/sh
# Rule 2: tracked changes.
echo dirty >> "$W/f"
refused "a dirty tracked file" "tracked changes in $W: f\$" "$W" opus/new
git -C "$W" add f
refused "a staged change" "tracked changes in $W: f\$" "$W" opus/new
git -C "$W" reset -q; git -C "$W" checkout -q -- f
check_ "control: ... nothing reached origin" '[ "$(remote_ref refs/heads/opus/new)" = none ]'
# Rule 4: branches.
refused "no such local branch" 'no local branch opus/missing$' "$W" opus/missing
mkdir "$T/hooks"; printf '#!/bin/sh\ntouch "%s"\n' "$T/hook-ran" > "$T/hooks/pre-push"; chmod 755 "$T/hooks/pre-push"
git -C "$W" config core.hooksPath "$T/hooks"
want "a new branch is pushed (with a WARN line for the fixture roots)" 0 "^push-branch: OK opus/new $(git -C "$W" rev-parse opus/new)\$" sh "$PB" "$W" opus/new
check_ "... origin has it at the local tip" '[ "$(remote_ref refs/heads/opus/new)" = "$(git -C "$W" rev-parse opus/new)" ]'
check_ "control: ... the pre-push hook in core.hooksPath did not run" '[ ! -e "$T/hook-ran" ]'
check_ "... the fixture-roots WARN line is printed" 'sh "$PB" "$W" opus/new 2>&1 | grep -q "^push-branch: WARN — root commits read from PUSH_BRANCH_ROOTS_FILE"'
git -C "$W" config --unset core.hooksPath
commit_on opus/new main n2
want "a fast-forward update is pushed" 0 "^push-branch: OK opus/new $(git -C "$W" rev-parse opus/new)\$" sh "$PB" "$W" opus/new
check_ "... origin moved forward" '[ "$(remote_ref refs/heads/opus/new)" = "$(git -C "$W" rev-parse opus/new)" ]'
commit_on integration/e9 main i1
want "an integration branch is pushed" 0 "^push-branch: OK integration/e9 [0-9a-f]{40}\$" sh "$PB" "$W" integration/e9
old=$(remote_ref refs/heads/integration/e9)
commit_on side main s1; git -C "$W" branch -q -f integration/e9 side
refused "a non-fast-forward update" "origin's integration/e9 \($old\) is not an ancestor of the local integration/e9 \(fast-forward only\)\$" "$W" integration/e9
check_ "control: ... origin is unchanged" '[ "$(remote_ref refs/heads/integration/e9)" = "$old" ]'
git -C "$W" remote set-url origin git@github.com:ephremdeme/exchange.git
refused "an unreachable origin (a failed read is never fine)" 'git ls-remote origin refs/heads/opus/new failed' "$W" opus/new
git -C "$W" remote set-url origin "$U"
# Rule 5: tags.
git -C "$W" tag v0.0.9
refused "a lightweight tag" 'v0\.0\.9 is not an annotated tag \(git cat-file -t: commit\)$' "$W" v0.0.9
refused "no such local tag" 'no local tag v9\.9\.9$' "$W" v9.9.9
git -C "$W" tag -a v0.2.0 -m off side
refused "a tag on a commit not in origin/main" "v0\.2\.0 \($(git -C "$W" rev-parse side)\) is not on origin's main\$" "$W" v0.2.0
git -C "$W" tag -a v0.3.0 -m ours main; git -C "$B" tag -a v0.3.0 -m theirs main
refused "a tag origin has at another object" "origin already has v0\.3\.0 at $(git -C "$B" rev-parse v0.3.0), not $(git -C "$W" rev-parse v0.3.0)\$" "$W" v0.3.0
git -C "$W" tag -a v0.1.0 -m release main
git -C "$W" remote set-url origin git@github.com:ephremdeme/exchange.git
refused "a tag outside the standards repository" 'tags are pushed only to ephremdeme/standards, not ephremdeme/exchange$' "$W" v0.1.0
git -C "$W" remote set-url origin "$U"
check_ "control: ... no refused tag reached origin" '[ "$(remote_ref refs/tags/v0.0.9)$(remote_ref refs/tags/v0.2.0)$(remote_ref refs/tags/v0.1.0)" = nonenonenone ] && [ "$(remote_ref refs/tags/v0.3.0)" = "$(git -C "$B" rev-parse v0.3.0)" ]'
want "an annotated tag on origin's main is pushed" 0 "^push-branch: OK v0\.1\.0 $(git -C "$W" rev-parse v0.1.0)\$" sh "$PB" "$W" v0.1.0
check_ "... origin has the same tag object" '[ "$(remote_ref refs/tags/v0.1.0)" = "$(git -C "$W" rev-parse v0.1.0)" ]'
want "a tag already on origin at the same object" 0 "^push-branch: OK v0\.1\.0 $(git -C "$W" rev-parse v0.1.0) already-present\$" sh "$PB" "$W" v0.1.0
want "one argument -> usage, exit 2" 2 '^push-branch: usage: push-branch <repo-dir> <ref>$' sh "$PB" "$W"
rm -rf "$T"; [ $R -eq 0 ] && echo "push-branch.t: all cases behave" || echo "push-branch.t: FAILURES"; exit $R
