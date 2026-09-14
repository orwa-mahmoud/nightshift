#!/usr/bin/env bash
# Session, lease, and shift-ownership fencing shared by Nightshift hooks.

# Cross-session mutex over one .nightshift/ — mkdir is the one atomic primitive every platform
# here ships (macOS has no flock). The holder writes its pid inside; a lock whose holder is
# provably dead is broken on sight, a mid-claim lock (no pid yet) is waited on, never stolen.
# The wait is bounded because a Stop hook must never hang a session over bookkeeping: on
# timeout the caller proceeds without the lock, and the race window is merely what it was
# before locks existed.
ns_lock() { # $1 = the .nightshift dir; bounded ~2s wait
  local dir="$1/.lock.d" holder _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if mkdir "$dir" 2>/dev/null; then
      printf '%s' "$$" >"$dir/pid" 2>/dev/null || true
      return 0
    fi
    holder="$(cat "$dir/pid" 2>/dev/null)"
    case "$holder" in
      '' | *[!0-9]*) ;;
      *) kill -0 "$holder" 2>/dev/null || { rm -rf "$dir" 2>/dev/null; continue; } ;;
    esac
    sleep 0.2
  done
  return 1
}
ns_unlock() { rm -rf "$1/.lock.d" 2>/dev/null; }

# One active shift may keep one conversation identity across several host processes. The
# conversation record preserves continuity; this lease fences the process that currently owns
# that conversation after a watchman revival. Its six lines are:
#   original session scope · host · generation · revival nonce · process pid · process start time
# The nonce is empty for the original interactive process. A watchman writes a new nonce and
# generation before every spawn, so an older process carrying the same session id is fenced.
ns_lease_lock() { # $1 = the .nightshift dir; bounded ~2s wait
  local dir="$1/.lease-lock.d" holder _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if mkdir "$dir" 2>/dev/null; then
      printf '%s' "$$" >"$dir/pid" 2>/dev/null || true
      return 0
    fi
    holder="$(cat "$dir/pid" 2>/dev/null)"
    case "$holder" in
      '' | *[!0-9]*) ;;
      *) kill -0 "$holder" 2>/dev/null || { rm -rf "$dir" 2>/dev/null; continue; } ;;
    esac
    sleep 0.2
  done
  return 1
}
ns_lease_unlock() { rm -rf "$1/.lease-lock.d" 2>/dev/null; }

ns_lease_safe_line() {
  case "$1" in
    *$'\n'* | *$'\r'*) return 1 ;;
  esac
  return 0
}

ns_session_write() { # <ns> <sid> <transcript> <pid> <start> <host> <tmp>; validates and writes tmp
  local ns="$1" sid="$2" transcript="$3" pid="$4" start="$5" host="$6" tmp="$7"
  [ -d "$ns" ] && [ -n "$sid" ] || return 1
  ns_lease_safe_line "$sid" && ns_lease_safe_line "$transcript" \
    && ns_lease_safe_line "$pid" && ns_lease_safe_line "$start" || return 1
  case "$pid" in *[!0-9]*) return 1 ;; esac
  case "$host" in claude | codex | cursor) ;; *) return 1 ;; esac
  (umask 077; printf '%s\n%s\n%s\n%s\n%s\n' \
    "$sid" "$transcript" "$pid" "$start" "$host" >"$tmp") || {
    rm -f "$tmp"
    return 1
  }
}

ns_session_claim() { # <ns> <sid> <transcript> <pid> <start> <host>; complete file appears atomically
  local ns="$1" tmp rc
  tmp="$ns/.shift-session.tmp.$$.$RANDOM"
  ns_session_write "$ns" "$2" "$3" "$4" "$5" "$6" "$tmp" || return 1
  [ -L "$ns/.shift-session" ] && rm -f "$ns/.shift-session"
  ln "$tmp" "$ns/.shift-session" 2>/dev/null
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

# Replace an existing conversation record. Claim creates; this updates the bound session
# after a revival or interactive reclaim without losing the race to a second first-writer.
ns_session_replace() { # <ns> <sid> <transcript> <pid> <start> <host>
  local ns="$1" tmp
  tmp="$ns/.shift-session.tmp.$$.$RANDOM"
  ns_session_write "$ns" "$2" "$3" "$4" "$5" "$6" "$tmp" || return 1
  mv -f "$tmp" "$ns/.shift-session"
}

# Prefer the recorded host pid when it is still the same process; otherwise walk ancestry.
# Sets NS_CURRENT_PID and NS_CURRENT_START for the caller.
# shellcheck disable=SC2034
ns_host_process() { # <host> <ns> <fallback-pid>
  local rec_pid rec_start live
  NS_CURRENT_PID=""
  NS_CURRENT_START=""
  rec_pid="$(ns_session_line "$2" 3 | tr -d '[:space:]')"
  rec_start="$(ns_session_line "$2" 4)"
  case "$rec_pid" in
    '' | *[!0-9]*) ;;
    *)
      if [ "$rec_pid" -gt 1 ] && kill -0 "$rec_pid" 2>/dev/null; then
        live="$(ns_process_start "$rec_pid" 2>/dev/null || true)"
        if [ -n "$live" ] && [ "$live" = "$rec_start" ]; then
          NS_CURRENT_PID="$rec_pid"
          NS_CURRENT_START="$rec_start"
          return 0
        fi
      fi
      ;;
  esac
  NS_CURRENT_PID="$(ns_ancestor_pid "$1" "$3" 2>/dev/null || true)"
  [ -z "$NS_CURRENT_PID" ] || NS_CURRENT_START="$(ns_process_start "$NS_CURRENT_PID" 2>/dev/null || true)"
}

