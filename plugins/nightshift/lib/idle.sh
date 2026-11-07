#!/usr/bin/env bash
# One idle rule for every watchman. A live worker is left alone unless a whole
# idle window shows a stale pulse, an unchanged transcript, no meaningful CPU
# across its process tree, and no build, test, or browser child. The window is
# idleWindowMinutes (30 when missing). Recovery stops the tree, then revives
# through the same path as a dead worker. Two failed recoveries in a row leave
# one parking-lot notice and stop retrying until the worker is busy again or
# Start clears this file.

# Work a child is doing. The worker's own shell waiting on a read is not in
# this list: that is the stall this rule exists to end.
NS_IDLE_WORK_RE='^(make|gmake|ninja|cmake|xcodebuild|gradle|mvn|mvnw|tsc|webpack|esbuild|rollup|vite|cargo|go|docker|podman|npm|pnpm|yarn|bun|bats|pytest|py\.test|jest|vitest|mocha|phpunit|rspec|ctest|playwright|chrome|chromium|firefox|safari|msedge|google-chrome|chromium-browser)$'

# One second, in the centiseconds ps time is summed in. Under that, a process
# that is merely scheduled is not working.
NS_IDLE_CPU_MIN=100

ns_idle_window_minutes() { # <project>
  local v
  v="$(rule "$1" idleWindowMinutes "${NIGHTSHIFT_IDLE_WINDOW:-}")"
  case "$v" in
    '' | *[!0-9]* | 0) printf '30' ;;
    *) printf '%s' "$v" ;;
  esac
}

# ns_cpu_centiseconds <ps time field> — [[dd-]hh:]mm:ss[.cc] to centiseconds.
ns_cpu_centiseconds() {
  local t="$1" h=0 m=0 rest s frac
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  [ -n "$t" ] || return 1
  case "$t" in
    *[!0-9:.-]*) return 1 ;;
  esac
  case "$t" in
    *-*) t="${t#*-}" ;;
  esac
  case "$t" in
    *:*:*)
      h="${t%%:*}"
      t="${t#*:}"
      m="${t%%:*}"
      rest="${t#*:}"
      ;;
    *:*)
      m="${t%%:*}"
      rest="${t#*:}"
      ;;
    *) rest="$t" ;;
  esac
  case "$h$m" in *[!0-9]*) return 1 ;; esac
  s="${rest%%.*}"
  case "$s" in '' | *[!0-9]*) return 1 ;; esac
  frac=0
  case "$rest" in
    *.*)
      frac="${rest#*.}"
      frac="${frac%%[!0-9]*}"
      case "$frac" in
        '') frac=0 ;;
        [0-9]) frac=$((frac * 10)) ;;
        *) frac=$((10#${frac:0:2})) ;;
      esac
      ;;
  esac
  printf '%s' $((h * 360000 + m * 6000 + s * 100 + frac))
}

# Prints: cpu-centiseconds, known (0|1), busy (0|1), tab-separated.
# known=0 when ps cannot account for a root. Busy is a work-named process
# anywhere in the union of the trees, so a parent and its child are counted once.
ns_idle_tree_sample() { # <pid>...
  local snap roots="" pid
  [ "$#" -ge 1 ] || { printf '0\t0\t0'; return 0; }
  for pid in "$@"; do
    case "$pid" in '' | *[!0-9]*) printf '0\t0\t0'; return 0 ;; esac
    roots="$roots $pid"
  done
  snap="$(ps -ax -o pid= -o ppid= -o time= -o comm= 2>/dev/null)" || {
    printf '0\t0\t0'
    return 0
  }
  [ -n "$snap" ] || { printf '0\t0\t0'; return 0; }
  printf '%s\n' "$snap" | awk -v roots="$roots" -v work="$NS_IDLE_WORK_RE" '
    function centi(raw,   t, n, a, h, m, rest, s, frac) {
      t = raw
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
      sub(/^[0-9]+-/, "", t)
      if (t !~ /^[0-9][0-9:.]*$/) return -1
      n = split(t, a, ":")
      h = 0; m = 0
      if (n == 3) { h = a[1]; m = a[2]; rest = a[3] }
      else if (n == 2) { m = a[1]; rest = a[2] }
      else rest = a[1]
      s = rest; sub(/\..*/, "", s)
      frac = 0
      if (rest ~ /\./) {
        frac = rest; sub(/.*\./, "", frac); frac = substr(frac "00", 1, 2) + 0
      }
      return h * 360000 + m * 6000 + s * 100 + frac
    }
    {
      pid = $1 + 0; ppid = $2 + 0
      parent[pid] = ppid
      cpus[pid] = centi($3)
      base = $4
      sub(/.*\//, "", base)
      name[pid] = base
      seen[pid] = 1
    }
    END {
      nroots = split(roots, r, " ")
      cpu = 0; busy = 0; known = 1; qn = 0
      for (k = 1; k <= nroots; k++) {
        root = r[k] + 0
        if (root == 0) continue
        if (!seen[root]) { known = 0; continue }
        if (walk[root]) continue
        q[++qn] = root; walk[root] = 1
      }
      if (qn == 0) { print "0\t0\t0"; exit }
      for (i = 1; i <= qn; i++) {
        p = q[i]
        if (cpus[p] < 0) known = 0
        else cpu += cpus[p]
        if (name[p] ~ work) busy = 1
        for (c in parent) if (parent[c] == p && !walk[c]) {
          walk[c] = 1; q[++qn] = c
        }
      }
      print cpu "\t" known "\t" busy
    }
  '
}

# ns_idle_verdict <pulse stale|fresh> <bytes-changed 0|1> <cpu-known 0|1> <cpu-delta> <busy 0|1> <since> <now> <window-min> <stuck 0|1>
# Prints stuck, busy, unavailable, pending, or due.
ns_idle_verdict() {
  local pulse="$1" changed="$2" known="$3" delta="$4" busy="$5" since="$6" now="$7" window="$8" stuck="$9"
  [ "$stuck" = 1 ] && { printf 'stuck'; return 0; }
  [ "$pulse" = fresh ] && { printf 'busy'; return 0; }
  [ "$changed" = 1 ] && { printf 'busy'; return 0; }
  [ "$known" = 1 ] || { printf 'unavailable'; return 0; }
  [ "$busy" = 1 ] && { printf 'busy'; return 0; }
  case "$since" in '' | *[!0-9]*) printf 'pending'; return 0 ;; esac
  case "$delta" in
    -*) printf 'busy'; return 0 ;;
    '' | *[!0-9]*) printf 'unavailable'; return 0 ;;
  esac
  [ "$delta" -ge "$NS_IDLE_CPU_MIN" ] && { printf 'busy'; return 0; }
  case "$now" in '' | *[!0-9]*) printf 'unavailable'; return 0 ;; esac
  case "$window" in '' | *[!0-9]*) window=30 ;; esac
  if [ $((now - since)) -ge $((window * 60)) ]; then
    printf 'due'
  else
    printf 'pending'
  fi
}

