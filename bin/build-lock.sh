# Sourced POSIX library (C5, founder 2026-10-03; docs/07 §2 item 10 "Builds"): one Rust build at a time per machine,
# one shared CARGO_TARGET_DIR per repo across worktrees, sccache when installed.
#   BUILD_LOCK_WHO=<name>; . standards/bin/build-lock.sh
#   build_lock_acquire || ...   # 0 acquired or re-entered; 1 error; 2 bad BUILD_LOCK_WAIT or BUILD_LOCK_STALE;
#                               # 3 held after the wait
#   build_lock_env || ...       # shared target, switch clean, sccache (1 = the clean failed: nothing may build)
#   build_lock_release          # also runs on EXIT/INT/TERM/HUP of the acquirer (a caller that sets its own EXIT
#                               # trap afterwards must call build_lock_release in it)
# Lock: `${TMPDIR:-/tmp}/build.lock.d`, created by mkdir (atomic, machine-wide like verify.lock.d) with an owner file
# (token=, pid=, who=, since=, cwd=). The acquirer exports BUILD_LOCK_TOKEN; a child whose BUILD_LOCK_TOKEN equals the
# owner's token re-enters without acquiring or releasing (a check inside a verify chain or a dispatch judgement). A
# foreign lock is waited for up to BUILD_LOCK_WAIT seconds (default 1800, polled every 10 s), then refused naming the
# holder. A lock is never stolen, reused or deleted by anyone but its acquirer, with one exception, the stale rule
# (exchange BACKLOG 56: a harness crash left the lock behind overnight): a waiter takes a foreign lock, before the wait
# budget is judged on each poll, only when ALL of these hold: BUILD_LOCK_STALE (seconds, default 900, a whole number of
# at most 7 digits, else return 2; 0 disables the rule) is not 0; the owner's pid= is numeric without a leading zero;
# /proc/1 is a directory (Linux) and /proc/<pid> is not; since= has the owner file's own form YYYY-MM-DDTHH:MM:SSZ and
# `date -u -d` parses it; now - since >= BUILD_LOCK_STALE; the owner file has a token=. Anything else is held, as
# before. Taking it renames the OWNER FILE to owner.stale.<pid> inside the lock (one waiter wins; the lock path is
# never vacated, so no third acquirer can mkdir it mid-take), re-reads the token there (a different token = a fresh
# owner moved in a race: moved back; if that fails it stays aside and the lock reads as held by unknown), removes it
# and rmdirs the lock (a failure = held), prints "build-lock: took the stale lock of <who> (pid <pid>, since <since>):
# the holder is gone and the lock is older than <n>s" on stderr and retries mkdir at once (another waiter may win it:
# then it is held). Residual: a holder in
# another pid namespace, or a build whose acquiring shell died while its cargo children run on, looks gone.
# Sessions never export their own TMPDIR (docs/07 §4), or the lock would not be machine-wide.
# Shared target: <primary checkout>/target/shared. Cargo keys workspace crates by their path relative to the workspace
# root and trusts mtimes, so before a different worktree builds there, every workspace member is cleaned
# (`cargo clean -p`), dependencies stay cached; the stamp target/shared/.standards-worktree names the last builder.
# The cargo workspace is <top>/Cargo.toml, else the one tracked subdirectory Cargo.toml (≤ 3 levels) with a [workspace]
# header line, indented or with a trailing comment (exchange D-157: legacy/rust; several refuse): the clean runs there and the stamp names that directory.
# Every failure refuses (fail closed). Variables of this library start with _bl_ or BUILD_LOCK_.