ns_lease_load() { # $1 = the .nightshift dir; one descriptor gives one coherent snapshot
  local f="$1/.shift-lease" _
  NS_LEASE_SID=""
  NS_LEASE_HOST=""
  NS_LEASE_GENERATION=""
  NS_LEASE_NONCE=""
  NS_LEASE_PID=""
  NS_LEASE_START=""
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  {
    IFS= read -r NS_LEASE_SID &&
      IFS= read -r NS_LEASE_HOST &&
      IFS= read -r NS_LEASE_GENERATION &&
      IFS= read -r NS_LEASE_NONCE &&
      IFS= read -r NS_LEASE_PID &&
      IFS= read -r NS_LEASE_START || return 1
    if IFS= read -r _; then return 1; fi
  } <"$f"
  # Native Windows writers use CRLF; read -r keeps the CR and the line checks refuse it.
  NS_LEASE_SID="${NS_LEASE_SID%$'\r'}"
  NS_LEASE_HOST="${NS_LEASE_HOST%$'\r'}"
  NS_LEASE_GENERATION="${NS_LEASE_GENERATION%$'\r'}"
  NS_LEASE_NONCE="${NS_LEASE_NONCE%$'\r'}"
  NS_LEASE_PID="${NS_LEASE_PID%$'\r'}"
  NS_LEASE_START="${NS_LEASE_START%$'\r'}"
  ns_lease_safe_line "$NS_LEASE_SID" && ns_lease_safe_line "$NS_LEASE_HOST" \
    && ns_lease_safe_line "$NS_LEASE_GENERATION" && ns_lease_safe_line "$NS_LEASE_NONCE" \
    && ns_lease_safe_line "$NS_LEASE_PID" && ns_lease_safe_line "$NS_LEASE_START" || return 1
  case "$NS_LEASE_HOST" in claude | codex | cursor) ;; *) return 1 ;; esac
  case "$NS_LEASE_GENERATION" in '' | *[!0-9]*) return 1 ;; esac
  [ "$NS_LEASE_GENERATION" -gt 0 ] 2>/dev/null || return 1
  case "$NS_LEASE_NONCE" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$NS_LEASE_PID" in *[!0-9]*) return 1 ;; esac
  [ -n "$NS_LEASE_PID" ] || [ -z "$NS_LEASE_START" ] || return 1
  [ -n "$NS_LEASE_SID" ] || [ -n "$NS_LEASE_NONCE" ] || return 1
  return 0
}
ns_lease_valid() { ns_lease_load "$1"; }

ns_lease_write_unlocked() { # <ns> <sid> <host> <generation> <nonce> <pid> <start>
  local ns="$1" sid="$2" host="$3" generation="$4" nonce="$5" pid="$6" start="$7" tmp
  ns_lease_safe_line "$sid" && ns_lease_safe_line "$start" || return 1
  case "$host" in claude | codex | cursor) ;; *) return 1 ;; esac
  case "$generation" in '' | *[!0-9]*) return 1 ;; esac
  [ "$generation" -gt 0 ] 2>/dev/null || return 1
  case "$nonce" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$pid" in *[!0-9]*) return 1 ;; esac
  [ -n "$sid" ] || [ -n "$nonce" ] || return 1
  [ -n "$pid" ] || [ -z "$start" ] || return 1
  tmp="$ns/.shift-lease.tmp.$$.$RANDOM"
  (umask 077; printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$sid" "$host" "$generation" "$nonce" "$pid" "$start" >"$tmp") || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$ns/.shift-lease" || {
    rm -f "$tmp"
    return 1
  }
}

ns_lease_claim_initial() { # <ns> <sid> <host> <pid> <start>
  local ns="$1" sid="$2" host="$3" pid="$4" start="$5" rc
  [ -n "$sid" ] || return 1
  ns_lease_lock "$ns" || return 2
  if [ -e "$ns/.shift-lease" ] || [ -L "$ns/.shift-lease" ]; then
    ns_lease_valid "$ns"
    rc=$?
    ns_lease_unlock "$ns"
    return "$rc"
  fi
  ns_lease_write_unlocked "$ns" "$sid" "$host" 1 "" "$pid" "$start"
  rc=$?
  ns_lease_unlock "$ns"
  return "$rc"
}

ns_lease_takeover() { # <ns> <possibly-empty-sid> <host>; prints: generation nonce
  local ns="$1" sid="$2" host="$3" generation=0 nonce rc existing_sid
  ns_lease_lock "$ns" || return 2
  if [ -e "$ns/.shift-lease" ] || [ -L "$ns/.shift-lease" ]; then
    if ! ns_lease_valid "$ns"; then
      ns_lease_unlock "$ns"
      return 1
    fi
    existing_sid="$NS_LEASE_SID"
    [ -z "$existing_sid" ] || sid="$existing_sid"
    generation="$NS_LEASE_GENERATION"
  fi
  generation=$((generation + 1))
  nonce="$host.$generation.$$.$RANDOM.$RANDOM"
  ns_lease_write_unlocked "$ns" "$sid" "$host" "$generation" "$nonce" "" ""
  rc=$?
  ns_lease_unlock "$ns"
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s %s' "$generation" "$nonce"
}

ns_lease_nonce_matches() { # <ns> <host> <nonce> <generation>; ignores sid for fresh fallback
  local ns="$1" host="$2" nonce="$3" generation="$4"
  [ -n "$nonce" ] && [ -n "$generation" ] || return 1
  ns_lease_load "$ns" || return 1
  [ "$NS_LEASE_HOST" = "$host" ] || return 1
  [ "$NS_LEASE_GENERATION" = "$generation" ] || return 1
  [ "$NS_LEASE_NONCE" = "$nonce" ]
}

