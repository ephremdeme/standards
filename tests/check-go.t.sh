#!/bin/sh
# Judge for bin/check's Go block (exchange D-158): a checkout with go.mod runs `make gen`, the committed-output check
# (make gen changed nothing in the working tree), `make lint` and `make test`, outside the build lock. Fixture git repos;
# stub make/go/gitleaks (and a git wrapper for the snapshot control) first on a PATH that holds no real make or go.
# Every case asserts its own line. Run: sh standards/tests/check-go.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d) || { echo "FAIL    mktemp -d"; exit 1; }; R=0
TMPDIR=$T; export TMPDIR
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset DATABASE_URL OTHER_SECRET

# A system PATH with only the tools check and the stubs need: real make and go are never reachable.
mkdir -p "$T/sys" "$T/stub" "$T/ctl"
for t in sh git mktemp xargs cat rm tail sed grep dirname diff cmp awk mkdir head tr wc sort; do
  p=$(command -v "$t") || { echo "FAIL    tool $t missing: the judge cannot run (BLOCKED)"; rm -rf "$T"; exit 1; }
  ln -s "$p" "$T/sys/$t"
done
REALGIT=$(command -v git); TRUE=$T/stub/quiet  # a diff driver that prints nothing (product diff config controls)

# Stub make: records its target and the DATABASE_URL / OTHER_SECRET it received; gen creates ctl/gen-ran, then runs
# ctl/gen.sh when present; ctl/fail-<target> makes that target fail.
cat > "$T/stub/make" <<EOF
#!/bin/sh
echo "\$1" >> "$T/make.log"
if [ "\$1" = gen ]; then : > "$T/ctl/gen-ran"; fi
printf 'DB=[%s] OTHER=[%s]\n' "\${DATABASE_URL:-}" "\${OTHER_SECRET:-}" >> "$T/make.env"
if [ "\$1" = gen ] && [ -f "$T/ctl/gen.sh" ]; then sh "$T/ctl/gen.sh" || exit 1; fi
if [ -f "$T/ctl/fail-\$1" ]; then echo "stub make: \$1 told to fail"; exit 1; fi
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/stub/go"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/gitleaks"; printf '#!/bin/sh\nexit 0\n' > "$TRUE"; chmod +x "$TRUE"
# Git wrapper for the snapshot controls: the subcommand <sub> (first argument after any `-c <k=v>` options) fails when
# ctl/git-fail-<sub>-before exists and gen has not run yet, or ctl/git-fail-<sub>-after exists and gen has run.
cat > "$T/stub/git" <<EOF
#!/bin/sh
sub=; skip=0
for a do
  if [ \$skip -eq 1 ]; then skip=0; continue; fi
  case "\$a" in -c) skip=1;; -*) ;; *) sub=\$a; break;; esac
done
when=before; if [ -f "$T/ctl/gen-ran" ]; then when=after; fi
if [ -n "\$sub" ] && [ -f "$T/ctl/git-fail-\$sub-\$when" ]; then echo "stub git: \$sub refused (\$when gen)" >&2; exit 1; fi
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/stub/make" "$T/stub/go" "$T/stub/gitleaks" "$T/stub/git"