build_lock_acquire() {
  _bl_who=${BUILD_LOCK_WHO:-${0##*/}}
  BUILD_LOCK_DIR="${TMPDIR:-/tmp}/build.lock.d"; _bl_dir=$BUILD_LOCK_DIR
  _bl_wait=${BUILD_LOCK_WAIT-1800}
  case "$_bl_wait" in ''|*[!0-9]*) echo "build-lock: BUILD_LOCK_WAIT must be a whole number of seconds" >&2; return 2;; esac
  [ ${#_bl_wait} -le 6 ] || { echo "build-lock: BUILD_LOCK_WAIT must be a whole number of seconds" >&2; return 2; }
  _bl_wait=$(printf '%s' "$_bl_wait" | sed 's/^0*//'); [ -n "$_bl_wait" ] || _bl_wait=0
  _bl_stale=${BUILD_LOCK_STALE-900}
  case "$_bl_stale" in ''|*[!0-9]*) echo "build-lock: BUILD_LOCK_STALE must be a whole number of seconds" >&2; return 2;; esac
  [ ${#_bl_stale} -le 7 ] || { echo "build-lock: BUILD_LOCK_STALE must be a whole number of seconds" >&2; return 2; }
  _bl_stale=$(printf '%s' "$_bl_stale" | sed 's/^0*//'); [ -n "$_bl_stale" ] || _bl_stale=0
  _bl_waited=0; _bl_said=0
  while :; do
    if mkdir "$_bl_dir" 2>/dev/null; then
      _bl_hex=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || _bl_hex=""
      _bl_now=$(date +%s 2>/dev/null) || _bl_now=""
      case "$_bl_hex" in ????????) ;; *) _bl_hex=x;; esac
      case "$_bl_hex$_bl_now" in *[!0-9a-f]*|'') rmdir "$_bl_dir"; echo "build-lock: could not make a lock token" >&2; return 1;; esac
      _bl_mytok="$$-$_bl_now-$_bl_hex"
      if ! { printf 'token=%s\npid=%s\nwho=%s\nsince=%s\ncwd=%s\n' "$_bl_mytok" "$$" "$_bl_who" \
               "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(pwd -P)" > "$_bl_dir/owner.$$" && mv "$_bl_dir/owner.$$" "$_bl_dir/owner"; }; then
        rm -f "$_bl_dir/owner.$$"; rmdir "$_bl_dir" 2>/dev/null; echo "build-lock: could not write $_bl_dir/owner" >&2; return 1
      fi
      BUILD_LOCK_TOKEN=$_bl_mytok; export BUILD_LOCK_TOKEN; BUILD_LOCK_HELD=1
      trap 'build_lock_release' EXIT
      trap 'build_lock_release; exit 129' HUP
      trap 'build_lock_release; exit 130' INT
      trap 'build_lock_release; exit 143' TERM
      return 0
    fi
    # Held. An owner file that is missing (holder between mkdir and write) or unreadable counts as held by someone else.
    _bl_otok=$(sed -n 's/^token=//p' "$_bl_dir/owner" 2>/dev/null | head -n 1) || _bl_otok=""
    if [ -n "${BUILD_LOCK_TOKEN:-}" ] && [ "$_bl_otok" = "$BUILD_LOCK_TOKEN" ]; then BUILD_LOCK_HELD=0; return 0; fi
    BUILD_LOCK_HOLDER_WHO=$(sed -n 's/^who=//p' "$_bl_dir/owner" 2>/dev/null | head -n 1); : "${BUILD_LOCK_HOLDER_WHO:=unknown}"
    BUILD_LOCK_HOLDER_PID=$(sed -n 's/^pid=//p' "$_bl_dir/owner" 2>/dev/null | head -n 1); : "${BUILD_LOCK_HOLDER_PID:=unknown}"
    BUILD_LOCK_HOLDER_SINCE=$(sed -n 's/^since=//p' "$_bl_dir/owner" 2>/dev/null | head -n 1); : "${BUILD_LOCK_HOLDER_SINCE:=unknown}"
    BUILD_LOCK_HOLDER_CWD=$(sed -n 's/^cwd=//p' "$_bl_dir/owner" 2>/dev/null | head -n 1); : "${BUILD_LOCK_HOLDER_CWD:=unknown}"
    BUILD_LOCK_WAITED=$_bl_waited
    # The stale rule. The OWNER FILE is renamed aside (one waiter wins the rename), never the directory, so the lock path
    # is never vacant and no third acquirer can mkdir it mid-take. Its token re-read there must be the one judged stale;
    # then it is removed and the directory rmdir'ed (a failure = held) and mkdir retried in this iteration. A different
    # token (a fresh owner moved in a race) is moved back (a failure leaves it aside: the lock then reads as held by
    # unknown). Every path but the retry falls through to the wait below, so the loop never spins without sleeping.
    _bl_aside="$_bl_dir/owner.stale.$$"
    if _bl_is_stale && mv "$_bl_dir/owner" "$_bl_aside" 2>/dev/null; then
      if [ "$(sed -n 's/^token=//p' "$_bl_aside" 2>/dev/null | head -n 1)" = "$_bl_otok" ]; then
        rm -f "$_bl_aside"
        if rmdir "$_bl_dir" 2>/dev/null; then
          echo "build-lock: took the stale lock of $BUILD_LOCK_HOLDER_WHO (pid $BUILD_LOCK_HOLDER_PID, since $BUILD_LOCK_HOLDER_SINCE): the holder is gone and the lock is older than ${_bl_stale}s" >&2
          continue
        fi
      else
        mv "$_bl_aside" "$_bl_dir/owner" 2>/dev/null || :
      fi
    fi
    [ "$_bl_waited" -lt "$_bl_wait" ] || return 3
    if [ $_bl_said -eq 0 ]; then
      echo "$_bl_who: waiting for the build lock held by $BUILD_LOCK_HOLDER_WHO (pid $BUILD_LOCK_HOLDER_PID, since $BUILD_LOCK_HOLDER_SINCE)" >&2
      case "$BUILD_LOCK_HOLDER_PID" in *[!0-9]*|'') ;; *)
        if [ -d /proc/1 ] && [ ! -d "/proc/$BUILD_LOCK_HOLDER_PID" ]; then
          echo "build-lock: pid $BUILD_LOCK_HOLDER_PID is not running — the lock is possibly stale; $(_bl_rule) (its owner file renamed aside, never the directory); by hand: rm -f $_bl_dir/owner $_bl_dir/owner.stale.* && rmdir $_bl_dir" >&2
        fi;;
      esac
      _bl_said=1
    fi
    _bl_step=10; [ $((_bl_wait - _bl_waited)) -ge 10 ] || _bl_step=$((_bl_wait - _bl_waited))
    sleep "$_bl_step"; _bl_waited=$((_bl_waited + _bl_step))
  done
}

