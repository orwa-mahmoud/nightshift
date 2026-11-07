# shellcheck shell=bash
# A long-lived watchman loads its libraries once. When the host replaces that install, later
# reads of those paths fail and a revival is refused for the rest of the night. Each wake
# re-runs from the copy the hooks are on, or from the install the host itself records.

# ns_plugin_install_usable <root> <host> — the directory can still run this host's watchman.
ns_plugin_install_usable() {
  local root="$1" host="$2" script
  [ -d "$root" ] || return 1
  case "$host" in
    windows) script="$root/runtime/windows/watchman.ps1" ;;
    claude | codex | cursor) script="$root/runtime/$host/watchman.sh" ;;
    *) return 1 ;;
  esac
  [ -f "$script" ] || return 1
  [ -f "$root/lib/lib.sh" ] || return 1
  [ -f "$root/lib/policy-emit.jq" ] || return 1
  [ -f "$root/lib/rules-read.awk" ] || return 1
}

# Canonical directory when it exists; the path unchanged when it does not.
ns_watchman_canon_dir() {
  if [ -d "$1" ]; then
    (cd -P "$1" 2>/dev/null && pwd) && return 0
  fi
  printf '%s' "$1"
}

# Plugin root of a runtime/<host>/watchman.sh path.
ns_plugin_root_from_script() {
  local d="${1%/*}"
  d="${d%/*}"
  d="${d%/*}"
  ns_watchman_canon_dir "$d"
}

# Newest hook-copies row for this host: root<TAB>version. Empty when none.
ns_hook_copy_newest() {
  local f
  ns_layout_set f "$1" hook-copies || return 0
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  awk -F '\t' -v h="$2" '
    $2 == h && ($1 + 0) >= best { best = $1 + 0; root = $4; ver = $5 }
    END { if (root != "") printf "%s\t%s\n", root, ver }
  ' "$f"
}

