#!/bin/sh
# Cases for bin/task-lint (C7, C5 disk floor, NOTES-19 defect 4): every rule is evaluated, each failure is one
# "task-lint: FAIL <rule>: <detail>" line, then FAILED (n rule(s)) exit 1; usage errors exit 2. Free disk comes from a
# stub `df` first on PATH (no bypass variable exists). Run: sh standards/tests/task-lint.t.sh -> exit 0 when all behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); TL="$S/bin/task-lint"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Stub df: 100 GB, 7 GB, and one that fails. Output shape of `df -Pk`: header, then the 4th column is free KiB.
mkdf(){ mkdir -p "$T/$1"; printf '#!/bin/sh\n%s\n' "$2" > "$T/$1/df"; chmod +x "$T/$1/df"; }
mkdf d100 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/stub 209715200 104857600 104857600 50%% /\n"'
mkdf d7 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/stub 209715200 202375168 7340032 97%% /\n"'
mkdf dbad 'echo "df: cannot read" >&2; exit 1'
lint(){ env PATH="$T/d100:$PATH" sh "$TL" "$@"; }
P="$T/p"; git init -q -b main "$P"; printf '.worktrees/\n' > "$P/.gitignore"; echo x > "$P/README.md"
git -C "$P" add -A; git -C "$P" commit -qm base; B=$(git -C "$P" rev-parse HEAD)
git -C "$P" checkout -q -b side; echo s > "$P/side.txt"; git -C "$P" add -A; git -C "$P" commit -qm side; SIDE=$(git -C "$P" rev-parse HEAD); git -C "$P" checkout -q main
git -C "$P" worktree add -q "$P/.worktrees/opus-x" -b opus/x main; W="$P/.worktrees/opus-x"
git -C "$P" worktree add -q "$P/.worktrees/ds-z" -b ds/z main; DW="$P/.worktrees/ds-z"
Q3='```'
NL='
'
D2="Complexity: low${NL}Tags: none"
# task <branch> <base> <risk line> [omit section n] [owned line] [§2's lines] [an extra line in §4]: a TASK with headings
# 1-7, §2's Complexity:/Tags: lines (default: low and none) and an owned-paths block.
task(){ { printf 'Branch: %s\nBase: %s\n%s\n\n' "$1" "$2" "$3"
  for n in 1 2 3 4 5 6 7; do
    [ "$n" = "${4:-}" ] && continue
    printf '## %s. Section %s\n' "$n" "$n"
    [ "$n" = 2 ] && printf '%s\n' "${6-$D2}"
    if [ "$n" = 3 ] && [ "${5:-}" != NONE ]; then printf '%sowned\n%s\n%s\n' "$Q3" "${5:-README.md}" "$Q3"; else echo '- x'; fi
    [ "$n" = 4 ] && [ -n "${7:-}" ] && printf '%s\n' "$7"
    echo
  done; } > "$W/TASK.md"; }