ns_idle_cpu_label() { # <centiseconds>
  local c="$1" sign="+"
  case "$c" in
    -*) sign="-"; c="${c#-}" ;;
  esac
  case "$c" in '' | *[!0-9]*) c=0 ;; esac
  printf '%s%d.%02ds' "$sign" $((c / 100)) $((c % 100))
}

ns_idle_file() { # <ns>
  ns_layout_path "$1" idle-watch
}

ns_idle_load() { # <ns>
  local f line key val
  NS_IDLE_SINCE=""
  NS_IDLE_CPU=""
  NS_IDLE_BYTES=""
  NS_IDLE_PIDS=""
  NS_IDLE_FAILS=0
  NS_IDLE_EPISODE=0
  NS_IDLE_STUCK=0
  NS_IDLE_NOTICED=0
  NS_IDLE_EVIDENCE=""
  f="$(ns_idle_file "$1")" || return 0
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      since) NS_IDLE_SINCE="$val" ;;
      cpu) NS_IDLE_CPU="$val" ;;
      bytes) NS_IDLE_BYTES="$val" ;;
      pids) NS_IDLE_PIDS="$val" ;;
      fails) NS_IDLE_FAILS="$val" ;;
      episode) NS_IDLE_EPISODE="$val" ;;
      stuck) NS_IDLE_STUCK="$val" ;;
      noticed) NS_IDLE_NOTICED="$val" ;;
      evidence) NS_IDLE_EVIDENCE="$val" ;;
    esac
  done <"$f"
  case "$NS_IDLE_FAILS" in '' | *[!0-9]*) NS_IDLE_FAILS=0 ;; esac
  case "$NS_IDLE_EPISODE" in 1) ;; *) NS_IDLE_EPISODE=0 ;; esac
  case "$NS_IDLE_STUCK" in 1) ;; *) NS_IDLE_STUCK=0 ;; esac
  case "$NS_IDLE_NOTICED" in 1) ;; *) NS_IDLE_NOTICED=0 ;; esac
}

