# Sourced POSIX library (C5, founder 2026-10-03; docs/07 §2 item 10 "Builds"): one Rust build at a time per machine,
# one shared CARGO_TARGET_DIR per repo across worktrees, sccache when installed.
#   BUILD_LOCK_WHO=<name>; . standards/bin/build-lock.sh
#   build_lock_acquire || ...   # 0 acquired or re-entered; 1 error; 2 bad BUILD_LOCK_WAIT; 3 held after the wait
#   build_lock_env || ...       # shared target, switch clean, sccache (1 = the clean failed: nothing may build)
#   build_lock_release          # also runs on EXIT/INT/TERM/HUP of the acquirer (a caller that sets its own EXIT
#                               # trap afterwards must call build_lock_release in it)
# Lock: `${TMPDIR:-/tmp}/build.lock.d`, created by mkdir (atomic, machine-wide like verify.lock.d) with an owner file
# (token=, pid=, who=, since=, cwd=). The acquirer exports BUILD_LOCK_TOKEN; a child whose BUILD_LOCK_TOKEN equals the
# owner's token re-enters without acquiring or releasing (a check inside a verify chain or a dispatch judgement). A
# foreign lock is waited for up to BUILD_LOCK_WAIT seconds (default 1800, polled every 10 s), then refused naming the
# holder. A lock is never stolen, reused or deleted by anyone but its acquirer; a stale one (holder gone) is named and
# removed by hand only. Sessions never export their own TMPDIR (docs/07 §4), or the lock would not be machine-wide.
# Shared target: <primary checkout>/target/shared. Cargo keys workspace crates by their path relative to the workspace
# root and trusts mtimes, so before a different worktree builds there, every workspace member is cleaned
# (`cargo clean -p`), dependencies stay cached; the stamp target/shared/.standards-worktree names the last builder.
# Every failure refuses (fail closed). Variables of this library start with _bl_ or BUILD_LOCK_.

build_lock_acquire() {
  _bl_who=${BUILD_LOCK_WHO:-${0##*/}}
  BUILD_LOCK_DIR="${TMPDIR:-/tmp}/build.lock.d"; _bl_dir=$BUILD_LOCK_DIR
  _bl_wait=${BUILD_LOCK_WAIT-1800}
  case "$_bl_wait" in ''|*[!0-9]*) echo "build-lock: BUILD_LOCK_WAIT must be a whole number of seconds" >&2; return 2;; esac
  [ ${#_bl_wait} -le 6 ] || { echo "build-lock: BUILD_LOCK_WAIT must be a whole number of seconds" >&2; return 2; }
  _bl_wait=$(printf '%s' "$_bl_wait" | sed 's/^0*//'); [ -n "$_bl_wait" ] || _bl_wait=0
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
    [ "$_bl_waited" -lt "$_bl_wait" ] || return 3
    if [ $_bl_said -eq 0 ]; then
      echo "$_bl_who: waiting for the build lock held by $BUILD_LOCK_HOLDER_WHO (pid $BUILD_LOCK_HOLDER_PID, since $BUILD_LOCK_HOLDER_SINCE)" >&2
      case "$BUILD_LOCK_HOLDER_PID" in *[!0-9]*|'') ;; *)
        if [ -d /proc/1 ] && [ ! -d "/proc/$BUILD_LOCK_HOLDER_PID" ]; then
          echo "build-lock: pid $BUILD_LOCK_HOLDER_PID is not running — the lock is possibly stale; it is never removed automatically (by hand: rm $_bl_dir/owner && rmdir $_bl_dir)" >&2
        fi;;
      esac
      _bl_said=1
    fi
    _bl_step=10; [ $((_bl_wait - _bl_waited)) -ge 10 ] || _bl_step=$((_bl_wait - _bl_waited))
    sleep "$_bl_step"; _bl_waited=$((_bl_waited + _bl_step))
  done
}

# The refusal after the wait (exit 3 in with-build-lock, verify-lib.sh and mutants).
build_lock_refusal() {
  echo "$_bl_who: refused — the machine build lock is held by $BUILD_LOCK_HOLDER_WHO (pid $BUILD_LOCK_HOLDER_PID, since $BUILD_LOCK_HOLDER_SINCE, cwd $BUILD_LOCK_HOLDER_CWD) after waiting ${BUILD_LOCK_WAITED}s; stale? check pid $BUILD_LOCK_HOLDER_PID, then rm $_bl_dir/owner && rmdir $_bl_dir" >&2
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

# Shared target dir, switch clean and sccache for the cargo commands the caller runs next (call after acquiring).
build_lock_env() {
  if [ -z "${RUSTC_WRAPPER+x}" ]; then
    if command -v sccache >/dev/null 2>&1; then RUSTC_WRAPPER=sccache; export RUSTC_WRAPPER
    else echo "build-lock: sccache not installed — no compiler cache" >&2; fi
  fi
  if ! _bl_top=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$_bl_top" ]; then
    [ -f Cargo.toml ] || return 0   # no git checkout and no cargo workspace here: nothing to share
    echo "build-lock: $(pwd -P) is not inside a git checkout; the shared target cannot be placed" >&2; return 1
  fi
  [ -f "$_bl_top/Cargo.toml" ] || return 0   # no cargo workspace in this checkout
  if [ -z "${CARGO_TARGET_DIR:-}" ]; then
    _bl_common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && [ -n "$_bl_common" ] \
      && _bl_primary=$(cd "$_bl_common/.." && pwd -P) \
      || { echo "build-lock: could not find the primary checkout of $_bl_top" >&2; return 1; }
    CARGO_TARGET_DIR="$_bl_primary/target/shared"; export CARGO_TARGET_DIR
  fi
  _bl_stamp="$CARGO_TARGET_DIR/.standards-worktree"
  _bl_prev=$(cat "$_bl_stamp" 2>/dev/null) || _bl_prev=""
  [ "$_bl_prev" != "$_bl_top" ] || return 0
  # A different (or unknown) worktree built last: clean every workspace member before anything builds here.
  command -v cargo >/dev/null 2>&1 || return 0   # no cargo, nothing can build; the stamp stays as it is
  command -v jq >/dev/null 2>&1 || { echo "build-lock: jq is required to list the workspace crates" >&2; _bl_cleanfail; return 1; }
  _bl_meta=$(cd "$_bl_top" && cargo metadata --no-deps --format-version 1 2>/dev/null) || { _bl_cleanfail; return 1; }
  _bl_names=$(printf '%s\n' "$_bl_meta" | jq -r '.packages[].name' 2>/dev/null) || { _bl_cleanfail; return 1; }
  [ -n "$_bl_names" ] || { _bl_cleanfail; return 1; }
  set --
  for _bl_n in $_bl_names; do
    case "$_bl_n" in ''|-*|*[!A-Za-z0-9_-]*) _bl_cleanfail; return 1;; esac
    set -- "$@" -p "$_bl_n"
  done
  (cd "$_bl_top" && cargo clean "$@") >/dev/null 2>&1 || { _bl_cleanfail; return 1; }
  { mkdir -p "$CARGO_TARGET_DIR" && printf '%s\n' "$_bl_top" > "$_bl_stamp"; } 2>/dev/null \
    || { echo "build-lock: could not write $_bl_stamp; nothing was built" >&2; return 1; }
  return 0
}