ns_lease_rebind_session() { # <ns> <sid> <host> <nonce> <generation>; fills an empty scope
  local ns="$1" sid="$2" host="$3" nonce="$4" generation="$5" scope pid start rc
  [ -n "$sid" ] || return 1
  ns_lease_lock "$ns" || return 2
  if ! ns_lease_nonce_matches "$ns" "$host" "$nonce" "$generation"; then
    ns_lease_unlock "$ns"
    return 1
  fi
  scope="$NS_LEASE_SID"
  [ -n "$scope" ] || scope="$sid"
  pid="$NS_LEASE_PID"
  start="$NS_LEASE_START"
  ns_lease_write_unlocked "$ns" "$scope" "$host" "$generation" "$nonce" "$pid" "$start"
  rc=$?
  ns_lease_unlock "$ns"
  return "$rc"
}

ns_lease_attach_process() { # <ns> <host> <nonce> <generation> <pid> <start>
  local ns="$1" host="$2" nonce="$3" generation="$4" pid="$5" start="$6" sid rc
  ns_lease_lock "$ns" || return 2
  if ! ns_lease_nonce_matches "$ns" "$host" "$nonce" "$generation"; then
    ns_lease_unlock "$ns"
    return 1
  fi
  sid="$NS_LEASE_SID"
  ns_lease_write_unlocked "$ns" "$sid" "$host" "$generation" "$nonce" "$pid" "$start"
  rc=$?
  ns_lease_unlock "$ns"
  return "$rc"
}

ns_lease_reclaim_interactive() { # <ns> <sid> <host> <old-generation> <pid> <start>
  local ns="$1" sid="$2" host="$3" old_generation="$4" pid="$5" start="$6"
  local lease_sid lease_host generation nonce old_pid old_start rc
  [ -n "$pid" ] || return 1
  ns_lease_lock "$ns" || return 2
  if ! ns_lease_valid "$ns"; then
    ns_lease_unlock "$ns"
    return 1
  fi
  lease_sid="$NS_LEASE_SID"
  lease_host="$NS_LEASE_HOST"
  generation="$NS_LEASE_GENERATION"
  nonce="$NS_LEASE_NONCE"
  old_pid="$NS_LEASE_PID"
  old_start="$NS_LEASE_START"
  if [ "$lease_sid" != "$sid" ] || [ "$lease_host" != "$host" ] \
    || [ "$generation" != "$old_generation" ] || [ -n "$nonce" ]; then
    ns_lease_unlock "$ns"
    return 1
  fi
  ns_recorded_process "$old_pid" "$old_start"
  rc=$?
  if [ "$rc" -ne 1 ]; then
    ns_lease_unlock "$ns"
    return 1
  fi
  generation=$((generation + 1))
  ns_lease_write_unlocked "$ns" "$sid" "$host" "$generation" "" "$pid" "$start"
  rc=$?
  ns_lease_unlock "$ns"
  return "$rc"
}

# Take back a lease whose recovery holder is gone. A revival carries a nonce and the pid of
# the process it fenced the site for; when that process is provably dead the site has no owner,
# and the conversation the record names may resume it at the next generation with an empty
# nonce and its own process. Provable death only, under the lease lock: an unreadable pid, an
# empty one, or a process the host cannot classify all leave the lease alone.
ns_lease_reclaim_recorded() { # <ns> <sid> <host> <pid> <start>
  local ns="$1" sid="$2" host="$3" pid="$4" start="$5" generation reclaimed rc
  [ -n "$sid" ] || return 1
  ns_lease_lock "$ns" || return 1
  if ! ns_lease_valid "$ns"; then
    ns_lease_unlock "$ns"
    return 1
  fi
  if [ "$NS_LEASE_HOST" != "$host" ] || [ -z "$NS_LEASE_NONCE" ] || [ -z "$NS_LEASE_PID" ]; then
    ns_lease_unlock "$ns"
    return 1
  fi
  ns_recorded_process "$NS_LEASE_PID" "$NS_LEASE_START"
  rc=$?
  if [ "$rc" -ne 1 ]; then
    ns_lease_unlock "$ns"
    return 1
  fi
  generation="$NS_LEASE_GENERATION"
  reclaimed=$((generation + 1))
  ns_lease_write_unlocked "$ns" "$sid" "$host" "$reclaimed" "" "$pid" "$start"
  rc=$?
  ns_lease_unlock "$ns"
  [ "$rc" -eq 0 ] || return 1
  ns_shift_log "$ns" "lease reclaimed by the recorded conversation after a dead recovery attempt (generation $generation → $reclaimed)"
  return 0
}

ns_lease_allows() { # <ns> <sid> <host> <pid> <start> <nonce> <generation>
  local ns="$1" sid="$2" host="$3" pid="$4" start="$5" nonce="$6" generation="$7"
  local lease_sid lease_host lease_generation lease_nonce lease_pid lease_start rc
  ns_lease_load "$ns" || return 2
  lease_sid="$NS_LEASE_SID"
  lease_host="$NS_LEASE_HOST"
  lease_generation="$NS_LEASE_GENERATION"
  lease_nonce="$NS_LEASE_NONCE"
  lease_pid="$NS_LEASE_PID"
  lease_start="$NS_LEASE_START"
  [ "$lease_host" = "$host" ] || return 1
  if [ -n "$lease_nonce" ]; then
    if [ "$nonce" = "$lease_nonce" ] && [ "$generation" = "$lease_generation" ]; then
      return 0
    fi
    return 1
  fi
  [ "$lease_sid" = "$sid" ] || return 1
  [ -z "$nonce" ] && [ -z "$generation" ] || return 1
  [ -n "$lease_pid" ] || return 0 # Codex cannot vouch for an interactive process pid.
  if [ -n "$pid" ] && [ "$pid" = "$lease_pid" ]; then
    ns_recorded_process "$lease_pid" "$lease_start"
    return
  fi
  [ -n "$pid" ] || return 1
  ns_recorded_process "$lease_pid" "$lease_start"
  rc=$?
  [ "$rc" -eq 1 ] || return 1
  ns_lease_reclaim_interactive "$ns" "$sid" "$host" "$lease_generation" "$pid" "$start"
}