ns_idle_save() { # <ns>
  local f dir tmp
  f="$(ns_idle_file "$1")" || return 1
  dir="${f%/*}"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$(mktemp "$dir/.idle-watch.XXXXXX")" || return 1
  {
    printf 'since=%s\n' "$NS_IDLE_SINCE"
    printf 'cpu=%s\n' "$NS_IDLE_CPU"
    printf 'bytes=%s\n' "$NS_IDLE_BYTES"
    printf 'pids=%s\n' "$NS_IDLE_PIDS"
    printf 'fails=%s\n' "$NS_IDLE_FAILS"
    printf 'episode=%s\n' "$NS_IDLE_EPISODE"
    printf 'stuck=%s\n' "$NS_IDLE_STUCK"
    printf 'noticed=%s\n' "$NS_IDLE_NOTICED"
    printf 'evidence=%s\n' "$NS_IDLE_EVIDENCE"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f"
}

# A busy worker, or Start, ends an idle episode. Removing the file is the reset.
ns_idle_note_busy() { # <ns>
  local f
  f="$(ns_idle_file "$1" 2>/dev/null || true)"
  [ -n "$f" ] || return 0
  [ -L "$f" ] && return 0
  rm -f "$f"
  NS_IDLE_SINCE=""
  NS_IDLE_CPU=""
  NS_IDLE_BYTES=""
  NS_IDLE_PIDS=""
  NS_IDLE_FAILS=0
  NS_IDLE_EPISODE=0
  NS_IDLE_STUCK=0
  NS_IDLE_NOTICED=0
  NS_IDLE_EVIDENCE=""
}

ns_idle_revival_blocked() { # <ns> — 0 when retries have stopped
  ns_idle_load "$1"
  [ "$NS_IDLE_STUCK" = 1 ]
}

# 0 counted a failure, 2 just stuck (reason and notice written), 1 not in an episode.
ns_idle_after_revival() { # <ns> <revived|failed>
  ns_idle_load "$1"
  if [ "$2" = revived ]; then
    ns_idle_note_busy "$1"
    return 1
  fi
  [ "$NS_IDLE_EPISODE" = 1 ] || return 1
  [ "$NS_IDLE_STUCK" = 1 ] && return 2
  NS_IDLE_FAILS=$((NS_IDLE_FAILS + 1))
  if [ "$NS_IDLE_FAILS" -ge 2 ]; then
    NS_IDLE_STUCK=1
    NS_IDLE_NOTICED=1
    ns_idle_save "$1" || return 1
    ns_record_reason "$1" idle-stuck "two recoveries failed"
    ns_shift_log "$1" "watchman: idle recovery failed twice — one notice, no further retries"
    ns_watchman_park "$1" "an idle worker was stopped and revival failed twice. The watchman will not try again until that worker is busy again or the shift is started again."
    return 2
  fi
  ns_idle_save "$1"
  return 0
}

# 0 when this pid is the watchman or one of its parents. Killing it would take
# the watchman, and the test runner, down with the worker.
ns_idle_protected() { # <pid>
  local pid="$1" p="$$" _ pp
  case "$pid" in '' | *[!0-9]* | 0 | 1) return 0 ;; esac
  [ "$pid" = "$$" ] && return 0
  p="$$"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    [ "$p" = "$pid" ] && return 0
    case "$p" in '' | *[!0-9]* | 0 | 1) return 1 ;; esac
    pp="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d '[:space:]')" || return 1
    case "$pp" in '' | *[!0-9]*) return 1 ;; esac
    p="$pp"
  done
  return 1
}

ns_idle_collect() { # <pid> — prints the live tree, root first
  ps -ax -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    { pid = $1 + 0; ppid = $2 + 0; parent[pid] = ppid; seen[pid] = 1 }
    END {
      if (!seen[root]) exit
      q[1] = root; n = 1; walk[root] = 1
      for (i = 1; i <= n; i++) {
        print q[i]
        for (c in parent) if (parent[c] == q[i] && !walk[c]) { walk[c] = 1; q[++n] = c }
      }
    }
  '
}

