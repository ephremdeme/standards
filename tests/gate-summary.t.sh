#!/bin/sh
# Cases for bin/gate-summary (E4 retrospective A.1): a bin/local-gate log summarised in a few lines and judged exactly as
# bin/merge-pr --local-log judges it. A green fixture log with noise and chained green verify lines; a long red log whose
# [FAIL] lines are capped at 10; then one control per rule, in the order of the script's header, each red for its own
# rule (exit 1 and the matching "red — …" text), and the refusals (exit 2).
# Run: sh tests/gate-summary.t.sh   -> exit 0 when all cases behave.
set -u
S=$(cd "$(dirname "$0")/.." && pwd); GS="$S/bin/gate-summary"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
check_(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
H=0123456789abcdef0123456789abcdef01234567; H2=fedcba9876543210fedcba9876543210fedcba98
# green <file> [skip-regex]: the green fixture log, minus the lines matching skip-regex.
green(){ {
  echo "Mem: noise-free 123"; echo "noise: compiling ledger"; echo "check: OK"; echo "noise: [ok] step a"
  echo "verify:e8 — 4 ok, 0 failed"; echo "noise: chained e8 done"; echo "verify:e9 — 7 ok, 0 failed"
  echo "gate-head: $H"; echo "gate-tree: clean"; echo "gate-verdict: green e9"
} | grep -Ev -- "${2:-^\$^}" > "$1"; }
L="$T/green.log"; green "$L"
want "green log -> exit 0, gate-summary: green e9 <sha>" 0 "gate-summary: green e9 $H\$" sh "$GS" "$L"
want "green log with --id e9 -> green" 0 "^gate-summary: green e9 $H\$" sh "$GS" "$L" --id e9
out=$(sh "$GS" "$L" 2>&1)
check_ "the output never contains a noise line" '! printf "%s\n" "$out" | grep -q noise'
check_ "the filtered lines come in file order (check, verify e8, verify e9, head, tree, verdict, then the verdict line)" \
  '[ "$(printf "%s\n" "$out" | cut -c1-9 | tr "\n" "|")" = "check: OK|verify:e8|verify:e9|gate-head|gate-tree|gate-verd|gate-summ|" ]'
# A long red log: 300 noise lines and 25 [FAIL] lines -> exactly 10 [FAIL] lines and "… and 15 more".
B="$T/big.log"; i=0; : > "$B"
while [ $i -lt 300 ]; do echo "noise line $i" >> "$B"; [ $((i % 12)) -eq 0 ] && [ $i -lt 300 ] && echo "[FAIL] case $i" >> "$B"; i=$((i + 1)); done
check_ "the fixture holds 25 [FAIL] lines" '[ "$(grep -c "^\[FAIL\]" "$B")" -eq 25 ]'
cat "$L" >> "$B"
out=$(sh "$GS" "$B" 2>&1); rc=$?
check_ "the big log prints exactly 10 [FAIL] lines" '[ "$(printf "%s\n" "$out" | grep -c "^\[FAIL\]")" -eq 10 ]'
check_ "the big log prints the '… and 15 more [FAIL] lines' line" 'printf "%s\n" "$out" | grep -qx "gate-summary: … and 15 more \[FAIL\] lines"'
check_ "the big log never prints a noise line and stays within filtered + 12 lines" \
  '! printf "%s\n" "$out" | grep -q "^noise" && [ "$(printf "%s\n" "$out" | wc -l)" -le $((6 + 12)) ]'
check_ "the big log is red for its [FAIL] lines (exit 1)" '[ $rc -eq 1 ] && printf "%s\n" "$out" | tail -n 1 | grep -qx "gate-summary: red — 25 \[FAIL\] line(s)"'
# Controls, one per rule in the header's order.
C="$T/c.log"
green "$C" '^check: OK$'
want "control 1: no check: OK -> red" 1 '^gate-summary: red — no check: OK line$' sh "$GS" "$C"
green "$C"; echo "check: FAILED" >> "$C"
want "control 2: a check: FAILED line -> red" 1 '^gate-summary: red — 1 check: FAILED line\(s\)$' sh "$GS" "$C"
green "$C"; echo "[FAIL] one case" >> "$C"
want "control 3: a [FAIL] line -> red" 1 '^gate-summary: red — 1 \[FAIL\] line\(s\)$' sh "$GS" "$C"
green "$C"; echo "verify:e9 — 3 ok, 1 failed" >> "$C"
want "control 4: verify:e9 — 3 ok, 1 failed -> red" 1 '^gate-summary: red — a verify line with failures: verify:e9 — 3 ok, 1 failed$' sh "$GS" "$C"
green "$C"; echo "gate-head: $H2" >> "$C"
want "control 5: two different gate-head values -> red" 1 '^gate-summary: red — 2 different gate-head values' sh "$GS" "$C"
green "$C" '^gate-head:'; echo "gate-head: ABC" >> "$C"
want "control 5b: a gate-head that is not 40 lowercase hex -> red" 1 "^gate-summary: red — gate-head is not 'gate-head: <40 lowercase hex>': gate-head: ABC\$" sh "$GS" "$C"
green "$C" '^gate-tree:'; echo "gate-tree: dirty (x)" >> "$C"
want "control 6: gate-tree: dirty (x) -> red" 1 '^gate-summary: red — gate-tree: dirty \(x\), not gate-tree: clean$' sh "$GS" "$C"
green "$C" '^gate-verdict:'; echo "gate-verdict: red — the instrument exited 1" >> "$C"
want "control 7: a gate-verdict: red line -> red" 1 '^gate-summary: red — a red gate verdict \(gate-verdict: red — the instrument exited 1\)$' sh "$GS" "$C"
green "$C"; echo "gate-verdict: green e9" >> "$C"
want "control 8: two verdict lines -> red" 1 '^gate-summary: red — 2 gate-verdict lines' sh "$GS" "$C"
green "$C" '^verify:e9'
want "control 9: gate-verdict: green e9 with only verify:e8 green -> red" 1 '^gate-summary: red — no verify:e9 — N ok, 0 failed line \(N >= 1\) for gate-verdict: green e9$' sh "$GS" "$C"
green "$C"
want "control 10: --id e8 against a green e9 log -> red" 1 '^gate-summary: red — gate-verdict: green e9, not the requested e8$' sh "$GS" "$C" --id e8
# Refusals.
want "refusal: no argument -> exit 2" 2 '^gate-summary: refused — usage' sh "$GS"
want "refusal: --id without a value -> exit 2" 2 '^gate-summary: refused — usage' sh "$GS" "$L" --id
want "refusal: --id E9 -> exit 2" 2 "^gate-summary: refused — --id 'E9' does not match" sh "$GS" "$L" --id E9
want "refusal: an unreadable log -> exit 2" 2 '^gate-summary: refused — log .*/nope.log is not a readable file$' sh "$GS" "$T/nope.log"
: > "$T/empty.log"
want "refusal: an empty log -> exit 2" 2 '^gate-summary: refused — log .*/empty.log is empty$' sh "$GS" "$T/empty.log"
rm -rf "$T"
[ $R -eq 0 ] && echo "gate-summary.t: all cases behave" || echo "gate-summary.t: FAILURES"
exit $R