ns_lease_release() { # $1 = the .nightshift dir
  local ns="$1" rc
  ns_lease_lock "$ns" || return 1
  rm -f "$ns/.shift-lease"
  rc=$?
  ns_lease_unlock "$ns"
  return "$rc"
}

ns_lease_release_retry() { # $1 = the .nightshift dir
  ns_lease_release "$1" && return 0
  sleep 0.2
  ns_lease_release "$1"
}

# One ownership protocol for every host hook. Wrappers claim the first session and emit
# the host-specific deny/pass. Unbound runs before that claim; rebind runs after it;
# authorize runs after Start's binding probe so a losing Start cannot pass as a helper.
# Uses NS, SID, TPATH, LEASE_NONCE, LEASE_GENERATION, NIGHTSHIFT_REVIVAL.
# Sets NS_SHIFT_REC and NS_SHIFT_FAIL.
# Returns 0 = continue as owner, 1 = pass through, 2 = fail closed.
# shellcheck disable=SC2034
ns_shift_unbound() { # <host> <mode:hardhat|gate>
  local host="$1" mode="$2" bound
  : "${LEASE_NONCE:=}" "${LEASE_GENERATION:=}"
  NS_SHIFT_FAIL=""
  bound="$(ns_session_line "$NS" 1)"
  if [ -z "$bound" ] && ns_lease_load "$NS" && [ -n "$NS_LEASE_NONCE" ]; then
    if [ "${NIGHTSHIFT_REVIVAL:-}" != "1" ] \
      || ! ns_lease_nonce_matches "$NS" "$host" "$LEASE_NONCE" "$LEASE_GENERATION"; then
      if [ "$mode" = hardhat ]; then
        NS_SHIFT_FAIL="BLOCKED: this shift is being recovered before its new conversation is bound. Reopen the recorded conversation and retry after recovery."
        return 2
      fi
      return 1
    fi
  fi
  return 0
}

# shellcheck disable=SC2034
ns_shift_rebind() { # <host> <pid> <start> <mode:hardhat|gate>
  local host="$1" pid="$2" start="$3" mode="$4"
  local rec session_pid transcript
  : "${LEASE_NONCE:=}" "${LEASE_GENERATION:=}"
  NS_SHIFT_REC=""
  NS_SHIFT_FAIL=""

  rec="$(ns_session_line "$NS" 1)"
  if [ "${NIGHTSHIFT_REVIVAL:-}" = "1" ]; then
    if ! ns_lease_nonce_matches "$NS" "$host" "$LEASE_NONCE" "$LEASE_GENERATION"; then
      if [ "$mode" = hardhat ]; then
        NS_SHIFT_FAIL="BLOCKED: this recovered worker no longer owns the shift. Reopen the recorded conversation instead of continuing an older process."
        return 2
      fi
      return 1
    fi
    if [ -n "${SID:-}" ]; then
      if [ -z "$NS_LEASE_SID" ]; then
        if ! ns_lease_rebind_session "$NS" "$SID" "$host" "$LEASE_NONCE" "$LEASE_GENERATION"; then
          if [ "$mode" = hardhat ]; then
            NS_SHIFT_FAIL="BLOCKED: the shift process lease could not bind the recovered conversation. Issue STOP from another session, then run Start again."
            return 2
          fi
          return 1
        fi
      fi
      session_pid="$(ns_session_line "$NS" 3 | tr -d '[:space:]')"
      if [ "$rec" != "$SID" ] || { [ -n "$pid" ] && [ "$session_pid" != "$pid" ]; }; then
        transcript="${TPATH:-$(ns_session_line "$NS" 2)}"
        if ! ns_session_replace "$NS" "$SID" "$transcript" "$pid" "$start" "$host"; then
          if [ "$mode" = hardhat ]; then
            NS_SHIFT_FAIL="BLOCKED: the recovered conversation could not update .shift-session. Issue STOP from another session, then run Start again."
            return 2
          fi
          return 1
        fi
      fi
      if [ -n "$pid" ]; then
        if ! ns_lease_load "$NS"; then
          if [ "$mode" = hardhat ]; then
            NS_SHIFT_FAIL="BLOCKED: the recovered process lease became unreadable. Issue STOP from another session, then run Start again."
            return 2
          fi
          return 1
        fi
        if [ "$NS_LEASE_PID" != "$pid" ]; then
          if ! ns_lease_attach_process "$NS" "$host" "$LEASE_NONCE" "$LEASE_GENERATION" "$pid" "$start"; then
            if [ "$mode" = hardhat ]; then
              NS_SHIFT_FAIL="BLOCKED: the recovered process could not refresh its shift lease. Reopen the recorded conversation."
              return 2
            fi
            return 1
          fi
        fi
      fi
      rec="$SID"
    fi
  fi

  NS_SHIFT_REC="$rec"
  return 0
}