# installPath values for nightshift@* in Claude Code's installed_plugins.json, in file order.
ns_claude_plugin_installs() {
  [ -f "$1" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r '
      (.plugins // {}) | to_entries[]
      | select(.key | test("^nightshift@"))
      | .value[]? | .installPath // empty
    ' "$1" 2>/dev/null
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
plugins = doc.get("plugins") if isinstance(doc, dict) else None
if not isinstance(plugins, dict):
    sys.exit(0)
for key, value in plugins.items():
    if not str(key).startswith("nightshift@"):
        continue
    rows = value if isinstance(value, list) else [value]
    for row in rows:
        if isinstance(row, dict) and row.get("installPath"):
            print(row["installPath"])
' "$1" 2>/dev/null
  fi
}

# Marketplace names of enabled nightshift plugins in a Codex config.toml.
ns_codex_enabled_markets() {
  [ -f "$1" ] || return 0
  awk '
    /^\[plugins\."nightshift@/ {
      if (market != "") { if (enabled) print market }
      market = $0
      sub(/^\[plugins\."nightshift@/, "", market)
      sub(/"\].*$/, "", market)
      enabled = 1
      next
    }
    /^\[/ {
      if (market != "") { if (enabled) print market }
      market = ""
      next
    }
    market != "" && $0 ~ /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*false[[:space:]]*$/ { enabled = 0 }
    END { if (market != "" && enabled) print market }
  ' "$1"
}

# Newest usable child directory of a versioned cache folder.
ns_newest_usable_child() {
  local parent="$1" host="$2" d m best="" best_m=0
  [ -d "$parent" ] || return 0
  for d in "$parent"/*; do
    [ -d "$d" ] || continue
    ns_plugin_install_usable "$d" "$host" || continue
    m="$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null || printf '0')"
    case "$m" in
      '' | *[!0-9]*) m=0 ;;
    esac
    if [ "$m" -ge "$best_m" ]; then
      best_m="$m"
      best="$d"
    fi
  done
  [ -n "$best" ] || return 0
  ns_watchman_canon_dir "$best"
}

# Newest usable Nightshift root under a Cursor plugins tree, identified by its manifest name.
ns_cursor_scan_installs() {
  local base="$1" host="$2" manifest root name m best="" best_m=0
  [ -d "$base" ] || return 0
  while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    root="${manifest%/*}"
    root="${root%/*}"
    name="$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)"
    [ "$name" = nightshift ] || continue
    ns_plugin_install_usable "$root" "$host" || continue
    m="$(stat -f %m "$root" 2>/dev/null || stat -c %Y "$root" 2>/dev/null || printf '0')"
    case "$m" in
      '' | *[!0-9]*) m=0 ;;
    esac
    if [ "$m" -ge "$best_m" ]; then
      best_m="$m"
      best="$root"
    fi
  done <<EOF
$(find "$base" -name plugin.json \( -path '*/.claude-plugin/plugin.json' -o -path '*/.cursor-plugin/plugin.json' -o -path '*/.codex-plugin/plugin.json' \) 2>/dev/null)
EOF
  [ -n "$best" ] || return 0
  ns_watchman_canon_dir "$best"
}

# The install this host records for Nightshift, or empty. Claude reads installed_plugins.json
# (https://code.claude.com/docs/en/plugins/loading). Codex reads enabled plugins in config.toml
# and the version directory under plugins/cache. Cursor's cache and local plugin folders are the
# record the client writes; a marketplace install wins over a local one.
ns_host_current_install() {
  local host="$1" home="${HOME:-}" root last="" p market dir found=""
  [ -n "$home" ] || return 0
  case "$host" in
    claude)
      root="${CLAUDE_CODE_PLUGIN_CACHE_DIR:-$home/.claude/plugins}"
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        ns_plugin_install_usable "$p" claude || continue
        last="$p"
      done <<EOF
$(ns_claude_plugin_installs "$root/installed_plugins.json")
EOF
      [ -n "$last" ] || return 0
      ns_watchman_canon_dir "$last"
      ;;
    codex)
      root="${CODEX_HOME:-$home/.codex}"
      while IFS= read -r market; do
        [ -n "$market" ] || continue
        dir="$(ns_newest_usable_child "$root/plugins/cache/$market/nightshift" codex)"
        [ -n "$dir" ] && last="$dir"
      done <<EOF
$(ns_codex_enabled_markets "$root/config.toml")
EOF
      [ -n "$last" ] && printf '%s' "$last"
      ;;
    cursor)
      found="$(ns_cursor_scan_installs "$home/.cursor/plugins/cache" cursor)"
      if [ -n "$found" ]; then
        printf '%s' "$found"
        return 0
      fi
      ns_cursor_scan_installs "$home/.cursor/plugins/local" cursor
      ;;
  esac
}

ns_watchman_write_pidfile() { # pidfile script
  local root ver start=""
  root="$(ns_plugin_root_from_script "$2")"
  ver="$(ns_plugin_version "$root")"
  start="$(ns_process_start $$ 2>/dev/null || true)"
  if [ -n "$start" ]; then
    printf '%s\nstart:%s\nscript:%s\nversion:%s\n' "$$" "$start" "$2" "$ver" >"$1"
  else
    printf '%s\nscript:%s\nversion:%s\n' "$$" "$2" "$ver" >"$1"
  fi
}

# ns_watchman_pidfile_read <file> — pid, start, script, version, tab-separated.
# Line 1 is the pid. Named fields are start:, script:, and version:. A second line
# with no field name is the older start-time record.
ns_watchman_pidfile_read() {
  local line pid="" start="" script="" version="" n=0
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
      start:*) start="${line#start:}" ;;
      script:*) script="${line#script:}" ;;
      version:*) version="${line#version:}" ;;
      *)
        if [ "$n" -eq 1 ]; then
          pid="$(printf '%s' "$line" | tr -d '[:space:]')"
        elif [ -z "$start" ] && [ -z "$script" ]; then
          start="$line"
        fi
        ;;
    esac
  done <"$1"
  printf '%s\t%s\t%s\t%s' "$pid" "$start" "$script" "$version"
}

