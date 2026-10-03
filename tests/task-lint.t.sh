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
Q3='```'
# task <branch> <base> <risk line> [omit section n] [owned line]: a TASK with headings 1-7 and an owned-paths block.
task(){ { printf 'Branch: %s\nBase: %s\n%s\n\n' "$1" "$2" "$3"
  for n in 1 2 3 4 5 6 7; do
    [ "$n" = "${4:-}" ] && continue
    printf '## %s. Section %s\n' "$n" "$n"
    if [ "$n" = 3 ] && [ "${5:-}" != NONE ]; then printf '%sowned\n%s\n%s\n' "$Q3" "${5:-README.md}" "$Q3"; else echo '- x'; fi; echo
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