# shellcheck disable=SC2034
ns_shift_authorize() { # <host> <pid> <start> <mode:hardhat|gate>
  local host="$1" pid="$2" start="$3" mode="$4"
  local rec session_pid lease_scope check_sid lease_rc transcript worker
  : "${LEASE_NONCE:=}" "${LEASE_GENERATION:=}"
  NS_SHIFT_FAIL=""
  rec="${NS_SHIFT_REC:-$(ns_session_line "$NS" 1)}"

  lease_scope=""
  if ns_lease_valid "$NS"; then lease_scope="$NS_LEASE_SID"; fi
  worker=""
  if [ "$host" = cursor ]; then
    worker="$(ns_cursor_worker_id "$NS")"
  fi
  if [ -n "$rec" ] && [ -n "${SID:-}" ] && [ "$SID" != "$rec" ] \
    && [ "$SID" != "$lease_scope" ] && [ "$SID" != "$worker" ] \
    && [ "${NIGHTSHIFT_REVIVAL:-}" != "1" ]; then
    return 1
  fi

  if [ -z "$rec" ]; then
    return 0
  fi

  check_sid="${SID:-$rec}"
  if [ ! -e "$NS/.shift-lease" ] && [ ! -L "$NS/.shift-lease" ]; then
    if ! ns_lease_claim_initial "$NS" "$rec" "$host" "$pid" "$start"; then
      if [ "$mode" = hardhat ]; then
        NS_SHIFT_FAIL="BLOCKED: the shift process lease could not be created. Issue STOP from another session, then run Start again."
      else
        NS_SHIFT_FAIL="DO NOT STOP — the shift process lease is unreadable. Issue STOP from another session, then run Start again."
      fi
      return 2
    fi
  elif [ "$host" = cursor ] && ns_lease_valid "$NS" \
    && [ "$NS_LEASE_HOST" = claude ] && [ "$NS_LEASE_SID" = "$rec" ] \
    && [ -z "$NS_LEASE_NONCE" ] && [ -z "${LEASE_NONCE:-}" ]; then
    # Cursor IDE also ran Claude marketplace hooks, which leased as host claude while
    # .shift-session already names cursor. Reclaim so the Cursor hardhat can own the shift.
    ns_lease_lock "$NS" || {
      if [ "$mode" = hardhat ]; then
        NS_SHIFT_FAIL="BLOCKED: the shift process lease could not be reclaimed for Cursor. Issue STOP from another session, then run Start again."
      else
        NS_SHIFT_FAIL="DO NOT STOP — the shift process lease could not be reclaimed for Cursor. Issue STOP from another session, then run Start again."
      fi
      return 2
    }
    if ! ns_lease_write_unlocked "$NS" "$rec" cursor 1 "" "$pid" "$start"; then
      ns_lease_unlock "$NS"
      if [ "$mode" = hardhat ]; then
        NS_SHIFT_FAIL="BLOCKED: the shift process lease could not be reclaimed for Cursor. Issue STOP from another session, then run Start again."
      else
        NS_SHIFT_FAIL="DO NOT STOP — the shift process lease could not be reclaimed for Cursor. Issue STOP from another session, then run Start again."
      fi
      return 2
    fi
    ns_lease_unlock "$NS"
  fi

  ns_lease_allows "$NS" "$check_sid" "$host" "$pid" "$start" \
    "$LEASE_NONCE" "$LEASE_GENERATION"
  lease_rc=$?
  # A recovery attempt that died holds nothing. The conversation the record names takes the
  # lease back here rather than waiting for a worker that will never report; a live holder,
  # a scope the record no longer names, and a process the host cannot classify keep the fence.
  if [ "$lease_rc" -eq 1 ] && [ -n "${SID:-}" ] && [ "$SID" = "$rec" ] \
    && [ -z "$LEASE_NONCE" ] \
    && ns_lease_reclaim_recorded "$NS" "$rec" "$host" "$pid" "$start"; then
    lease_rc=0
  fi
  if [ "$lease_rc" -eq 1 ]; then
    if [ "$mode" = hardhat ]; then
      if ns_lease_load "$NS" && [ -n "$NS_LEASE_NONCE" ] \
        && [ -n "$NS_LEASE_PID" ] && ns_recorded_process "$NS_LEASE_PID" "$NS_LEASE_START"; then
        NS_SHIFT_FAIL="BLOCKED: this shift is being recovered in another process. Wait or issue STOP from a separate session; reopening the recorded conversation stays blocked while that worker holds the lease."
      else
        NS_SHIFT_FAIL="BLOCKED: this shift continued in a recovered process. Reopen the recorded conversation before using tools here."
      fi
      return 2
    fi
    return 1
  fi
  if [ "$lease_rc" -ne 0 ]; then
    if [ "$mode" = hardhat ]; then
      NS_SHIFT_FAIL="BLOCKED: this shift continued in a recovered process. Reopen the recorded conversation before using tools here."
    else
      NS_SHIFT_FAIL="DO NOT STOP — the shift process lease is unreadable. Issue STOP from another session, then run Start again."
    fi
    return 2
  fi

  if [ -n "${SID:-}" ] && [ -n "$pid" ] && [ -z "$LEASE_NONCE" ]; then
    if ! ns_lease_load "$NS"; then
      if [ "$mode" = hardhat ]; then
        NS_SHIFT_FAIL="BLOCKED: the shift process lease became unreadable. Issue STOP from another session, then run Start again."
      else
        NS_SHIFT_FAIL="DO NOT STOP — the shift process lease became unreadable. Issue STOP from another session, then run Start again."
      fi
      return 2
    fi
    session_pid="$(ns_session_line "$NS" 3 | tr -d '[:space:]')"
    if [ "$NS_LEASE_PID" = "$pid" ] && [ "$session_pid" != "$pid" ]; then
      transcript="${TPATH:-$(ns_session_line "$NS" 2)}"
      if ! ns_session_replace "$NS" "$SID" "$transcript" "$pid" "$start" "$host"; then
        if [ "$mode" = hardhat ]; then
          NS_SHIFT_FAIL="BLOCKED: the reclaimed interactive process could not refresh .shift-session. Issue STOP from another session, then run Start again."
        else
          NS_SHIFT_FAIL="DO NOT STOP — the reclaimed process could not refresh .shift-session. Issue STOP from another session, then run Start again."
        fi
        return 2
      fi
    fi
  fi

  NS_SHIFT_REC="$rec"
  return 0
}