# 0 when an argument is the watchman script. A longer name that only contains those
# letters is not it.
ns_watchman_command_is_script() {
  local cmd="$1" tok base noglob=0
  case "$-" in *f*) noglob=1 ;; esac
  set -f
  # shellcheck disable=SC2086
  for tok in $cmd; do
    tok="${tok#\"}"
    tok="${tok%\"}"
    tok="${tok#\'}"
    tok="${tok%\'}"
    base="${tok##*/}"
    case "$base" in
      watchman.sh | watchman.ps1)
        [ "$noglob" -eq 0 ] && set +f
        return 0
        ;;
    esac
  done
  [ "$noglob" -eq 0 ] && set +f
  return 1
}

# The workspace is one whole argument. A longer path that only begins with it does not match.
ns_watchman_command_has_project() {
  local cmd="$1" ws="$2" needle prefix rest
  [ -n "$ws" ] || return 1
  for needle in \
    "--project $ws" "--project=$ws" "-Project $ws" "-Project=$ws" \
    "--project \"$ws\"" "--project '$ws'" "-Project \"$ws\"" "-Project '$ws'"; do
    prefix="$cmd"
    while :; do
      case "$prefix" in
        *"$needle"*) ;;
        *) break ;;
      esac
      rest="${prefix#*"$needle"}"
      [ "$rest" != "$prefix" ] || break
      prefix="$rest"
      case "${prefix:0:1}" in
        '' | ' ' | '"' | "'" | "$(printf '\t')") return 0 ;;
      esac
    done
  done
  return 1
}

# ns_watchman_live_for_project <workspace>
# Prints the pid of a live watchman whose command names this workspace. Status 1 when
# none is visible (no ps, or no such process).
ns_watchman_live_for_project() {
  local ws="$1" line pid cmd
  [ -n "$ws" ] || return 1
  ns_have_cmd ps || return 1
  if [ -d "$ws" ]; then
    ws="$(cd -P "$ws" 2>/dev/null && pwd)" || return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%%[[:space:]]*}"
    cmd="${line#"$pid"}"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    case "$pid" in '' | *[!0-9]*) continue ;; esac
    [ "$pid" -gt 1 ] || continue
    [ "$pid" = "$$" ] && continue
    ns_watchman_command_is_script "$cmd" || continue
    ns_watchman_command_has_project "$cmd" "$ws" || continue
    kill -0 "$pid" 2>/dev/null || continue
    printf '%s\n' "$pid"
    return 0
  done <<EOF
$(ps -axww -o pid= -o command= 2>/dev/null || true)
EOF
  return 1
}

# Claim the pidfile. Status 1 when another live watchman already holds it.
ns_watchman_claim() { # pidfile script
  local pidfile="$1" oldpid=""
  if [ -L "$pidfile" ]; then
    rm -f "$pidfile"
  elif [ -f "$pidfile" ]; then
    oldpid="$(sed -n '1p' "$pidfile" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$oldpid" ] && [ "$oldpid" != "$$" ] && kill -0 "$oldpid" 2>/dev/null; then
      printf 'watchman: already watching (pid %s)\n' "$oldpid" >&2
      return 1
    fi
  fi
  ns_watchman_write_pidfile "$pidfile" "$2"
}