P="$T/p"
fixture(){ # fixture [nogomod] [nomakefile] [agents]: a fresh repo with one commit; resets the control files and logs
  if [ -d "$P" ]; then chmod -R u+rwX "$P"; fi
  rm -rf "$P" "$T/ctl" "$T/make.log" "$T/make.env"; mkdir -p "$P/gen" "$T/ctl"
  git init -q -b main "$P"; echo x > "$P/README.md"; printf '.env\n' > "$P/.gitignore"
  printf 'package gen // v1\n' > "$P/gen/out.go"
  case " $* " in *" nogomod "*) ;; *) printf 'module example.com/p\n' > "$P/go.mod";; esac
  case " $* " in *" nomakefile "*) ;; *) printf 'gen:\nlint:\ntest:\n' > "$P/Makefile";; esac
  case " $* " in *" agents "*) mkdir -p "$P/.claude/agents" "$P/standards/agents"
    printf 'agent\n' > "$P/.claude/agents/a.md"; printf 'agent\n' > "$P/standards/agents/a.md";; esac
  git -C "$P" add -A; git -C "$P" commit -qm base
}
commit_extra(){ git -C "$P" add -A; git -C "$P" commit -qm extra; }
run(){ # run [-make] [-go] [+git] [-- check args...]: HOME with the chosen stubs, PATH = stubs + $T/sys only
  rm -rf "$T/h"; mkdir -p "$T/h/.local/bin"; skip_make=0; skip_go=0; wrap=0
  while [ $# -gt 0 ]; do case "$1" in -make) skip_make=1;; -go) skip_go=1;; +git) wrap=1;; --) shift; break;; esac; shift; done
  cp "$T/stub/gitleaks" "$T/h/.local/bin/"
  [ $skip_make -eq 1 ] || cp "$T/stub/make" "$T/h/.local/bin/"
  [ $skip_go -eq 1 ] || cp "$T/stub/go" "$T/h/.local/bin/"
  [ $wrap -eq 0 ] || cp "$T/stub/git" "$T/h/.local/bin/"
  env HOME="$T/h" PATH="$T/sys" sh -c 'cd "$1" || exit 9; shift; exec sh "$@"' _ "$P" "$S/bin/check" "$@" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
has(){ grep -Eq -- "$1" "$T/out"; }
# in_block <line prefix> <text>: <text> appears in the indented block printed right after the line starting <prefix>
in_block(){ A=$1 B=$2 awk 'index($0, ENVIRON["A"]) == 1 { p = 1; next } p && /^      / { if (index($0, ENVIRON["B"])) ok = 1; next } { p = 0 } END { exit !ok }' "$T/out"; }
# block <line prefix>: the indented block printed right after the line starting <prefix>, indentation removed
block(){ A=$1 awk 'index($0, ENVIRON["A"]) == 1 { p = 1; next } p && /^      / { print substr($0, 7); next } { p = 0 }' "$T/out"; }
# changed_eq <line>: the committed step's block holds exactly this line
changed_eq(){ block "FAIL  $C" | grep -qxF -- "$1"; }
makelog(){ if [ -f "$T/make.log" ]; then tr '\n' ' ' < "$T/make.log"; fi; }
rc(){ cat "$T/rc"; }
show(){ tail -n 8 "$T/out" | sed 's/^/        /'; }
judge(){ # judge <label> <condition...>
  label=$1; shift; if "$@"; then ok "$label"; else bad "$label (rc=$(rc), make: $(makelog))"; show; fi; }

C='generated code committed (make gen changed nothing)'
CE='generated code committed \(make gen changed nothing\)'

# (a) all green
fixture; printf 'printf "package gen // v1\\n" > gen/out.go\n' > "$T/ctl/gen.sh"; run
judge "(a) Go module, all green: four PASS lines, check: OK, make gen lint test in order" sh -c '
  [ "$(cat "$1/rc")" = 0 ] && grep -q "^PASS  go generate (make gen)$" "$1/out" && grep -q "^PASS  $2$" "$1/out" &&
  grep -q "^PASS  go lint (make lint)$" "$1/out" && grep -q "^PASS  go tests (make test)$" "$1/out" &&
  grep -q "^check: OK$" "$1/out" && [ "$(tr "\n" " " < "$1/make.log")" = "gen lint test " ]' _ "$T" "$C"

committed_fail(){ # committed_fail <path that must be named>
  [ "$(rc)" = 1 ] && has '^PASS  go generate \(make gen\)$' && has "^FAIL  $CE\$" && changed_eq "changed: $1" && has '^check: FAILED$'; }
# (b) gen modifies a tracked file
fixture; printf 'printf "package gen // v2\\n" > gen/out.go\n' > "$T/ctl/gen.sh"; run
judge "(b) control: gen modifies a tracked file -> FAIL committed step naming gen/out.go" committed_fail gen/out.go
# (c) gen writes a new untracked file
fixture; printf 'printf "package gen\\n" > gen/new_gen.go\n' > "$T/ctl/gen.sh"; run
judge "(c) control: gen writes a new untracked file -> FAIL committed step naming gen/new_gen.go" committed_fail gen/new_gen.go
# (d) gen rewrites an already-modified file differently (git status --porcelain is the same before and after)
fixture; printf 'package gen // lane edit\n' > "$P/gen/out.go"; printf 'printf "package gen // v2\\n" > gen/out.go\n' > "$T/ctl/gen.sh"; run
judge "(d) control: gen rewrites an already-modified file differently -> FAIL committed step naming gen/out.go" committed_fail gen/out.go
# (e) uncommitted lane work that gen does not touch
fixture; printf 'lane work\n' >> "$P/README.md"; printf 'draft\n' > "$P/notes.txt"
printf 'printf "package gen // v1\\n" > gen/out.go\n' > "$T/ctl/gen.sh"; run
judge "(e) uncommitted lane work that gen does not touch -> committed step PASS, check: OK" sh -c '
  [ "$(cat "$1/rc")" = 0 ] && grep -q "^PASS  $2$" "$1/out" && grep -q "^check: OK$" "$1/out"' _ "$T" "$C"
# (f) lint fails / test fails
fixture; : > "$T/ctl/fail-lint"; run
judge "(f) control: make lint fails -> FAIL  go lint (make lint) + check: FAILED" sh -c '
  [ "$(cat "$1/rc")" = 1 ] && grep -q "^FAIL  go lint (make lint)$" "$1/out" && grep -q "^check: FAILED$" "$1/out"' _ "$T"
fixture; : > "$T/ctl/fail-test"; run
judge "(f) control: make test fails -> FAIL  go tests (make test) + check: FAILED" sh -c '
  [ "$(cat "$1/rc")" = 1 ] && grep -q "^FAIL  go tests (make test)$" "$1/out" && grep -q "^check: FAILED$" "$1/out"' _ "$T"
# (g) no make / no go on PATH
fixture; run -make
judge "(g) control: no make on PATH -> BLOCKED go (missing tool: make) + check: FAILED" sh -c '
  [ "$(cat "$1/rc")" = 1 ] && grep -q "^BLOCKED go (missing tool: make)$" "$1/out" && grep -q "^check: FAILED$" "$1/out"' _ "$T"
fixture; run -go
judge "(g) control: no go on PATH -> BLOCKED go (missing tool: go) + check: FAILED, make never called" sh -c '
  [ "$(cat "$1/rc")" = 1 ] && grep -q "^BLOCKED go (missing tool: go)$" "$1/out" && grep -q "^check: FAILED$" "$1/out" &&
  [ ! -f "$1/make.log" ]' _ "$T"
# (h) go.mod without a Makefile
fixture nomakefile; run
judge "(h) control: go.mod without a Makefile -> BLOCKED no-Makefile line, make never called" sh -c '
  [ "$(cat "$1/rc")" = 1 ] && grep -q "^BLOCKED go (no Makefile with gen, lint and test targets)$" "$1/out" &&
  grep -q "^check: FAILED$" "$1/out" && [ ! -f "$1/make.log" ]' _ "$T"
# (i) no go.mod
fixture nogomod; run
judge "(i) no go.mod -> SKIP  go (no go.mod), make never called" sh -c '
  [ "$(cat "$1/rc")" = 0 ] && grep -q "^SKIP  go (no go.mod)$" "$1/out" && [ ! -f "$1/make.log" ]' _ "$T"
# (j) --only
fixture; run -- --only rust
judge "(j) --only rust -> SKIP  go (--only rust), make never called" sh -c '
  grep -q "^SKIP  go (--only rust)$" "$1/out" && [ ! -f "$1/make.log" ]' _ "$T"
fixture; run -- --only web
judge "(j) --only web -> SKIP  go (--only web), make never called" sh -c '
  grep -q "^SKIP  go (--only web)$" "$1/out" && [ ! -f "$1/make.log" ]' _ "$T"
fixture agents; run -- --only go
judge "(j) --only go -> Go steps run, SKIP rust and frontend (--only go)" sh -c '
  [ "$(cat "$1/rc")" = 0 ] && grep -q "^SKIP  rust (--only go)$" "$1/out" && grep -q "^SKIP  frontend (--only go)$" "$1/out" &&
  grep -q "^PASS  go tests (make test)$" "$1/out" && [ "$(tr "\n" " " < "$1/make.log")" = "gen lint test " ]' _ "$T"
judge "(j) --only go still runs the always-run steps: agent definitions and both secret scans" sh -c '
  grep -q "^PASS  agent definitions match pinned standards$" "$1/out" && grep -q "^PASS  secret scan (committed history)$" "$1/out" &&
  grep -q "^PASS  secret scan (uncommitted + untracked)$" "$1/out"' _ "$T"
# (k) --only bogus
fixture; run -- --only bogus
judge "(k) control: --only bogus -> usage, exit 2, make never called" sh -c '
  [ "$(cat "$1/rc")" = 2 ] && grep -q "^check: usage: check \[--only " "$1/out" && [ ! -f "$1/make.log" ]' _ "$T"
judge "(k) the usage line names go: check [--only rust|web|go|all]" sh -c '
  grep -q "^check: usage: check \[--only rust|web|go|all\]$" "$1/out"' _ "$T"
# (l) DATABASE_URL from .env reaches make; nothing else from .env does
fixture; printf 'DATABASE_URL=postgres://env\nOTHER_SECRET=leak\n' > "$P/.env"; run
judge "(l) DATABASE_URL from .env reaches every make call; OTHER_SECRET does not" sh -c '
  [ "$(cat "$1/rc")" = 0 ] && [ -f "$1/make.env" ] && [ "$(wc -l < "$1/make.env")" -eq 3 ] &&
  [ "$(grep -c "^DB=\[postgres://env\] OTHER=\[\]$" "$1/make.env")" -eq 3 ]' _ "$T"
# (m) a snapshot that fails after gen fails the committed step closed
snap_fail(){ [ "$(rc)" = 1 ] && has "^FAIL  $CE\$" && in_block "FAIL  $C" "could not snapshot the working tree"; }
fixture; : > "$T/ctl/git-fail-diff-after"; run +git
judge "(m) control: git diff fails after gen -> FAIL committed step: could not snapshot the working tree" snap_fail

# (n) gen rewrites an untracked file that existed before gen
fixture; printf 'package gen // untracked v1\n' > "$P/gen/new_gen.go"
printf 'printf "package gen // untracked v2\\n" > gen/new_gen.go\n' > "$T/ctl/gen.sh"; run
judge "(n) control: gen rewrites a pre-existing untracked file -> FAIL committed step naming gen/new_gen.go" committed_fail gen/new_gen.go
# (o)-(r) every snapshot producer fails closed
fixture; : > "$T/ctl/git-fail-status-after"; run +git
judge "(o) control: git status fails after gen -> could not snapshot the working tree" snap_fail
fixture; : > "$T/ctl/git-fail-ls-files-after"; run +git
judge "(p) control: git ls-files fails after gen -> could not snapshot the working tree" snap_fail
fixture; : > "$T/ctl/git-fail-diff-before"; run +git
judge "(q) control: the BEFORE snapshot fails (git diff before gen) -> could not snapshot the working tree" snap_fail
fixture; printf 'secret draft\n' > "$P/unreadable.txt"; chmod 000 "$P/unreadable.txt"
if cat "$P/unreadable.txt" >/dev/null 2>&1; then bad "(r) the judge runs as a user who can read a mode-000 file: case cannot run (BLOCKED)"
else run; judge "(r) control: an unreadable untracked file (cat fails) -> could not snapshot the working tree" snap_fail; fi
# (s) gen writes a file, then fails: both steps FAIL and the path is named
fixture; printf 'printf "package gen // v2\\n" > gen/out.go\nexit 1\n' > "$T/ctl/gen.sh"; run
judge "(s) control: gen writes gen/out.go then exits 1 -> FAIL go generate and FAIL committed step naming gen/out.go" sh -c '
  [ "$(cat "$1/rc")" = 1 ] && grep -q "^FAIL  go generate (make gen)$" "$1/out" && grep -q "^FAIL  $2$" "$1/out"' _ "$T" "$C"
judge "(s) the committed step names gen/out.go after a failed gen" changed_eq "changed: gen/out.go"
# (t), (u) a product's diff configuration cannot mask a change (textconv, external diff)
fixture; printf '*.go diff=mask\n' > "$P/.gitattributes"; commit_extra; git -C "$P" config diff.mask.textconv "$TRUE"
printf 'package gen // lane edit\n' > "$P/gen/out.go"; printf 'printf "package gen // v2\\n" > gen/out.go\n' > "$T/ctl/gen.sh"; run
judge "(t) control: a textconv that prints nothing does not mask gen's rewrite of gen/out.go" committed_fail gen/out.go
fixture; git -C "$P" config diff.external "$TRUE"
printf 'package gen // lane edit\n' > "$P/gen/out.go"; printf 'printf "package gen // v2\\n" > gen/out.go\n' > "$T/ctl/gen.sh"; run
judge "(u) control: an external diff that prints nothing does not mask gen's rewrite of gen/out.go" committed_fail gen/out.go
# (v) a non-ASCII path is named as is (core.quotePath=false), tracked and untracked
fixture; printf 'package gen // v1\n' > "$P/gen/ü.go"; commit_extra
printf 'printf "package gen // v2\\n" > gen/ü.go\nprintf "x\\n" > gen/é_new.go\n' > "$T/ctl/gen.sh"; run
judge "(v) a tracked non-ASCII path changed by gen is named changed: gen/ü.go" committed_fail gen/ü.go
judge "(v) an untracked non-ASCII path written by gen is named changed: gen/é_new.go" changed_eq "changed: gen/é_new.go"
# (w) twelve changed paths: the first ten sorted, then the count, and the list survives check's 15-line tail
fixture; printf 'for i in 12 03 07 01 10 05 11 02 09 04 08 06; do printf "x\\n" > gen/f$i.go; done\n' > "$T/ctl/gen.sh"; run
block "FAIL  $C" | grep -E '^(changed: |… and )' > "$T/got"
{ printf 'changed: gen/f%s.go\n' 01 02 03 04 05 06 07 08 09 10; echo '… and 2 more'; } > "$T/want"
judge "(w) twelve changed paths -> changed: gen/f01.go .. gen/f10.go in order, then '… and 2 more'" cmp -s "$T/got" "$T/want"

rm -rf "$T"; [ $R -eq 0 ] && echo "check-go.t: all cases behave" || echo "check-go.t: FAILURES"; exit $R