# Gate wrappers have no Start probe between rebind and authorize.
ns_shift_ownership() { # <host> <pid> <start> <mode:hardhat|gate>
  ns_shift_rebind "$1" "$2" "$3" "$4" || return "$?"
  ns_shift_authorize "$1" "$2" "$3" "$4"
}

# Fence a recovery child: take the lease, export the capability, attach the pid, wait.
# Remaining arguments are the command line. Returns 3 when takeover fails.
ns_watchman_run_child() { # <ns> <host> <sid> <work_target> <project_env> <project> <cmd...>
  local ns="$1" host="$2" sid="$3" work="$4" env_name="$5" project="$6"
  local lease generation nonce child start rc
  shift 6
  lease="$(ns_lease_takeover "$ns" "$sid" "$host")" || return 3
  generation="${lease%% *}"
  nonce="${lease#* }"
  (
    cd "$work" || exit 1
    env "${env_name}=${project}" \
      NIGHTSHIFT_REVIVAL=1 \
      NIGHTSHIFT_LEASE_GENERATION="$generation" \
      NIGHTSHIFT_LEASE_NONCE="$nonce" \
      "$@" >/dev/null 2>&1
  ) &
  child=$!
  start="$(ns_process_start "$child" 2>/dev/null || true)"
  ns_lease_attach_process "$ns" "$host" "$nonce" "$generation" "$child" "$start" || true
  wait "$child"
  rc=$?
  return "$rc"
}

# Exit 0 from a revival child is not proof it worked — a denied claude -p still quits clean.
# 0 = a box moved, the pulse is fresh, or the lease holder is still alive.
ns_watchman_revival_proved() { # <ns> <sentinel> <interval_min> <open_before>
  local ns="$1" interval="${3:-0}" before="${4:-}"
  local now_open
  if [ -f "$ns/.ended" ] && [ ! -L "$ns/.ended" ]; then
    return 0
  fi
  now_open="$(ns_open_boxes "$ns/punch-list.md" 2>/dev/null)" || now_open=""
  case "$before" in
    '' | *[!0-9]*) ;;
    *)
      case "$now_open" in
        '' | *[!0-9]*) ;;
        *) [ "$now_open" -lt "$before" ] && return 0 ;;
      esac
      ;;
  esac
  if ns_pulse_fresh "$ns" "$interval"; then
    return 0
  fi
  ns_lease_pid_live "$ns"
}

# After a clock-out spawn: 0 = the shift ended, 1 = still armed (sentinel refreshed,
# recovery nonce restored to interactive when the child is proven dead). Callers stand
# down on 1 — production must not retry terminal clock-out. Extra args are ignored.
ns_watchman_clockout_pending() { # <ns> <sentinel> [ignored-max-wakes] [ignored-wake]
  if [ -f "$1/.ended" ] && [ ! -L "$1/.ended" ]; then
    ns_lease_release "$1" || true
    return 0
  fi
  : >"$2" 2>/dev/null || true
  ns_lease_restore_interactive "$1" || true
  return 1
}

# Convert a dead recovery nonce back to the recorded interactive session. Proves the
# lease-holder pid is dead (or never attached) under the lease lock. Empty sid with a
# nonce releases instead of writing an unowned interactive lease.
ns_lease_restore_interactive() { # <ns>
  local ns="$1" sid host generation rc
  ns_lease_lock "$ns" || return 1
  if ! ns_lease_valid "$ns"; then
    ns_lease_unlock "$ns"
    return 1
  fi
  if [ -z "$NS_LEASE_NONCE" ]; then
    ns_lease_unlock "$ns"
    return 0
  fi
  if [ -n "$NS_LEASE_PID" ]; then
    ns_recorded_process "$NS_LEASE_PID" "$NS_LEASE_START"
    rc=$?
    if [ "$rc" -ne 1 ]; then
      ns_lease_unlock "$ns"
      return 1
    fi
  fi
  sid="$NS_LEASE_SID"
  host="$NS_LEASE_HOST"
  generation=$((NS_LEASE_GENERATION + 1))
  if [ -z "$sid" ]; then
    rm -f "$ns/.shift-lease"
    rc=$?
    ns_lease_unlock "$ns"
    return "$rc"
  fi
  # Empty pid: the recorded session id may reclaim. Copying a still-live
  # recorded pid would fence that conversation's next tool process.
  ns_lease_write_unlocked "$ns" "$sid" "$host" "$generation" "" "" ""
  rc=$?
  ns_lease_unlock "$ns"
  return "$rc"
}

ns_lease_reset_stale() { # $1 = .nightshift; caller has proved no process or watchman owns it
  local ns="$1" rc
  rm -rf "$ns/.lease-lock.d" 2>/dev/null
  ns_lease_lock "$ns" || return 1
  rm -f "$ns/.shift-lease" "$ns"/.shift-lease.tmp.*
  rc=$?
  ns_lease_unlock "$ns"
  return "$rc"
}