# Sets NS_WATCH_ACTION (stay|reexec|pending|stand-down), NS_WATCH_TARGET, NS_WATCH_MESSAGE,
# NS_WATCH_REASON. A copy is its directory: the hooks' row wins when that directory differs
# and can still run. A missing directory re-runs from the host's recorded install.
ns_watchman_install_plan() {
  local ns="$1" host="$2" script="$3"
  local self self_ver hooks_line hooks_root="" hooks_ver="" hooks_usable=0 self_usable=0
  local reg="" reg_ver="" prev="" detail="" reason_file=""
  NS_WATCH_ACTION=stay
  NS_WATCH_TARGET=""
  NS_WATCH_MESSAGE=""
  NS_WATCH_REASON=""
  self="$(ns_plugin_root_from_script "$script")"
  self_ver="$(ns_plugin_version "$self")"
  if [ "$self_ver" = unknown ] && [ -n "${NS_WATCHMAN_SELF_VERSION:-}" ]; then
    self_ver="$NS_WATCHMAN_SELF_VERSION"
  fi
  ns_plugin_install_usable "$self" "$host" && self_usable=1
  hooks_line="$(ns_hook_copy_newest "$ns" "$host")"
  if [ -n "$hooks_line" ]; then
    hooks_root="${hooks_line%%$'\t'*}"
    hooks_ver="${hooks_line#*$'\t'}"
    if ns_plugin_install_usable "$hooks_root" "$host"; then
      hooks_usable=1
      hooks_root="$(ns_watchman_canon_dir "$hooks_root")"
    fi
  fi
  reg="$(ns_host_current_install "$host")"
  if [ "$hooks_usable" -eq 1 ] && [ "$hooks_root" != "$self" ]; then
    NS_WATCH_ACTION=reexec
    NS_WATCH_TARGET="$hooks_root/runtime/$host/watchman.sh"
    NS_WATCH_MESSAGE="watchman: install ${self_ver} at ${self} is not the hooks' copy ${hooks_ver} at ${hooks_root}; re-running from the hooks' copy"
    return 0
  fi
  if [ "$self_usable" -eq 1 ]; then
    NS_WATCH_ACTION=stay
    return 0
  fi
  if [ -n "$reg" ]; then
    reg="$(ns_watchman_canon_dir "$reg")"
  fi
  if [ -n "$reg" ] && [ "$reg" != "$self" ] && ns_plugin_install_usable "$reg" "$host"; then
    reg_ver="$(ns_plugin_version "$reg")"
    NS_WATCH_ACTION=reexec
    NS_WATCH_TARGET="$reg/runtime/$host/watchman.sh"
    NS_WATCH_MESSAGE="watchman: install ${self_ver} at ${self} is gone; re-running ${reg_ver} at ${reg}"
    return 0
  fi
  if [ -n "$hooks_root" ] && [ "$hooks_usable" -eq 0 ]; then
    NS_WATCH_REASON=hooks-unusable
    NS_WATCH_MESSAGE="watchman: the hooks' copy of the plugin at ${hooks_root} cannot be used"
  else
    NS_WATCH_REASON=no-install
    NS_WATCH_MESSAGE="watchman: no current install of the plugin"
  fi
  prev="$(ns_reason_code "$ns" 2>/dev/null || true)"
  reason_file="$(ns_layout_path "$ns" watch-reason 2>/dev/null || true)"
  detail=""
  if [ -n "$reason_file" ] && [ -f "$reason_file" ]; then
    detail="$(sed -n '2p' "$reason_file" 2>/dev/null || true)"
  fi
  if [ "$prev" = install-pending ] && [ "$detail" = "$NS_WATCH_REASON" ]; then
    NS_WATCH_ACTION=stand-down
  else
    NS_WATCH_ACTION=pending
  fi
}

ns_watchman_park() { # ns message
  local lot
  ns_layout_set lot "$1" parking-lot || return 0
  mkdir -p "${lot%/*}" 2>/dev/null || return 0
  printf -- '- [notice] %s — %s\n' "$(ns_local_now second)" "$2" >>"$lot"
}

ns_watchman_start_command() { # host project [plugin-root]
  local bin="ns"
  if [ -n "${3:-}" ] && [ -f "$3/runtime/ns" ]; then
    bin="$3/runtime/ns"
  fi
  printf '%s start-watchman --host %s --project %s' "$bin" "$1" "$2"
}