task opus/x "$B" 'Risk: LOW'
want "a valid lane -> task-lint: OK" 0 "^task-lint: OK \($W\)\$" lint "$W"
task opus/x "$B" 'Risk: HIGH'
want "a valid HIGH lane -> OK" 0 'task-lint: OK' lint "$W"
task opus/x "$B" 'Risk: MEDIUM'
want "control: header with Risk: MEDIUM -> FAIL header" 1 '^task-lint: FAIL header: lines 1-3 must be Branch:, Base:, Risk: LOW\|HIGH and the TASK must hold exactly one Risk: line$' lint "$W"
task opus/x "$B" 'Risk: LOW'; printf 'Risk: LOW\n' >> "$W/TASK.md"
want "control: a second Risk: line further down -> FAIL header" 1 '^task-lint: FAIL header: ' lint "$W"
task opus/y "$B" 'Risk: LOW'
want "control: TASK branch differs from the worktree's -> FAIL branch" 1 '^task-lint: FAIL branch: TASK says opus/y, the worktree is on opus/x$' lint "$W"
task 'weird' "$B" 'Risk: LOW'
want "control: a branch that is not <model>/<slug> -> FAIL branch" 1 "^task-lint: FAIL branch: 'weird' is not <model>/<slug> " lint "$W"
task opus/x '<filled at dispatch>' 'Risk: LOW'
want "control: Base: <filled at dispatch> -> FAIL base (not a sha)" 1 "^task-lint: FAIL base: '<filled at dispatch>' is not a full 40-character commit sha\$" lint "$W"
task opus/x 0123456789abcdef0123456789abcdef01234567 'Risk: LOW'
want "control: a 40-hex base that is no commit here -> FAIL base" 1 '^task-lint: FAIL base: 0123456789abcdef0123456789abcdef01234567 is not a commit in this repository$' lint "$W"
task opus/x "$SIDE" 'Risk: LOW'
want "control: a base that is not an ancestor of HEAD -> FAIL base" 1 "^task-lint: FAIL base: $SIDE is not an ancestor of HEAD $B\$" lint "$W"
task opus/x "$B" 'Risk: LOW' '' NONE
want "control: no owned-paths block -> FAIL owned" 1 '^task-lint: FAIL owned: TASK §3 has no owned-paths block' lint "$W"
task opus/x "$B" 'Risk: LOW' '' '<paths>'
want "control: a placeholder in the block -> FAIL owned naming it" 1 '^task-lint: FAIL owned: invalid owned path on block line 1: <paths>$' lint "$W"
task opus/x "$B" 'Risk: LOW' 5
want "control: a missing ## 5. heading -> FAIL sections" 1 '^task-lint: FAIL sections: missing heading ## 5\.$' lint "$W"
task opus/x "$B" 'Risk: LOW'; echo y >> "$W/README.md"
want "control: a modified tracked file -> FAIL clean naming it" 1 '^task-lint: FAIL clean: uncommitted changes besides TASK\.md: README\.md$' lint "$W"
git -C "$W" checkout -q -- README.md; echo n > "$W/new.txt"
want "control: an untracked file besides TASK.md -> FAIL clean" 1 '^task-lint: FAIL clean: uncommitted changes besides TASK\.md: new\.txt$' lint "$W"
rm -f "$W/new.txt"
want "control: 7 GB free (stub df) -> FAIL disk" 1 "^task-lint: FAIL disk: 7(\.0)? GB free on the filesystem of $W, below the 15 GB floor — prune merged lanes \(standards/bin/prune-lane\)\$" env PATH="$T/d7:$PATH" sh "$TL" "$W"
want "control: a failing df -> FAIL disk (fail closed)" 1 "^task-lint: FAIL disk: could not read free space \(df -Pk $W failed\)\$" env PATH="$T/dbad:$PATH" sh "$TL" "$W"
task opus/x '<x>' 'Risk: LOW' 6
out=$(lint "$W" 2>&1); rc=$?
if [ $rc -eq 1 ] && printf '%s\n' "$out" | grep -q '^task-lint: FAIL base: ' && printf '%s\n' "$out" | grep -q '^task-lint: FAIL sections: missing heading ## 6\.$' && printf '%s\n' "$out" | grep -q '^task-lint: FAILED (2 rule(s))$'; then
  ok "two failures in one run -> both lines and FAILED (2 rule(s))"; else bad "two failures in one run (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/        /'; fi
# complexity and tags (docs/07 §1 R6, R1; exchange BACKLOG 44): exactly one line each, inside §2, closed vocabulary.
V='sql authz privacy input crypto destructive checker supply-chain'
task opus/x "$B" 'Risk: LOW' '' '' "Complexity: medium${NL}Tags: sql, privacy"
want "Tags: sql, privacy -> OK" 0 "^task-lint: OK \($W\)\$" lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' "Complexity: high${NL}Tags: supply-chain"
want "Tags: supply-chain -> OK" 0 "^task-lint: OK \($W\)\$" lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' 'Tags: none'
want "control: no Complexity: line -> FAIL complexity" 1 '^task-lint: FAIL complexity: no Complexity: line in §2 \(Complexity: low\|medium\|high\)$' lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' "Complexity: MEDIUM${NL}Tags: none"
want "control: Complexity: MEDIUM -> FAIL complexity naming it" 1 "^task-lint: FAIL complexity: 'MEDIUM' is not low, medium or high\$" lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' "Complexity: low${NL}Complexity: low${NL}Tags: none"
want "control: two Complexity: lines -> FAIL complexity (2 lines)" 1 '^task-lint: FAIL complexity: 2 Complexity: lines, exactly one in §2 is required$' lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' 'Tags: none' 'Complexity: low'
want "control: Complexity: line in §4 only -> FAIL complexity (outside §2)" 1 '^task-lint: FAIL complexity: the Complexity: line is outside §2$' lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' 'Complexity: low'
want "control: no Tags: line -> FAIL tags" 1 "^task-lint: FAIL tags: no Tags: line in §2 \(Tags: none, or a comma-separated list from $V\)\$" lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' "Complexity: low${NL}Tags: privcy"
want "control: Tags: privcy -> FAIL tags naming it" 1 "^task-lint: FAIL tags: 'privcy' is not one of $V\$" lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' "Complexity: low${NL}Tags: none, sql"
want "control: Tags: none, sql -> FAIL tags ('none' stands alone)" 1 "^task-lint: FAIL tags: 'none' stands alone\$" lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' "Complexity: low${NL}Tags: privacy, privacy"
want "control: Tags: privacy, privacy -> FAIL tags (listed twice)" 1 "^task-lint: FAIL tags: 'privacy' listed twice\$" lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' "Complexity: low${NL}Tags: sql,"
want "control: Tags: sql, -> FAIL tags (empty token)" 1 "^task-lint: FAIL tags: '' is not one of $V\$" lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' 'Complexity: low'; printf 'Tags: none\n' >> "$W/TASK.md"
want "control: Tags: line in §7 only -> FAIL tags (outside §2)" 1 '^task-lint: FAIL tags: the Tags: line is outside §2$' lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' "Complexity: low${NL}Tags: "
want "control: empty Tags: line -> FAIL tags" 1 "^task-lint: FAIL tags: empty Tags: line \(Tags: none, or a comma-separated list from $V\)\$" lint "$W"
task opus/x "$B" 'Risk: LOW' 2
out=$(lint "$W" 2>&1); rc=$?
if [ $rc -eq 1 ] && printf '%s\n' "$out" | grep -q '^task-lint: FAIL sections: missing heading ## 2\.$' \
   && printf '%s\n' "$out" | grep -q '^task-lint: FAIL complexity: no Complexity: line in §2 (Complexity: low|medium|high)$' \
   && printf '%s\n' "$out" | grep -q "^task-lint: FAIL tags: no Tags: line in §2 (Tags: none, or a comma-separated list from $V)\$" \
   && printf '%s\n' "$out" | grep -q '^task-lint: FAILED (3 rule(s))$'; then
  ok "control: missing ## 2. heading -> FAIL sections, FAIL complexity, FAIL tags (3 rules)"