# Every tool that speaks Claude Code's plugin interface executes these same hooks, so a hook
# cannot assume Claude is the host it runs in. The transcript path names the writer: Cursor
# keeps its conversations under ~/.cursor, and a record claimed from one belongs to Cursor —
# Claude's watchman must stand down from it rather than fire `claude --resume` at a
# conversation it can never reach. Paths without a known foreign marker stay claude.
ns_claude_session_host() { # <transcript-path>
  case "$1" in
    */.cursor/*) printf 'cursor' ;;
    *) printf 'claude' ;;
  esac
}

# Cursor IDE loads Claude marketplace plugins and runs their hooks in the same Agent tab.
# Those Claude-entry hooks must not claim or fence a Cursor-owned shift. True when the
# transcript lives under ~/.cursor, or .shift-session already records host cursor.
ns_claude_foreign_cursor_surface() { # <ns-dir> <transcript-path>
  case "$2" in
    */.cursor/*) return 0 ;;
  esac
  [ "$(ns_session_host "$1")" = "cursor" ]
}

# True when .shift-session is a real file, not a planted symlink.
ns_session_present() { # <ns-dir>
  local rec="$1/.shift-session"
  [ -f "$rec" ] && [ ! -L "$rec" ]
}

# Prints one line of a real .shift-session file. Empty when the path is missing or a symlink.
ns_session_line() { # <ns-dir> <line>
  ns_session_present "$1" || return 0
  sed -n "$2p" "$1/.shift-session" 2>/dev/null
}

# Which host owns this shift. Absent means a record written before hosts were distinguished,
# and every such record is Claude's — nothing else could have written one.
ns_session_host() {
  local h
  h="$(ns_session_line "$1" 5 | tr -d '[:space:]')"
  printf '%s' "${h:-claude}"
}

# Codex `exec resume` accepts a session/thread id, not a rollout path or ChatGPT scratch handle.
# Fail closed on anything that is not a known resumable shape so recovery never claims it
# resumed a thread it did not.
# Prints: missing | resumable | malformed | unsupported
# Return 0 only for resumable.
ns_codex_identity_kind() {
  local id="$1"
  if [ -z "$id" ]; then
    printf 'missing'
    return 1
  fi
  if printf '%s' "$id" | grep -qE '[[:space:]/\\\$`;|&<>*]'; then
    printf 'malformed'
    return 1
  fi
  case "$id" in
    thread_*|conv_*|chatgpt-*|rollout-*|task_*|scratch_*|local|unknown)
      printf 'unsupported'
      return 1
      ;;
  esac
  if printf '%s' "$id" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
    printf 'resumable'
    return 0
  fi
  if printf '%s' "$id" | grep -Eq '^[0-9a-fA-F]{32,}$'; then
    printf 'resumable'
    return 0
  fi
  printf 'unsupported'
  return 1
}

# Cursor CLI worker — the resumable id in ~/.cursor/chats. The origin IDE conversation
# stays on .shift-session; this file is the id agent --resume may legally receive.
ns_cursor_worker_present() { # <ns>
  [ -f "$1/.shift-worker" ] && [ ! -L "$1/.shift-worker" ]
}

ns_cursor_worker_id() { # <ns>
  ns_cursor_worker_present "$1" || return 0
  sed -n 1p "$1/.shift-worker" 2>/dev/null
}

ns_cursor_worker_write() { # <ns> <cli_id>
  local ns="$1" id="$2" tmp
  [ -d "$ns" ] && [ -n "$id" ] || return 1
  ns_lease_safe_line "$id" || return 1
  case "$id" in
    *[[:space:]/\\\$\`\;\|\&\<\>\*]*) return 1 ;;
  esac
  tmp="$ns/.shift-worker.tmp.$$.$RANDOM"
  (umask 077; printf '%s\n' "$id" >"$tmp") || { rm -f "$tmp"; return 1; }
  [ -L "$ns/.shift-worker" ] && rm -f "$ns/.shift-worker"
  mv -f "$tmp" "$ns/.shift-worker"
}

ns_cursor_store_kind() { # <transcript-path>
  case "$1" in
    */agent-transcripts/*) printf 'ide' ;;
    */.cursor/chats/* | */.cursor/chats) printf 'cli' ;;
    *) printf 'unknown' ;;
  esac
}

# Origin IDE tab while a different CLI worker holds the shift.
ns_cursor_stale_origin() { # <ns> <sid>
  local rec worker
  rec="$(ns_session_line "$1" 1)"
  worker="$(ns_cursor_worker_id "$1")"
  [ -n "$rec" ] && [ -n "$worker" ] && [ -n "${2:-}" ] \
    && [ "$2" = "$rec" ] && [ "$2" != "$worker" ]
}

ns_cursor_resume_command() { # <ns> <workspace>
  local worker workspace
  worker="$(ns_cursor_worker_id "$1")"
  workspace="$2"
  [ -n "$worker" ] && [ -n "$workspace" ] || return 1
  printf 'agent --resume="%s" --workspace "%s"' "$worker" "$workspace"
}

ns_cursor_pointer_message() { # <ns> <workspace>
  local cmd
  cmd="$(ns_cursor_resume_command "$1" "$2")" || return 1
  printf 'BLOCKED: this shift session died and continued in a recovered CLI session. To see it, run this in a terminal: %s. To stop it from this chat, ask Nightshift to stop.' "$cmd"
}

# Owner asking this tab to end the shift — not ordinary work on the dead thread.
ns_cursor_stop_request() { # <prompt>
  printf '%s' "${1:-}" | grep -qiE \
    'ask[[:space:]]+nightshift[[:space:]]+to[[:space:]]+stop|[[:space:]/]nightshift[[:space:]]+stop|/nightshift:stop|stop[[:space:]]+the[[:space:]]+shift'
}


# .shift-pulse — overwrite-only liveness: "epoch session-id" (unix seconds).
# Fresh: epoch within 2 * watchMinutes. Stale: older than that, or never written
# and at least two wake intervals have passed since arm (or the supplied clock).
ns_pulse_epoch() { # <ns>
  local f="$1/.shift-pulse" line epoch
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  IFS= read -r line <"$f" || true
  epoch="${line%% *}"
  case "$epoch" in '' | *[!0-9]*) return 0 ;; esac
  printf '%s' "$epoch"
}

