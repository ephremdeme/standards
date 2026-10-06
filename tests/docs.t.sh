#!/bin/sh
# Markdown sanity judge of standards docs lanes, and its own cases. bin/dispatch-deepseek runs it, from the PRE-run commit,
# on every docs/*.md a DeepSeek standards lane changed (docs/07 §1, DeepSeek scope 3).
#   sh tests/docs.t.sh                            -> the cases below; exit 0 when all behave
#   sh tests/docs.t.sh --judge <root> <file>...   -> judges each repo-relative markdown file under <root> (the
#     dispatcher passes every docs/**/*.md and README.md of the lane's tree):
#     - every relative link, inline `[t](x)` or a reference definition `[t]: x`, resolves to an existing path inside
#       <root> (an anchor or query is dropped; `/x` is read from <root>; scheme links and bare anchors are not followed);
#     - no leftover template placeholder: `<...>` outside code spans and fenced blocks (except a short list of HTML tags,
#       comments and autolinks), TODO, TBD, FIXME, `{{...}}`.
#     One line `docs: FAIL <file>:<line>: <reason>` per finding, then `docs: OK (<n> file(s))` exit 0 or
#     `docs: FAILED (<n> finding(s))` exit 1. Usage errors exit 2. Every read error is a finding, never a pass.
set -u
tab=$(printf '\t')

