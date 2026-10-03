#!/bin/sh
# Cases for bin/owned-paths (C7, NOTES-19 defect 1): ownership is read from ONE explicit field, the ```owned block in
# TASK §3, verbatim; bullets, prose, "never touch" lines and blocks outside §3 are never read. Every refusal exits 2
# with its own message. Run: sh standards/tests/owned-paths.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); O="$S/bin/owned-paths"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 4 | sed 's/^/        /'; fi; }
want_eq(){ # want_eq <label> <expected stdout> <cmd...>: exit 0 and stdout exactly the expected lines
  label=$1; exp=$2; shift 2; out=$("$@" 2>"$T/err"); rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "$exp" ]; then ok "$label"; else bad "$label (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/        got: /'; sed 's/^/        err: /' "$T/err"; fi; }
F="$T/TASK.md"; Q='```'
head3(){ printf '%s\n' 'Branch: opus/x' 'Base: 0' 'Risk: LOW' '' '## 1. Read first' '- x' '' '## 2. What this is' 'x' ''; }
tail47(){ printf '%s\n' '' '## 4. Hard rules' '- never touch web/src/admin/' '' '## 5. Verify' '- x' '' '## 6. Commit subject' 'x' '' '## 7. Binding facts' '- x'; }
# task <line>...: §3 consists of exactly the given lines.
task(){ { head3; echo '## 3. Files you own (touch nothing else)'; printf '%s\n' "$@"; tail47; } > "$F"; }

task '- docs/ (bullet, never read)' 'Prose: also web/src/pages/ is fine.' "${Q}owned" 'api/src/a.rs' '  web/src/components/  ' '' 'docs/*.md' "$Q"
want_eq "the block is printed verbatim (trimmed), trailing / becomes /*, bullets and prose ignored" "$(printf '%s\n' api/src/a.rs 'web/src/components/*' 'docs/*.md')" sh "$O" "$F"
task '- api/src/users/ (nickname.rs (PATCH), mod.rs (export))' "${Q}owned" 'api/src/users/nickname.rs' 'api/src/users/mod.rs' "$Q"
want_eq "defect 1: a bullet with nested parentheses beside the block -> exactly the block's two files" "$(printf '%s\n' api/src/users/nickname.rs api/src/users/mod.rs)" sh "$O" "$F"
{ head3; printf '%s\n' '## 3. Files you own' "${Q}owned" 'docs/a.md' "$Q"; tail47; printf '%s\n' "${Q}owned" 'api/src/x.rs' "$Q"; } > "$F"
want_eq "a block in §7 (an example) is ignored; only §3's block counts" 'docs/a.md' sh "$O" "$F"
want "the §4 'never touch web/src/admin/' line is never read as ownership" 0 '^docs/a\.md$' sh "$O" "$F"

task '- docs/' '- web/src/components/'
want "control: bullets only, no block -> exit 2" 2 '^owned-paths: TASK §3 has no owned-paths block \(a line that is exactly three backticks and "owned"\)$' sh "$O" "$F"
{ head3; printf '%s\n' '## 3. Files you own' '- docs/'; tail47; printf '%s\n' "${Q}owned" 'docs/' "$Q"; } > "$F"
want "control: a block only in §7 -> exit 2 (no block in §3)" 2 'owned-paths: TASK §3 has no owned-paths block' sh "$O" "$F"
task "${Q}owned" 'docs/' "$Q" "${Q}owned" 'api/' "$Q"
want "control: two blocks in §3 -> exit 2" 2 '^owned-paths: TASK §3 has more than one owned-paths block$' sh "$O" "$F"
task "${Q}owned" 'docs/'
want "control: a block left open until the next heading -> exit 2" 2 '^owned-paths: the owned-paths block is not closed$' sh "$O" "$F"
{ head3; printf '%s\n' '## 3. Files you own' "${Q}owned" 'docs/'; } > "$F"
want "control: a block left open until the end of the file -> exit 2" 2 '^owned-paths: the owned-paths block is not closed$' sh "$O" "$F"
task "${Q}owned" '' '   ' "$Q"
want "control: an empty block -> exit 2" 2 '^owned-paths: the owned-paths block lists no paths$' sh "$O" "$F"
inv(){ # inv <label> <line>: a block whose 2nd line is <line> -> exit 2 naming block line 2
  task "${Q}owned" 'docs/' "$2" "$Q"; lit=$(printf '%s' "$2" | sed -e 's/^ *//' -e 's/ *$//' -e 's/[][\.*^$(){}|+?]/\\&/g')
  want "control: $1 -> exit 2" 2 "^owned-paths: invalid owned path on block line 2: $lit\$" sh "$O" "$F"; }
inv "the <paths> placeholder" '<paths>'
inv "two paths on one line with a comma" 'api/src/a.rs, b.rs'
inv "a parenthetical note" 'api/src/ (x)'
inv "a brace list" 'api/src/{a,b}.rs'
inv "an absolute path" '/abs'
inv "a .. segment" '../x'
inv "a .. segment in the middle" 'docs/../api/x.rs'
inv "a pattern owning the whole repo" '*'
inv "a */* pattern owning the whole repo" '*/*'
inv "a backtick-quoted path" '`docs/a.md`'
want "control: no TASK file -> exit 2" 2 "^owned-paths: no TASK file at $T/missing.md\$" sh "$O" "$T/missing.md"
want "control: no argument -> usage, exit 2" 2 '^owned-paths: usage: owned-paths \[--kind\] <TASK\.md>$' sh "$O"
want "control: an unknown option -> usage, exit 2" 2 '^owned-paths: usage: owned-paths \[--kind\] <TASK\.md>$' sh "$O" --kinds "$F"

task "${Q}owned" 'web/src/components/' 'web/src/i18n/keys/en.json' "$Q"
want_eq "--kind: every path under web/ -> web" web sh "$O" --kind "$F"
task "${Q}owned" 'api/src/users/' 'migrations/0009_x.sql' '.sqlx/' 'Cargo.toml' 'Cargo.lock' 'crates/x/' "$Q"
want_eq "--kind: every path Rust (api/, migrations/, .sqlx/, crates/, Cargo.*) -> rust" rust sh "$O" --kind "$F"
task "${Q}owned" 'web/src/components/' 'api/src/users/' "$Q"
want_eq "--kind: web/ and api/ mixed -> all" all sh "$O" --kind "$F"
task "${Q}owned" 'docs/' "$Q"
want_eq "--kind: docs/ -> all" all sh "$O" --kind "$F"
task "${Q}owned" '<paths>' "$Q"
want "control: --kind on an invalid block -> exit 2 with the same message" 2 'invalid owned path on block line 1: <paths>' sh "$O" --kind "$F"
rm -rf "$T"; [ $R -eq 0 ] && echo "owned-paths.t: all cases behave" || echo "owned-paths.t: FAILURES"; exit $R