# The stale rule's conditions on the owner just read (all of them; anything else = held).
_bl_is_stale() {
  [ "$_bl_stale" -ne 0 ] && [ -n "$_bl_otok" ] || return 1
  case "$BUILD_LOCK_HOLDER_PID" in ''|0*|*[!0-9]*) return 1;; esac
  [ -d /proc/1 ] && [ ! -d "/proc/$BUILD_LOCK_HOLDER_PID" ] || return 1
  case "$BUILD_LOCK_HOLDER_SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;; *) return 1;; esac
  _bl_s=$(date -u -d "$BUILD_LOCK_HOLDER_SINCE" +%s 2>/dev/null) || return 1
  _bl_n=$(date -u +%s 2>/dev/null) || return 1
  case "$_bl_s$_bl_n" in ''|*[!0-9]*) return 1;; esac
  [ $((_bl_n - _bl_s)) -ge "$_bl_stale" ]
}

# The rule, named in the hints.
_bl_rule() {
  if [ "$_bl_stale" -eq 0 ]; then echo "the stale rule is off (BUILD_LOCK_STALE=0)"
  else echo "it is taken automatically once older than BUILD_LOCK_STALE=${_bl_stale}s"; fi
}

# The refusal after the wait (exit 3 in with-build-lock, verify-lib.sh and mutants).
build_lock_refusal() {
  echo "$_bl_who: refused — the machine build lock is held by $BUILD_LOCK_HOLDER_WHO (pid $BUILD_LOCK_HOLDER_PID, since $BUILD_LOCK_HOLDER_SINCE, cwd $BUILD_LOCK_HOLDER_CWD) after waiting ${BUILD_LOCK_WAITED}s; stale? check pid $BUILD_LOCK_HOLDER_PID, then rm $_bl_dir/owner && rmdir $_bl_dir (a lock whose holder is gone: $(_bl_rule))" >&2
}

# Releases only a lock this process acquired, and only while the owner file still carries its token.
build_lock_release() {
  [ "${BUILD_LOCK_HELD:-0}" = 1 ] || return 0
  BUILD_LOCK_HELD=0
  if [ "$(sed -n 's/^token=//p' "$_bl_dir/owner" 2>/dev/null | head -n 1)" = "$_bl_mytok" ]; then
    rm -f "$_bl_dir/owner"; rmdir "$_bl_dir" 2>/dev/null
  fi
  unset BUILD_LOCK_TOKEN
  return 0
}