# SIGTERM the tree, then SIGKILL after the grace. 0 when every pid is gone.
ns_idle_stop_tree() { # <pid>...
  local grace="${NIGHTSHIFT_IDLE_GRACE:-5}" pid p targets="" alive
  case "$grace" in '' | *[!0-9]*) grace=5 ;; esac
  for pid in "$@"; do
    ns_idle_protected "$pid" && return 1
    while IFS= read -r p; do
      case "$p" in '' | *[!0-9]*) continue ;; esac
      ns_idle_protected "$p" && return 1
      case " $targets " in
        *" $p "*) ;;
        *) targets="$targets $p" ;;
      esac
    done <<EOF
$(ns_idle_collect "$pid")
EOF
  done
  [ -n "${targets# }" ] || return 1
  # Children first, so a parent cannot restart one we have not signalled.
  # shellcheck disable=SC2086
  set -- $targets
  local i
  for ((i = $#; i >= 1; i--)); do
    kill -TERM "${!i}" 2>/dev/null || true
  done
  [ "$grace" -gt 0 ] && sleep "$grace"
  alive=0
  for p in "$@"; do
    if ns_pid_alive "$p"; then alive=1; fi
  done
  if [ "$alive" -eq 1 ]; then
    for ((i = $#; i >= 1; i--)); do
      kill -KILL "${!i}" 2>/dev/null || true
    done
  fi
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    alive=0
    for p in "$@"; do
      ns_pid_alive "$p" && alive=1
    done
    [ "$alive" -eq 0 ] && return 0
    sleep 0.1
  done
  return 1
}

# A host process in this project that is not part of the worker tree.
# 0 outside tree · 1 every match is inside, or none match.
ns_idle_host_outside_tree() { # <comm> <project> <pid>...
  local comm="$1" project="$2" p cwd root inside
  shift 2
  ns_have_cmd pgrep || return 1
  for p in $(pgrep -x "$comm" 2>/dev/null); do
    cwd="$(ns_proc_cwd "$p" 2>/dev/null || true)"
    [ "$cwd" = "$project" ] || continue
    inside=0
    for root in "$@"; do
      if ns_idle_collect "$root" | grep -qx "$p"; then
        inside=1
        break
      fi
    done
    [ "$inside" -eq 0 ] && return 0
  done
  return 1
}

# No recorded process: the host still calls the session quiet. Time and the
# transcript are the whole signal, and there is nothing to stop. Same returns
# as ns_idle_take, without 11.
ns_idle_mark_quiet() { # <ns> <project> <transcript> <stale|fresh>
  local ns="$1" project="$2" transcript="$3" pulse="$4"
  local bytes=0 changed=0 now window verdict mins
  ns_idle_load "$ns"
  [ "$NS_IDLE_STUCK" = 1 ] && return 13
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    bytes="$(wc -c <"$transcript" 2>/dev/null | tr -d '[:space:]')"
    case "$bytes" in '' | *[!0-9]*) bytes=0 ;; esac
  fi
  if [ -n "$NS_IDLE_SINCE" ] && [ "${NS_IDLE_BYTES:-0}" != "$bytes" ]; then
    changed=1
  fi
  now="$(date +%s)"
  window="$(ns_idle_window_minutes "$project")"
  verdict="$(ns_idle_verdict "$pulse" "$changed" 1 0 0 "$NS_IDLE_SINCE" "$now" "$window" 0)"
  case "$verdict" in
    busy)
      ns_idle_note_busy "$ns"
      return 0
      ;;
    pending | due)
      [ -n "$NS_IDLE_SINCE" ] || NS_IDLE_SINCE="$now"
      [ -n "$NS_IDLE_CPU" ] || NS_IDLE_CPU=0
      if [ -z "$NS_IDLE_BYTES" ]; then NS_IDLE_BYTES="$bytes"; fi
      NS_IDLE_EVIDENCE="pulse stale, transcript unchanged, no recorded process"
      ns_idle_save "$ns" || return 12
      [ "$verdict" = pending ] && return 0
      mins=$(((now - NS_IDLE_SINCE) / 60))
      [ "$mins" -lt 1 ] && mins=1
      ns_shift_log "$ns" "watchman: worker quiet for ${mins} min — ${NS_IDLE_EVIDENCE} — reviving"
      NS_IDLE_EPISODE=1
      ns_idle_save "$ns" || true
      return 10
      ;;
  esac
  return 12
}