else bad "control: missing ## 2. heading -> FAIL sections, FAIL complexity, FAIL tags (3 rules) (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/        /'; fi
W=$DW
task ds/z "$B" 'Risk: LOW' '' '' "Complexity: low${NL}Tags: privacy"
want "control: a ds/ lane with Tags: privacy -> FAIL tags (R1 untagged)" 1 "^task-lint: FAIL tags: a ds/ lane must be untagged \(Tags: none\), got 'privacy' \(docs/07 R1\)\$" lint "$W"
task ds/z "$B" 'Risk: LOW'
want "a ds/ lane with Tags: none -> OK" 0 "^task-lint: OK \($W\)\$" lint "$W"
task ds/z "$B" 'Risk: LOW' '' '' "Complexity: low${NL}Tags: none, sql"
want "control: a ds/ lane with Tags: none, sql -> FAIL tags (none stands alone, before the ds/ rule)" 1 "^task-lint: FAIL tags: 'none' stands alone\$" lint "$W"
W="$P/.worktrees/opus-x"
# Revision: the Tags value is trimmed before the none check and the split; the Complexity value is not.
task opus/x "$B" 'Risk: LOW' '' '' "Complexity: low${NL}Tags: none "
want "Tags: none  (trailing space) -> OK" 0 "^task-lint: OK \($W\)\$" lint "$W"
task opus/x "$B" 'Risk: LOW' '' '' "Complexity: low ${NL}Tags: none"
want "control: Complexity: low  (trailing space) -> FAIL complexity naming it" 1 "^task-lint: FAIL complexity: 'low ' is not low, medium or high\$" lint "$W"
want "control: no argument -> usage, exit 2" 2 '^task-lint: usage: task-lint <absolute worktree>$' lint
want "control: a relative worktree path -> usage, exit 2" 2 '^task-lint: usage: task-lint <absolute worktree>$' lint p/.worktrees/opus-x
mkdir "$T/empty"
want "control: a directory without TASK.md -> exit 2" 2 "^task-lint: no TASK.md in $T/empty\$" lint "$T/empty"

# Defect 4 (NOTES-19): after `merge --ff-only` in a lane worktree the standards gitlink moves but the checkout lags.
SRC="$T/std-src"; git init -q -b main "$SRC"; echo v1 > "$SRC/PIN"; git -C "$SRC" add -A; git -C "$SRC" commit -qm v1
G="$T/game"; git init -q -b main "$G"; printf '.worktrees/\n' > "$G/.gitignore"; git -C "$G" add -A; git -C "$G" commit -qm init
git -C "$G" -c protocol.file.allow=always submodule add -q "$SRC" standards; git -C "$G" commit -qm pin; GB=$(git -C "$G" rev-parse HEAD)
git -C "$G" worktree add -q "$G/.worktrees/opus-q" -b opus/q main; GW="$G/.worktrees/opus-q"
git -C "$GW" -c protocol.file.allow=always -c "submodule.standards.url=$G/standards" submodule update -q --init
W=$GW; task opus/q "$GB" 'Risk: LOW' '' 'docs/'
want "a product lane with an in-sync standards submodule -> OK" 0 'task-lint: OK' lint "$GW"
echo v2 > "$SRC/PIN"; git -C "$SRC" commit -qam v2
git -C "$G/standards" pull -q; git -C "$G" add standards; git -C "$G" commit -qm bump
git -C "$GW" merge -q --ff-only main
want "control: defect 4: gitlink moved by merge --ff-only, checkout lags -> FAIL submodule naming the update command" 1 "^task-lint: FAIL submodule: standards is not at the commit HEAD records \(\+[0-9a-f]{40} standards.*\) — run: git -C $GW -c protocol.file.allow=always -c submodule.standards.url=$G/standards submodule update -q --init\$" lint "$GW"
git -C "$GW" -c protocol.file.allow=always -c "submodule.standards.url=$G/standards" submodule update -q --init
want "defect 4: after the printed update command -> OK" 0 'task-lint: OK' lint "$GW"
rm -rf "$T"; [ $R -eq 0 ] && echo "task-lint.t: all cases behave" || echo "task-lint.t: FAILURES"; exit $R