# The markdown scan: one record `<line><TAB>link|ph<TAB><text>` per link target and placeholder.
scan() {
  awk '
    # A fence opens with 3+ backticks or tildes and closes only with the same character, at least as many, and nothing
    # after it: a ``` line inside a ```` or ~~~ block is content.
    match($0, /^[ \t]*(```+|~~~+)/) {
      f = substr($0, RSTART, RLENGTH); sub(/^[ \t]+/, "", f); c = substr(f, 1, 1); n = length(f); rest = substr($0, RSTART + RLENGTH)
      if (!fence) { fence = 1; fchar = c; flen = n; next }
      if (c == fchar && n >= flen && rest ~ /^[ \t]*$/) { fence = 0; next }
    }
    fence { next }
    {
      line = $0
      gsub(/``[^`]*``/, "", line); gsub(/`[^`]*`/, "", line)
      s = line
      while (match(s, /\]\([^)]*\)/)) { print NR "\tlink\t" substr(s, RSTART + 2, RLENGTH - 3); s = substr(s, RSTART + RLENGTH) }
      if (match(line, /^ *\[[^]]+\]:[ \t]*[^ \t]+/)) { d = substr(line, RSTART, RLENGTH); sub(/^ *\[[^]]+\]:[ \t]*/, "", d); print NR "\tlink\t" d }
      s = line
      while (match(s, /<[^<>]*>/)) {
        t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        if (t ~ /^<!--/) continue
        if (t ~ /^<[A-Za-z][A-Za-z0-9+.-]*:[^ <>]*>$/) continue
        if (t ~ /^<\/?(a|b|br|code|details|div|em|hr|i|img|kbd|li|ol|p|pre|span|strong|sub|summary|sup|table|tbody|td|th|thead|tr|ul)( [^>]*)?\/?>$/) continue
        print NR "\tph\t" t
      }
      s = line
      while (match(s, /TODO|TBD|FIXME|[{][{][^}]*[}][}]/)) { print NR "\tph\t" substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }
    }' "$1"
}

judge() { # judge <root> <file>...
  [ $# -ge 1 ] && [ -d "$1" ] || { echo "docs: usage: docs.t.sh --judge <root> <file>..." >&2; return 2; }
  rootp=$(cd "$1" && pwd -P) || { echo "docs: usage: docs.t.sh --judge <root> <file>... (root unreadable)" >&2; return 2; }
  shift; n=0; nf=0
  for f in "$@"; do
    case "$f" in /*|..|../*|*/..|*/../*) echo "docs: FAIL $f: not a repo-relative path"; nf=$((nf + 1)); continue;; esac
    if [ ! -f "$rootp/$f" ] || [ ! -r "$rootp/$f" ]; then echo "docs: FAIL $f: no such file"; nf=$((nf + 1)); continue; fi
    n=$((n + 1))
    if ! recs=$(scan "$rootp/$f"); then echo "docs: FAIL $f: unreadable (awk failed)"; nf=$((nf + 1)); continue; fi
    dir=$(dirname "$rootp/$f")
    while IFS="$tab" read -r ln kind val; do
      [ -n "$ln" ] || continue
      if [ "$kind" = ph ]; then echo "docs: FAIL $f:$ln: template placeholder $val"; nf=$((nf + 1)); continue; fi
      t=${val#"${val%%[! ]*}"}; t=${t%%[ ]*}            # first token: drops a "title"
      case "$t" in "<"*">") t=${t#<}; t=${t%>};; esac
      case "$t" in ''|'#'*) continue;; esac
      case "$t" in [A-Za-z]*:*) s=${t%%:*}; case "$s" in *[!A-Za-z0-9+.-]*) ;; *) continue;; esac;; esac
      p=${t%%#*}; p=${p%%\?*}
      [ -n "$p" ] || continue
      case "$p" in /*) target="$rootp$p";; *) target="$dir/$p";; esac
      if [ ! -e "$target" ]; then echo "docs: FAIL $f:$ln: broken relative link $t"; nf=$((nf + 1)); continue; fi
      if [ -d "$target" ]; then real=$(cd "$target" && pwd -P); else real=$(cd "$(dirname "$target")" && pwd -P); fi \
        || { echo "docs: FAIL $f:$ln: broken relative link $t (unresolvable)"; nf=$((nf + 1)); continue; }
      case "$real/" in "$rootp"/*) ;; *) echo "docs: FAIL $f:$ln: link leaves the repository $t"; nf=$((nf + 1));; esac
    done <<EOF
$recs
EOF
  done
  if [ $nf -eq 0 ]; then echo "docs: OK ($n file(s))"; return 0; fi
  echo "docs: FAILED ($nf finding(s))"; return 1
}

if [ "${1:-}" = --judge ]; then shift; judge "$@"; exit $?; fi

# ---- cases ----------------------------------------------------------------------------------------------------------
S=$(cd "$(dirname "$0")/.." && pwd); ME="$S/tests/docs.t.sh"; T=$(mktemp -d); R=0
TMPDIR=$T; export TMPDIR
ok(){ echo "PASS    $1"; }; bad(){ echo "FAIL    $1"; R=1; }
want(){ # want <label> <rc> <regex> <cmd...>
  label=$1; rc_want=$2; re=$3; shift 3; out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$rc_want" ] && printf '%s' "$out" | grep -Eq -- "$re"; then ok "$label"; else bad "$label (rc=$rc want $rc_want, /$re/)"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        /'; fi; }
J(){ sh "$ME" --judge "$@"; }
P="$T/repo"; mkdir -p "$P/docs/sub" "$P/bin"; echo x > "$P/bin/check"; echo x > "$P/docs/sub/b.md"; echo x > "$T/outside.md"
Q3='```'
# good: links that resolve (sibling, subdirectory, parent, root-relative, anchor, title), scheme links, an autolink,
# argument syntax in code spans and fences, HTML tags, a comment, a broken link and a placeholder inside a fence.
{ printf '%s\n' '# Good' 'See [b](sub/b.md), [b again](./sub/b.md#top "Title"), [check](../bin/check) and [root](/bin/check).' \
    'Anchors [here](#good), web [site](https://example.com/a_(b)) and <https://example.com>, mail [m](mailto:a@b).' \
    'Run `standards/bin/check --only <kind>` and ``a <x> b``.<br> <!-- a comment -->' '<details><summary>More</summary></details>' \
    '[ref]: sub/b.md' "$Q3" 'see [x](missing.md) and <placeholder> TODO' "$Q3"; } > "$P/docs/a.md"
want "a clean file: every link resolves, code spans, fences and HTML tags are not placeholders -> docs: OK" 0 '^docs: OK \(1 file\(s\)\)$' J "$P" docs/a.md
printf '# Broken\n\nIntro.\nSee [gone](gone.md#x) for details.\n' > "$P/docs/broken.md"
want "control: a broken relative link -> FAIL naming file, line and target" 1 '^docs: FAIL docs/broken\.md:4: broken relative link gone\.md#x$' J "$P" docs/broken.md
printf '# Ref\n[gone]: ../nowhere/x.md\n' > "$P/docs/ref.md"
want "control: a broken reference definition -> FAIL" 1 '^docs: FAIL docs/ref\.md:2: broken relative link \.\./nowhere/x\.md$' J "$P" docs/ref.md
printf '# Out\nSee [o](../../outside.md).\n' > "$P/docs/out.md"
want "control: a link that resolves outside the repository -> FAIL" 1 '^docs: FAIL docs/out\.md:2: link leaves the repository \.\./\.\./outside\.md$' J "$P" docs/out.md
printf '# Repo\n\nPurpose: <one-line purpose>.\n' > "$P/docs/ph.md"
want "control: a template placeholder <...> outside code -> FAIL naming it" 1 '^docs: FAIL docs/ph\.md:3: template placeholder <one-line purpose>$' J "$P" docs/ph.md
printf '# Repo\nOwner: TBD\n' > "$P/docs/tbd.md"
want "control: TBD -> FAIL" 1 '^docs: FAIL docs/tbd\.md:2: template placeholder TBD$' J "$P" docs/tbd.md
printf '# Repo\nName: {{ repo }}\n' > "$P/docs/mustache.md"
want "control: {{ repo }} -> FAIL" 1 '^docs: FAIL docs/mustache\.md:2: template placeholder \{\{ repo \}\}$' J "$P" docs/mustache.md
printf '# Fence\n````\n```\n````\nSee [gone](gone.md).\n' > "$P/docs/fence.md"
want "control: a \`\`\` line inside a \`\`\`\` fence does not close it; the broken link after the fence is caught" 1 '^docs: FAIL docs/fence\.md:5: broken relative link gone\.md$' J "$P" docs/fence.md
printf '# Fence\n~~~\n```\n~~~\nTBD\n' > "$P/docs/fence2.md"
want "control: a \`\`\` line inside a ~~~ fence does not close it either (TBD after the fence caught)" 1 '^docs: FAIL docs/fence2\.md:5: template placeholder TBD$' J "$P" docs/fence2.md
want "two bad files and one good -> every finding listed, FAILED (2 finding(s))" 1 '^docs: FAILED \(2 finding\(s\)\)$' J "$P" docs/a.md docs/broken.md docs/tbd.md
want "control: a named file that does not exist -> FAIL (never skipped)" 1 '^docs: FAIL docs/none\.md: no such file$' J "$P" docs/none.md
want "control: an absolute file argument -> FAIL" 1 '^docs: FAIL /etc/passwd: not a repo-relative path$' J "$P" /etc/passwd
want "no files -> docs: OK (0 file(s))" 0 '^docs: OK \(0 file\(s\)\)$' J "$P"
want "control: --judge without a root -> usage, exit 2" 2 '^docs: usage: docs\.t\.sh --judge <root> <file>\.\.\.$' J
want "control: --judge with a missing root -> usage, exit 2" 2 '^docs: usage: ' J "$T/none"
# This checkout's own docs pass the judge (what a docs lane is held to).
set --; for f in "$S"/docs/*.md; do set -- "$@" "docs/${f##*/}"; done
want "this checkout's docs/*.md pass the judge" 0 '^docs: OK \([1-9][0-9]* file\(s\)\)$' J "$S" "$@"
rm -rf "$T"; [ $R -eq 0 ] && echo "docs.t: all cases behave" || echo "docs.t: FAILURES"; exit $R
