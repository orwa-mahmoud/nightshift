#!/usr/bin/env bash
# Owner emergency control: stop (pause), reset (drop runtime), purge (delete project state).
# Runtime wrappers source this after lib.sh. Hooks do not load it.

ns_control_drop() { # <path> — unlink a file, symlink, or directory without following
  local p="$1"
  [ -e "$p" ] || [ -L "$p" ] || return 0
  if [ -d "$p" ] && [ ! -L "$p" ]; then
    rm -rf "$p"
  else
    rm -f "$p"
  fi
}

ns_control_canon_path() { # <path> — canonical absolute path; directory need not exist
  local raw="${1%/}" parent
  case "$raw" in /*) ;; *) return 1 ;; esac
  [ -n "$raw" ] || return 1
  if [ "$raw" = / ]; then
    printf '/'
    return 0
  fi
  if [ -d "$raw" ] && [ ! -L "$raw" ]; then
    printf '%s' "$(cd -P "$raw" >/dev/null 2>&1 && pwd -P)"
    return 0
  fi
  parent="${raw%/*}"
  [ -n "$parent" ] || parent=/
  parent="$(cd -P "$parent" >/dev/null 2>&1 && pwd -P)" || return 1
  if [ "$parent" = / ]; then
    printf '/%s' "${raw##*/}"
  else
    printf '%s/%s' "$parent" "${raw##*/}"
  fi
}