ns_pulse_fresh() { # <ns> <interval_min>
  local epoch now window interval="${2:-0}"
  epoch="$(ns_pulse_epoch "$1")"
  [ -n "$epoch" ] || return 1
  case "$interval" in '' | *[!0-9]*) interval=0 ;; esac
  window=$((interval * 120))
  now="$(date +%s)"
  [ $((now - epoch)) -lt "$window" ]
}

ns_pulse_stale() { # <ns> <interval_min> [clock_epoch]
  local ns="$1" interval="${2:-0}" clock="${3:-}" now epoch window armed
  case "$interval" in '' | *[!0-9]*) interval=0 ;; esac
  window=$((interval * 120))
  now="$(date +%s)"
  epoch="$(ns_pulse_epoch "$ns")"
  if [ -n "$epoch" ]; then
    [ $((now - epoch)) -ge "$window" ]
    return
  fi
  armed="$ns/.shift-armed"
  if [ -f "$armed" ] && [ ! -L "$armed" ]; then
    clock="$(ns_mtime "$armed")"
  fi
  case "$clock" in '' | *[!0-9]*) clock="$now" ;; esac
  [ $((now - clock)) -ge "$window" ]
}

# Live lease holder pid. Empty pid is not live and does not decide death.
ns_lease_pid_live() { # <ns>
  ns_lease_valid "$1" || return 1
  [ -n "$NS_LEASE_PID" ] || return 1
  ns_recorded_process "$NS_LEASE_PID" "$NS_LEASE_START"
}

ns_fence_print() { # <action> <duplicate> <fenced> <active> <takeover>
  local action="$1" duplicate="$2" fenced="$3" active="$4" takeover="$5"
  local json_true=true json_false=false
  printf '{\n'
  printf '  "action": "%s",\n' "$action"
  printf '  "duplicateWorkerRejected": %s,\n' "$([ "$duplicate" -eq 1 ] && printf '%s' "$json_true" || printf '%s' "$json_false")"
  printf '  "kind": "handoff-fence",\n'
  printf '  "priorOwnerFenced": %s,\n' "$([ "$fenced" -eq 1 ] && printf '%s' "$json_true" || printf '%s' "$json_false")"
  printf '  "priorWorkerActive": %s,\n' "$([ "$active" -eq 1 ] && printf '%s' "$json_true" || printf '%s' "$json_false")"
  printf '  "schemaVersion": 1,\n'
  printf '  "takeoverAllowed": %s,\n' "$([ "$takeover" -eq 1 ] && printf '%s' "$json_true" || printf '%s' "$json_false")"
  printf '  "twoActiveWorkersAllowed": false\n'
  printf '}\n'
}

# Worker fence from on-disk lease / session / pid. Model-authored flags are not consulted.
# Prints a handoff-fence object. 0 proceed · 1 refuse · 2 unavailable
ns_fence_check() { # <ns>
  local ns="$1"
  local prior_fenced=0 prior_active=0 duplicate=0 takeover=0 action=refuse
  local session_exists=0 session_pid="" session_start="" session_host="" session_sid=""
  local lease_rc sess_rc

  if [ -z "$ns" ] || [ ! -d "$ns" ] || [ -L "$ns" ]; then
    ns_fence_print refuse 0 0 0 0
    return 2
  fi

  if ! ns_lease_load "$ns"; then
    ns_fence_print refuse 0 0 0 0
    return 2
  fi

  if [ -e "$ns/.shift-session" ] || [ -L "$ns/.shift-session" ]; then
    if ! ns_session_present "$ns"; then
      ns_fence_print refuse 0 0 0 0
      return 2
    fi
    session_exists=1
    session_sid="$(ns_session_line "$ns" 1)"
    session_pid="$(ns_session_line "$ns" 3 | tr -d '[:space:]')"
    session_start="$(ns_session_line "$ns" 4)"
    session_host="$(ns_session_line "$ns" 5 | tr -d '[:space:]')"
    [ -n "$session_host" ] || session_host=claude
    case "$session_host" in
      claude | codex | cursor) ;;
      *)
        ns_fence_print refuse 0 0 0 0
        return 2
        ;;
    esac
    [ -n "$session_sid" ] || {
      ns_fence_print refuse 0 0 0 0
      return 2
    }
  fi

  if [ -z "$NS_LEASE_PID" ]; then
    prior_fenced=1
  else
    ns_recorded_process "$NS_LEASE_PID" "$NS_LEASE_START"
    lease_rc=$?
    case "$lease_rc" in
      0) prior_active=1 ;;
      1) prior_fenced=1 ;;
      *)
        ns_fence_print refuse 0 0 0 0
        return 2
        ;;
    esac
  fi

  if [ "$session_exists" -eq 1 ] && [ -n "$session_pid" ]; then
    ns_recorded_process "$session_pid" "$session_start"
    sess_rc=$?
    case "$sess_rc" in
      0)
        if [ -n "$NS_LEASE_PID" ] && [ "$session_pid" != "$NS_LEASE_PID" ]; then
          duplicate=1
        fi
        prior_active=1
        prior_fenced=0
        ;;
      1) ;;
      *)
        ns_fence_print refuse 0 0 0 0
        return 2
        ;;
    esac
  fi

  if [ "$prior_active" -eq 0 ] && [ "$duplicate" -eq 0 ] && [ "$prior_fenced" -eq 1 ]; then
    takeover=1
    action=proceed
    ns_fence_print "$action" "$duplicate" "$prior_fenced" "$prior_active" "$takeover"
    return 0
  fi
  ns_fence_print refuse "$duplicate" "$prior_fenced" "$prior_active" 0
  return 1
}