_bl_cleanfail() { echo "build-lock: could not clean the previous worktree's workspace crates; nothing was built" >&2; return 1; }

# The cargo workspace of a checkout <top> without a top-level Cargo.toml (exchange D-157: legacy/rust): the directory of
# the one TRACKED Cargo.toml at most 3 directory levels deep with a `[workspace]` header line (indented or with a
# trailing comment). Prints <top>/<dir>, or nothing when there is none (nothing to share); several refuse (never guess),
# as does a listing or a read that fails. The listing takes no pathspec (GIT_LITERAL_PATHSPECS and friends cannot change
# it) and is unquoted (core.quotePath=false: non-ASCII names come through as they are); a Cargo.toml name git still
# quotes (a quote, a control character) cannot be read safely and refuses.
_bl_find_ws() {
  _bl_ls=$(git -c core.quotePath=false -C "$1" ls-files 2>/dev/null) || {
    echo "build-lock: could not list the tracked Cargo.toml files of $1" >&2; return 1; }
  _bl_found=$(printf '%s\n' "$_bl_ls" | while IFS= read -r _bl_f; do
      case "$_bl_f" in \"*Cargo.toml\") echo "/quoted"; continue;; esac
      case "$_bl_f" in */*/*/*/*) continue;; */Cargo.toml) ;; *) continue;; esac
      [ -e "$1/$_bl_f" ] || continue   # tracked, but deleted in this worktree
      grep -Eq '^[[:space:]]*\[workspace\][[:space:]]*(#.*)?$' "$1/$_bl_f" 2>/dev/null; _bl_g=$?
      case $_bl_g in 0) printf '%s\n' "${_bl_f%/Cargo.toml}";; 1) ;; *) printf '/unreadable %s\n' "$_bl_f";; esac
    done | LC_ALL=C sort) || { echo "build-lock: could not list the tracked Cargo.toml files of $1" >&2; return 1; }
  if printf '%s\n' "$_bl_found" | grep -qx '/quoted'; then
    echo "build-lock: could not list the tracked Cargo.toml files of $1" >&2; return 1; fi
  if _bl_u=$(printf '%s\n' "$_bl_found" | grep '^/unreadable ' | head -n 1) && [ -n "$_bl_u" ]; then
    echo "build-lock: could not read $1/${_bl_u#/unreadable }; the shared target cannot be placed" >&2; return 1; fi
  _bl_cnt=$(printf '%s\n' "$_bl_found" | grep -c .)
  case "$_bl_cnt" in
    0) return 0;;
    1) printf '%s\n' "$1/$_bl_found";;
    *) echo "build-lock: several cargo workspaces in $1 ($(printf '%s\n' "$_bl_found" | head -n 5 | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')); the shared target cannot be placed" >&2
       return 1;;
  esac
}