# Read .nightshift-link without requiring .nightshift/ (purge idempotency).
ns_control_read_link() { # <host> — prints workspace · 2 malformed
  local host="$1" link="$1/.nightshift-link" target="" lines="" canonical=""
  if [ ! -e "$link" ] && [ ! -L "$link" ]; then
    return 1
  fi
  if [ ! -f "$link" ] || [ -L "$link" ]; then
    return 2
  fi
  IFS= read -r target <"$link" || true
  lines="$(awk 'END { print NR + 0 }' "$link" 2>/dev/null)"
  if [ -z "$target" ] || [ "$lines" -ne 1 ]; then
    return 2
  fi
  case "$target" in /*) ;; *) return 2 ;; esac
  canonical="$(cd -P "$target" 2>/dev/null && pwd)" || {
    ns_control_canon_path "$target" || return 2
    return 0
  }
  printf '%s' "$canonical"
}

ns_control_broad_workspace() { # <canonical-workspace>
  local ws="$1" home="${HOME:-}"
  [ -z "$ws" ] && return 0
  [ "$ws" = / ] && return 0
  ws="${ws%/}"
  [ -z "$ws" ] && return 0
  [ -n "$home" ] && home="$(cd -P "$home" 2>/dev/null && pwd)" || home=""
  case "$ws" in
    / | /Users | /home | /etc | /usr | /bin | /sbin | /var | /opt | /private | /System | /tmp)
      return 0
      ;;
  esac
  [ -n "$home" ] && [ "$ws" = "$home" ] && return 0
  return 1
}

# Resolve --project (host/task root) to HOST, WORKSPACE, NS. Requires an explicit path.
# Sets NS_CONTROL_HOST NS_CONTROL_WORKSPACE NS_CONTROL_NS.
# Return 0 · 1 usage · 2 invalid link or missing state
ns_control_resolve() { # <host-path>
  local host workspace ns
  NS_CONTROL_HOST=""
  NS_CONTROL_WORKSPACE=""
  NS_CONTROL_NS=""
  [ -n "$1" ] || return 1
  host="$(cd -P "$1" 2>/dev/null && pwd)" || return 1
  if [ -e "$host/.nightshift-link" ] || [ -L "$host/.nightshift-link" ]; then
    workspace="$(ns_workspace_root "$host" 2>/dev/null)" || return 2
  else
    workspace="$host"
  fi
  ns="$workspace/.nightshift"
  NS_CONTROL_HOST="$host"
  NS_CONTROL_WORKSPACE="$workspace"
  NS_CONTROL_NS="$ns"
  return 0
}

ns_control_deadline_passed() { # <ns>
  local dl now
  [ -L "$1/deadline" ] && return 1
  [ -f "$1/deadline" ] || return 1
  dl="$(tr -d '[:space:]' <"$1/deadline" 2>/dev/null || true)"
  [ -n "$dl" ] || return 1
  case "$dl" in *[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ "$now" -ge "$dl" ]
}

# Print a refuse line when Start must not arm a paused shift. Empty = Start may proceed.
ns_control_start_refuse_reason() { # <ns>
  local ns="$1"
  [ -f "$ns/STOP" ] || return 0
  [ -f "$ns/.ended" ] && [ ! -L "$ns/.ended" ] && return 0
  ns_control_deadline_passed "$ns" || return 0
  printf '%s\n' "paused shift deadline has expired — write a new UNIX epoch to $ns/deadline, or run Reset then Start; refusing to invent a time budget"
}

ns_control_watchman_command_ok() { # <pid>
  local args
  ns_have_cmd ps || return 1
  args="$(ps -o command= -p "$1" 2>/dev/null || ps -o args= -p "$1" 2>/dev/null || true)"
  [ -n "$args" ] || return 1
  printf '%s' "$args" | grep -qE 'watchman\.sh|watchman\.ps1|start-watchman'
}

# Kill only a verified live Nightshift watchman.
# Sets NS_CONTROL_WATCHMAN to absent | stopped | unverified.
# 0 killed or absent · 1 unverified (left running)
ns_control_stop_watchman() { # <ns>
  local ns="$1" pidfile pid start rc
  NS_CONTROL_WATCHMAN=absent
  pidfile="$ns/.watchman"
  if [ -L "$pidfile" ]; then
    ns_control_drop "$pidfile"
    ns_control_drop "$ns/.watchman-tick"
    NS_CONTROL_WATCHMAN=stopped
    return 0
  fi
  if [ ! -f "$pidfile" ]; then
    ns_control_drop "$ns/.watchman-tick"
    return 0
  fi
  pid="$(sed -n 1p "$pidfile" 2>/dev/null | tr -d '[:space:]')"
  start="$(sed -n 2p "$pidfile" 2>/dev/null || true)"
  case "$pid" in
    '' | *[!0-9]*)
      ns_control_drop "$pidfile"
      ns_control_drop "$ns/.watchman-tick"
      return 0
      ;;
  esac
  [ "$pid" -gt 1 ] 2>/dev/null || {
    ns_control_drop "$pidfile"
    ns_control_drop "$ns/.watchman-tick"
    return 0
  }
  ns_recorded_process "$pid" "$start"
  rc=$?
  if [ "$rc" -eq 1 ]; then
    ns_control_drop "$pidfile"
    ns_control_drop "$ns/.watchman-tick"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    NS_CONTROL_WATCHMAN=unverified
    return 1
  fi
  if [ -z "$start" ] && ! ns_control_watchman_command_ok "$pid"; then
    NS_CONTROL_WATCHMAN=unverified
    return 1
  fi
  kill "$pid" 2>/dev/null || true
  ns_control_drop "$pidfile"
  ns_control_drop "$ns/.watchman-tick"
  NS_CONTROL_WATCHMAN=stopped
  return 0
}

ns_control_drop_runtime_markers() { # <ns>
  local ns="$1" f
  ns_control_drop "$ns/.shift-armed"
  ns_control_drop "$ns/.ended"
  ns_control_drop "$ns/.session-end"
  ns_control_drop "$ns/.shift-pulse"
  ns_control_drop "$ns/.mint-failed"
  ns_control_drop "$ns/.shift-session"
  ns_control_drop "$ns/.shift-worker"
  ns_control_drop "$ns/.stall"
  ns_control_drop "$ns/.notified"
  ns_control_drop "$ns/.watchman-tick"
  ns_control_drop "$ns/.mutex-scope"
  ns_control_drop "$ns/.lock.d"
  for f in "$ns"/.shift-session.tmp.* "$ns"/.mutex-scope.tmp.*; do
    ns_control_drop "$f"
  done
  ns_lease_reset_stale "$ns" || true
}

ns_control_write_stop() { # <ns> <reason>
  local ns="$1" reason="$2" ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  [ -n "$reason" ] || reason="stopped by owner"
  ns_control_drop "$ns/STOP"
  printf '%s · %s\n' "$reason" "$ts" >"$ns/STOP" || return 1
}

ns_control_log() { # <ns> <line>
  [ -d "$1" ] || return 0
  printf '%s · %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$2" >>"$1/shift-log.md"
}

# Stop-work order: write STOP and stand the watchman down. Keep .shift-armed so
# hardhat stays until clock-out writes ENDED. Reset is the manual escape.
# Prints a short status. Return 0 · 1 usage/resolve · 2 unverified watchman (STOP still written)
ns_control_stop() { # <host-path> [reason]
  local host="$1" reason="${2:-stopped by owner}" rc=0 watch="absent" open=0
  ns_control_resolve "$host" || return 1
  host="$NS_CONTROL_HOST"
  if [ ! -d "$NS_CONTROL_NS" ]; then
    printf 'stop-shift: no .nightshift/ at %s\n' "$NS_CONTROL_WORKSPACE" >&2
    return 1
  fi
  if [ -L "$NS_CONTROL_NS" ]; then
    printf 'stop-shift: .nightshift path is not a usable directory\n' >&2
    return 1
  fi
  ns_control_write_stop "$NS_CONTROL_NS" "$reason"
  if ns_control_stop_watchman "$NS_CONTROL_NS"; then
    watch="${NS_CONTROL_WATCHMAN:-absent}"
  else
    watch="unverified"
    rc=2
  fi
  ns_record_reason "$NS_CONTROL_NS" owner-stop 2>/dev/null || true
  ns_control_log "$NS_CONTROL_NS" "stopped by owner"
  if [ -f "$NS_CONTROL_NS/punch-list.md" ]; then
    open="$(ns_open_boxes "$NS_CONTROL_NS/punch-list.md")"
  fi
  printf 'stopped %s\n' "$NS_CONTROL_NS"
  printf 'workspace %s\n' "$NS_CONTROL_WORKSPACE"
  [ "$host" = "$NS_CONTROL_WORKSPACE" ] || printf 'host %s\n' "$host"
  printf 'watchman %s\n' "$watch"
  printf 'open-items %s\n' "$open"
  printf 'deadline preserved\n'
  return "$rc"
}

# Reset: Stop teardown plus drop deadline, leftover STOP/reason, and tonight's shift policy.
# shift-defaults.json (remembered convenience) and rules.json (permanent boundaries) survive a
# reset exactly like the punch list and parking lot do.
ns_control_reset() { # <host-path>
  local host="$1" rc=0
  ns_control_resolve "$host" || return $?
  if [ -e "$NS_CONTROL_NS/provision-transaction.json" ] || [ -L "$NS_CONTROL_NS/provision-transaction.json" ]; then
    printf 'reset-shift: refuse while provision-transaction.json is open; run provision recover or rollback first\n' >&2
    return 1
  fi
  ns_control_stop "$host" "reset by owner" || {
    rc=$?
    [ "$rc" -eq 2 ] || return "$rc"
  }
  ns_control_drop_runtime_markers "$NS_CONTROL_NS"
  ns_control_drop "$NS_CONTROL_NS/STOP"
  ns_control_drop "$NS_CONTROL_NS/deadline"
  ns_control_drop "$NS_CONTROL_NS/.watch-reason"
  ns_control_drop "$NS_CONTROL_NS/shift-policy.json"
  ns_control_log "$NS_CONTROL_NS" "reset by owner — runtime markers, deadline, and shift policy cleared"
  printf 'reset %s\n' "$NS_CONTROL_NS"
  printf 'deadline removed\n'
  return "$rc"
}

ns_control_purge_allowed() { # <workspace> <ns>
  local ws="$1" ns="$2" root
  ns_control_broad_workspace "$ws" && return 1
  [ -L "$ns" ] && return 1
  [ -d "$ns" ] || return 0
  root="$(cd -P "$ns" 2>/dev/null && pwd)" || return 1
  [ "$root" = "$ns" ] || [ "$root" = "$ws/.nightshift" ] || return 1
  case "$root" in
    "$ws/.nightshift") ;;
    *) return 1 ;;
  esac
  return 0
}

# Purge: Reset, then delete this project's .nightshift/ and a local .nightshift-link.
# Requires --confirm-path equal to the canonical .nightshift directory.
ns_control_purge() { # <host-path> <confirm-path>
  local host="$1" confirm="$2" ns_canon link rc=0 workspace
  [ -n "$confirm" ] || return 1
  [ -n "$host" ] || return 1
  host="$(cd -P "$host" 2>/dev/null && pwd)" || return 1
  NS_CONTROL_HOST="$host"
  if [ -e "$host/.nightshift-link" ] || [ -L "$host/.nightshift-link" ]; then
    workspace="$(ns_control_read_link "$host")" || return 1
  else
    workspace="$host"
  fi
  NS_CONTROL_WORKSPACE="$workspace"
  NS_CONTROL_NS="$workspace/.nightshift"
  ns_canon="$(ns_control_canon_path "$workspace/.nightshift")" || return 1
  confirm="$(ns_control_canon_path "$2")" || return 1
  [ "$confirm" = "$ns_canon" ] || {
    printf 'purge-workspace: --confirm-path must be exactly %s\n' "$ns_canon" >&2
    return 1
  }
  ns_control_purge_allowed "$NS_CONTROL_WORKSPACE" "$ns_canon" || {
    printf 'purge-workspace: refusing to delete %s\n' "$ns_canon" >&2
    return 1
  }
  if [ -d "$NS_CONTROL_NS" ] && [ ! -L "$NS_CONTROL_NS" ]; then
    ns_control_reset "$host" || {
      rc=$?
      [ "$rc" -eq 2 ] || return "$rc"
    }
  fi
  if [ -L "$ns_canon" ]; then
    printf 'purge-workspace: .nightshift path is a symlink\n' >&2
    return 1
  fi
  if [ -e "$ns_canon" ]; then
    rm -rf "$ns_canon" || return 1
  fi
  link="$host/.nightshift-link"
  if [ -e "$link" ] || [ -L "$link" ]; then
    if [ -f "$link" ] || [ -L "$link" ]; then
      rm -f "$link"
    fi
  fi
  printf 'purged %s\n' "$ns_canon"
  printf 'plugin install was not touched\n'
  return "$rc"
}
