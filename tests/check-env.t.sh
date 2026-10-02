#!/bin/sh
# Negative control for bin/check's .env handling and its uncommitted-secret scan (retro review 1 and 15).
# .env is DATA: check takes DATABASE_URL from it literally (bin/read-env) and never executes it. Every case must be
# red for its own reason. Run: sh standards/tests/check-env.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); R=0; REAL_HOME=$HOME
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 4 | sed 's/^/        /'; fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset DATABASE_URL
# A product repo with one commit and nothing else: check's only steps are the two secret scans. A fake HOME puts a
# gitleaks stub first on check's PATH; the stub prints the DATABASE_URL it received and fails, so check shows it.
P="$T/p"; git init -q -b main "$P"; echo x > "$P/README.md"; git -C "$P" add -A; git -C "$P" commit -qm base
mkdir -p "$T/h/.local/bin"; printf '#!/bin/sh\necho "DBURL=[$DATABASE_URL]"\nexit 1\n' > "$T/h/.local/bin/gitleaks"; chmod +x "$T/h/.local/bin/gitleaks"
chk(){ env HOME="$T/h" sh -c 'cd "$1" && sh "$2"' _ "$P" "$S/bin/check" > "$T/out" 2>&1; echo $? > "$T/rc"; }
has(){ grep -Eq -- "$1" "$T/out"; }
verdict(){ # verdict <label> <regex that must appear>
  if [ "$(cat "$T/rc")" = 1 ] && has '^FAIL  secret scan \(committed history\)' && has '^check: FAILED' && has "$2" && ! has FAKE; then ok "$1"
  else bad "$1 (rc=$(cat "$T/rc"), want 1 + steps ran + /$2/ + no FAKE)"; tail -n 6 "$T/out" | sed 's/^/        /'; fi; }

printf 'DATABASE_URL=postgres://x\nexit 0\ncargo() { echo FAKE; }\n' > "$P/.env"; chk
verdict "control: '.env' holding 'exit 0' and a cargo() function does not stop check before its steps" 'DBURL=\[postgres://x\]'
printf 'gitleaks() { echo FAKE; return 1; }\nDATABASE_URL=postgres://y\n' > "$P/.env"; chk
verdict "control: a function defined in .env never replaces a tool (gitleaks stub ran, not FAKE)" 'DBURL=\[postgres://y\]'
printf 'DATABASE_URL="postgres://q/$USER"\n' > "$P/.env"; chk
verdict "control: a double-quoted value loses its quotes and nothing else (no \$USER expansion)" 'DBURL=\[postgres://q/\$USER\]'
printf "DATABASE_URL='postgres://s'\n" > "$P/.env"; chk
verdict "a single-quoted value loses its quotes" 'DBURL=\[postgres://s\]'
printf 'DATABASE_URL="postgres://crlf"\r\nOTHER=1\r\n' > "$P/.env"; chk
verdict "control: a CRLF .env loses the trailing CR, then the quotes" 'DBURL=\[postgres://crlf\]$'
printf 'DATABASE_URL=postgres://first\nDATABASE_URL=postgres://second\n' > "$P/.env"; chk
verdict "control: the first DATABASE_URL line wins (no later line overrides it)" 'DBURL=\[postgres://first\]'
printf 'DATABASE_URL=postgres://file\n' > "$P/.env"; DATABASE_URL=postgres://exported chk
verdict "an exported DATABASE_URL is used as is; .env is not read" 'DBURL=\[postgres://exported\]'
rm -f "$P/.env"

RE="$S/bin/read-env"
printf 'OTHER=1\n DATABASE_URL=indented\nexport DATABASE_URL=exported\n' > "$T/e1"
want "read-env: no line starting with NAME= (indented, export) -> exit 1" 1 'read-env: no DATABASE_URL= line in' sh "$RE" DATABASE_URL "$T/e1"
want "read-env: missing file -> exit 1" 1 'read-env: cannot read' sh "$RE" DATABASE_URL "$T/missing"
want "read-env: a name that is not an identifier -> exit 2" 2 'read-env: invalid name' sh "$RE" 'X;rm' "$T/e1"
printf 'DATABASE_URL=a"b$(echo no)`x`\n' > "$T/e2"
want "read-env: inner quotes, \$( ) and backticks stay literal" 0 '^a"b\$\(echo no\)`x`$' sh "$RE" DATABASE_URL "$T/e2"

# Retro review 15: an untracked file named like an option must not swallow the scan of the other untracked files.
# Real gitleaks, real HOME. The token is assembled at run time so this file itself holds no secret.
if [ -x "$REAL_HOME/.local/bin/gitleaks" ] || command -v gitleaks >/dev/null 2>&1; then
  p1=R7mQ2xLk9vTz; p2=4NcW8pHs3JdY; p3=6bFa1GeU5oKi
  printf 'x\n' > "$P/--version"; printf 'token = "ghp_%s%s%s"\n' "$p1" "$p2" "$p3" > "$P/leak.txt"
  env HOME="$REAL_HOME" sh -c 'cd "$1" && sh "$2"' _ "$P" "$S/bin/check" > "$T/out" 2>&1; rc=$?
  if [ $rc -eq 1 ] && has '^FAIL  secret scan \(uncommitted' && has '^PASS  secret scan \(committed history\)'; then ok "control: an untracked file named --version does not hide an untracked secret"
  else bad "an untracked file named --version hid an untracked secret (rc=$rc)"; tail -n 6 "$T/out" | sed 's/^/        /'; fi
  rm -f "$P/--version" "$P/leak.txt"
  want "clean repo: both secret scans pass with real gitleaks" 0 'check: OK' env HOME="$REAL_HOME" sh -c 'cd "$1" && sh "$2"' _ "$P" "$S/bin/check"
else bad "gitleaks missing: the uncommitted-scan cases cannot run (BLOCKED)"; fi
rm -rf "$T"; [ $R -eq 0 ] && echo "check-env.t: all cases behave" || echo "check-env.t: FAILURES"; exit $R