# Shared target dir, switch clean and sccache for the cargo commands the caller runs next (call after acquiring).
build_lock_env() {
  # cargo and sccache are looked for on PATH, then in $HOME/.cargo/bin (appended, so the caller's own tools keep
  # precedence), on EVERY call: cargo only on a worktree switch made a later call in the same worktree fail `cargo: not
  # found` (exchange BACKLOG 46 (b)). sccache installed there but missing from PATH left the cache silently off
  # (2026-10-13: 412 requests, 2 hits). The line naming it puts "the cache is on" into every log that builds.
  if ! command -v cargo >/dev/null 2>&1 && [ -x "${HOME:-/nonexistent}/.cargo/bin/cargo" ]; then
    PATH="$PATH:$HOME/.cargo/bin"; export PATH; fi
  if [ -z "${RUSTC_WRAPPER+x}" ]; then
    if ! command -v sccache >/dev/null 2>&1 && [ -x "${HOME:-/nonexistent}/.cargo/bin/sccache" ]; then
      PATH="$PATH:$HOME/.cargo/bin"; export PATH; fi
    if _bl_sc=$(command -v sccache 2>/dev/null) && [ -n "$_bl_sc" ]; then
      RUSTC_WRAPPER=sccache; export RUSTC_WRAPPER; echo "build-lock: sccache $_bl_sc" >&2
    else echo "build-lock: sccache not installed — no compiler cache" >&2; fi
  fi
  if ! _bl_top=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$_bl_top" ]; then
    [ -f Cargo.toml ] || return 0   # no git checkout and no cargo workspace here: nothing to share
    echo "build-lock: $(pwd -P) is not inside a git checkout; the shared target cannot be placed" >&2; return 1
  fi
  # The workspace directory: <top> when <top>/Cargo.toml exists, else the one tracked nested workspace (_bl_find_ws).
  _bl_ws=$_bl_top
  if [ ! -f "$_bl_top/Cargo.toml" ]; then
    _bl_ws=$(_bl_find_ws "$_bl_top") || return 1
    [ -n "$_bl_ws" ] || return 0   # no cargo workspace in this checkout
  fi
  if [ -z "${CARGO_TARGET_DIR:-}" ]; then
    _bl_common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && [ -n "$_bl_common" ] \
      && _bl_primary=$(cd "$_bl_common/.." && pwd -P) \
      || { echo "build-lock: could not find the primary checkout of $_bl_top" >&2; return 1; }
    CARGO_TARGET_DIR="$_bl_primary/target/shared"; export CARGO_TARGET_DIR
  fi
  [ "$_bl_ws" = "$_bl_top" ] || echo "build-lock: cargo workspace ${_bl_ws#"$_bl_top"/} (shared target $CARGO_TARGET_DIR)" >&2
  _bl_stamp="$CARGO_TARGET_DIR/.standards-worktree"
  _bl_prev=$(cat "$_bl_stamp" 2>/dev/null) || _bl_prev=""
  [ "$_bl_prev" != "$_bl_ws" ] || return 0
  # A different (or unknown) worktree built last: clean every workspace member before anything builds here. Cargo was
  # looked for at the top (PATH, then $HOME/.cargo/bin); a cargo the caller can reach only by an absolute path would
  # otherwise skip the clean — so a missing cargo refuses (fail closed).
  command -v cargo >/dev/null 2>&1 || {
    echo "build-lock: cargo is not on PATH or in \$HOME/.cargo/bin, so the previous worktree's workspace crates cannot be cleaned; nothing was built" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "build-lock: jq is required to list the workspace crates" >&2; _bl_cleanfail; return 1; }
  _bl_meta=$(cd "$_bl_ws" && cargo metadata --no-deps --format-version 1 2>/dev/null) || { _bl_cleanfail; return 1; }
  _bl_names=$(printf '%s\n' "$_bl_meta" | jq -r '.packages[].name' 2>/dev/null) || { _bl_cleanfail; return 1; }
  [ -n "$_bl_names" ] || { _bl_cleanfail; return 1; }
  set --
  for _bl_n in $_bl_names; do
    case "$_bl_n" in ''|-*|*[!A-Za-z0-9_-]*) _bl_cleanfail; return 1;; esac
    set -- "$@" -p "$_bl_n"
  done
  # `cargo clean -p` cleans one profile directory: dev (debug/) always, then every other profile directory present in
  # the shared target (release/ -> --release, <name>/ -> --profile <name>; a directory with a .fingerprint/ is a profile).
  (cd "$_bl_ws" && cargo clean "$@") >/dev/null 2>&1 || { _bl_cleanfail; return 1; }
  for _bl_pd in "$CARGO_TARGET_DIR"/*/.fingerprint; do
    [ -d "$_bl_pd" ] || continue
    _bl_p=${_bl_pd%/.fingerprint}; _bl_p=${_bl_p##*/}
    case "$_bl_p" in debug) continue;; ''|-*|*[!A-Za-z0-9_-]*) _bl_cleanfail; return 1;; esac
    if [ "$_bl_p" = release ]; then (cd "$_bl_ws" && cargo clean "$@" --release) >/dev/null 2>&1 || { _bl_cleanfail; return 1; }
    else (cd "$_bl_ws" && cargo clean "$@" --profile "$_bl_p") >/dev/null 2>&1 || { _bl_cleanfail; return 1; }; fi
  done
  { mkdir -p "$CARGO_TARGET_DIR" && printf '%s\n' "$_bl_ws" > "$_bl_stamp"; } 2>/dev/null \
    || { echo "build-lock: could not write $_bl_stamp; nothing was built" >&2; return 1; }
  return 0
}