# Re-exec, or return 1 so this wake does not revive, or exit on a confirmed stand-down.
# Uses the watchman's NS, PROJECT, INTERVAL_MIN, MAX_WAKES, AGENT, NS_WATCHMAN_SCRIPT.
ns_watchman_settle() {
  local host="$1" ws cmd code
  ns_watchman_install_plan "$NS" "$host" "$NS_WATCHMAN_SCRIPT"
  case "$NS_WATCH_ACTION" in
    stay) return 0 ;;
    reexec)
      ns_shift_log "$NS" "$NS_WATCH_MESSAGE"
      if [ -n "${AGENT:-}" ]; then
        NIGHTSHIFT_WATCH_IMMEDIATE=1 exec "$NS_WATCH_TARGET" --project "$PROJECT" --interval "$INTERVAL_MIN" --max-wakes "$MAX_WAKES" --agent "$AGENT"
      else
        NIGHTSHIFT_WATCH_IMMEDIATE=1 exec "$NS_WATCH_TARGET" --project "$PROJECT" --interval "$INTERVAL_MIN" --max-wakes "$MAX_WAKES"
      fi
      ns_shift_log "$NS" "watchman: could not re-run ${NS_WATCH_TARGET}"
      return 0
      ;;
    pending)
      ns_record_reason "$NS" install-pending "$NS_WATCH_REASON"
      ns_shift_log "$NS" "${NS_WATCH_MESSAGE} — checking once more on the next wake"
      return 1
      ;;
    stand-down)
      ws="${NS%/.nightshift}"
      cmd="$(ns_watchman_start_command "$host" "$ws")"
      case "$NS_WATCH_REASON" in
        hooks-unusable) code=install-mismatch ;;
        *) code=install-removed ;;
      esac
      ns_record_reason "$NS" "$code" "$NS_WATCH_REASON"
      ns_shift_log "$NS" "${NS_WATCH_MESSAGE} — standing down. Run ${cmd}"
      ns_watchman_park "$NS" "${NS_WATCH_MESSAGE}. Run ${cmd}"
      exit 0
      ;;
  esac
  return 0
}

ns_watchman_script_line() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  sed -n 's/^script://p' "$1" | head -n 1
}

ns_watchman_version_line() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  sed -n 's/^version://p' "$1" | head -n 1
}

# The warning sentence when a live watchman's script is gone. Status 1 when it is not.
ns_watchman_removed_sentence() { # ns pidfile pid
  local ns="$1" file="$2" pid="$3" script="" ver="" host="" current="" curver="" ws="" cmd=""
  script="$(ns_watchman_script_line "$file")"
  if [ -z "$script" ] && [ -n "$pid" ]; then
    script="$(ps -o args= -p "$pid" 2>/dev/null | sed -n 's/.*[[:space:]]\(\/[^[:space:]]*watchman\.sh\).*/\1/p' | head -n 1)"
  fi
  [ -n "$script" ] || return 1
  [ ! -e "$script" ] || return 1
  ver="$(ns_watchman_version_line "$file")"
  [ -n "$ver" ] || ver="unknown"
  host="$(ns_session_host "$ns")"
  case "$host" in
    claude | codex | cursor) ;;
    *) host="claude" ;;
  esac
  current="$(ns_host_current_install "$host")"
  ws="${ns%/.nightshift}"
  if [ -n "$current" ]; then
    curver="$(ns_plugin_version "$current")"
    cmd="$(ns_watchman_start_command "$host" "$ws" "$current")"
    printf 'watchman running from a removed install (version %s); current install is %s (%s). Replace it: kill %s; %s' \
      "$ver" "$curver" "$current" "$pid" "$cmd"
  else
    cmd="$(ns_watchman_start_command "$host" "$ws")"
    printf 'watchman running from a removed install (version %s); current install is none. Replace it: kill %s; %s' \
      "$ver" "$pid" "$cmd"
  fi
}