# 0 stand by (pending or busy) · 10 tree stopped, revive as dead ·
# 11 could not stop · 12 evidence unavailable · 13 retries stopped.
ns_idle_take() { # <ns> <project> <transcript> <stale|fresh> <pid>...
  local ns="$1" project="$2" transcript="$3" pulse="$4"
  shift 4
  ns_idle_load "$ns"
  [ "$NS_IDLE_STUCK" = 1 ] && return 13
  local bytes=0 changed=0 now window sample cpu known busy delta verdict evidence mins
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    bytes="$(wc -c <"$transcript" 2>/dev/null | tr -d '[:space:]')"
    case "$bytes" in '' | *[!0-9]*) bytes=0 ;; esac
  fi
  if [ -n "$NS_IDLE_SINCE" ] && [ "${NS_IDLE_BYTES:-0}" != "$bytes" ]; then
    changed=1
  fi
  sample="$(ns_idle_tree_sample "$@")"
  cpu="${sample%%	*}"
  sample="${sample#*	}"
  known="${sample%%	*}"
  busy="${sample#*	}"
  delta=0
  if [ -n "$NS_IDLE_CPU" ] && [ "$known" = 1 ]; then
    delta=$((cpu - NS_IDLE_CPU))
  fi
  now="$(date +%s)"
  window="$(ns_idle_window_minutes "$project")"
  verdict="$(ns_idle_verdict "$pulse" "$changed" "$known" "$delta" "$busy" "$NS_IDLE_SINCE" "$now" "$window" "$NS_IDLE_STUCK")"
  case "$verdict" in
    busy)
      ns_idle_note_busy "$ns"
      return 0
      ;;
    unavailable) return 12 ;;
    stuck) return 13 ;;
    pending | due)
      [ -n "$NS_IDLE_SINCE" ] || NS_IDLE_SINCE="$now"
      [ -n "$NS_IDLE_CPU" ] || NS_IDLE_CPU="$cpu"
      [ -n "$NS_IDLE_SINCE" ] && [ -z "$NS_IDLE_BYTES" ] && NS_IDLE_BYTES="$bytes"
      # bytes may be 0; only fill them when the window is just opening.
      if [ "$NS_IDLE_BYTES" = "" ]; then NS_IDLE_BYTES="$bytes"; fi
      NS_IDLE_PIDS="$*"
      evidence="pulse stale, transcript unchanged, cpu $(ns_idle_cpu_label "$delta"), no busy child"
      NS_IDLE_EVIDENCE="$evidence"
      ns_idle_save "$ns" || return 12
      [ "$verdict" = pending ] && return 0
      mins=$(((now - NS_IDLE_SINCE) / 60))
      [ "$mins" -lt 1 ] && mins=1
      ns_shift_log "$ns" "watchman: worker alive but idle for ${mins} min — ${evidence} — stopping it and reviving"
      if ns_idle_stop_tree "$@"; then
        NS_IDLE_EPISODE=1
        ns_idle_save "$ns" || true
        return 10
      fi
      ns_shift_log "$ns" "watchman: idle worker could not be stopped — not reviving beside it"
      return 11
      ;;
  esac
  return 0
}

# The status and Doctor line, or empty when the worker is not idle.
ns_idle_status_sentence() { # <ns>
  local now mins p alive=0
  ns_idle_load "$1"
  [ "$NS_IDLE_STUCK" = 1 ] && return 0
  [ -n "$NS_IDLE_SINCE" ] || return 0
  [ -n "$NS_IDLE_EVIDENCE" ] || return 0
  for p in $NS_IDLE_PIDS; do
    case "$p" in '' | *[!0-9]*) continue ;; esac
    if ns_pid_alive "$p"; then alive=1; fi
  done
  [ "$alive" -eq 1 ] || return 0
  now="$(date +%s)"
  case "$NS_IDLE_SINCE" in '' | *[!0-9]*) return 0 ;; esac
  mins=$(((now - NS_IDLE_SINCE) / 60))
  [ "$mins" -lt 0 ] && return 0
  printf 'worker alive but idle for %s min — %s' "$mins" "$NS_IDLE_EVIDENCE"
}
