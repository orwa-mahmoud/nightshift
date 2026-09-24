#!/usr/bin/env bash
# Workspace resolution and canonical path helpers shared by Nightshift hooks.

# ns_msys_path <path>
# Git Bash cannot cd to D:/foo; it wants /d/foo. Do not call cygpath -u here:
# it remaps Windows Temp to /tmp, which is a different directory, so helpers
# refuse a project PowerShell just created.
ns_msys_path() {
  local p d
  p="${1//\\//}"
  case "$p" in
    [A-Za-z]:/*)
      d=$(printf '%s' "${p%"${p#?}"}" | tr '[:upper:]' '[:lower:]')
      printf '%s' "/${d}${p#?:}"
      ;;
    *)
      printf '%s' "$p"
      ;;
  esac
}

# ns_native_display_path <path>
# Receipts print the native Windows form so the bash and PowerShell renderers
# stay byte-identical when Git Bash is the twin. POSIX paths are unchanged.
ns_native_display_path() {
  local p d rest converted
  p="$1"
  [ -n "$p" ] || return 0
  if command -v cygpath >/dev/null 2>&1; then
    converted="$(cygpath -w -- "$p" 2>/dev/null)" || converted=""
    if [ -n "$converted" ]; then
      printf '%s' "$converted"
      return 0
    fi
  fi
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) ;;
    *)
      printf '%s' "$p"
      return 0
      ;;
  esac
  p="${p//\\//}"
  case "$p" in
    /[A-Za-z]/*)
      d="${p#/}"
      d="${d%"${d#?}"}"
      d=$(printf '%s' "$d" | tr '[:lower:]' '[:upper:]')
      rest="${p#/?}"
      printf '%s' "${d}:${rest//\//\\}"
      ;;
    [A-Za-z]:/*)
      d=$(printf '%s' "${p%"${p#?}"}" | tr '[:lower:]' '[:upper:]')
      rest="${p#?:}"
      printf '%s' "${d}:${rest//\//\\}"
      ;;
    *)
      printf '%s' "${p//\//\\}"
      ;;
  esac
}

# ns_workspace_root <host-root>
#
# Resolve the one workspace that owns Nightshift state. Normally that is the task root itself.
# A task opened elsewhere may opt in explicitly with a local .nightshift-link containing one
# absolute path to a directory that already owns .nightshift/. We never search parent or sibling
# directories: an absent link means local state; a malformed link returns 2 so callers can fail
# closed instead of silently running without the owner's contract.
ns_workspace_root() {
  local host link target="" lines="" canonical=""
  host="$(ns_msys_path "$1")"
  link="$host/.nightshift-link"
  canonical="$(cd -P "$host" 2>/dev/null && pwd)" || {
    return 2
  }
  if [ ! -e "$link" ] && [ ! -L "$link" ]; then
    printf '%s' "$canonical"
    return 0
  fi
  if [ ! -f "$link" ] || [ -L "$link" ]; then
    return 2
  fi
  IFS= read -r target <"$link" || true
  lines="$(awk 'END { print NR + 0 }' "$link" 2>/dev/null)"
  if [ -z "$target" ] || [ "$lines" -ne 1 ]; then
    return 2
  fi
  case "$target" in /*) ;; *)
    return 2
  esac
  canonical="$(cd -P "$target" 2>/dev/null && pwd)" || {
    return 2
  }
  [ -d "$canonical/.nightshift" ] || {
    return 2
  }
  printf '%s' "$canonical"
}

# ns_hook_host_dir — project dir from the host environment, never from stdin.
ns_hook_host_dir() {
  printf '%s' "${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}}"
}

# ns_hook_idle_exit — after the library is loaded, leave if the resolved site
# has no armed shift. A broken .nightshift-link is not idle: the caller fail-
# closes. Revival workers stay in.
ns_hook_idle_exit() {
  [ "${NIGHTSHIFT_REVIVAL:-}" != "1" ] || return 0
  local host project ns armed ended
  host="$(ns_hook_host_dir)"
  project="$(ns_workspace_root "$host" 2>/dev/null)" || return 0
  ns="$project/.nightshift"
  ns_layout_set armed "$ns" armed
  [ -f "$armed" ] || exit 0
  ns_layout_set ended "$ns" ended
  if [ -f "$ended" ] && [ ! -L "$ended" ]; then
    exit 0
  fi
}

# ns_record_workspace_link <host-root> <workspace>
# Validate and atomically record a cross-workspace link. The pointer is machine-local, so when
# the host is a Git repository it goes in .git/info/exclude rather than changing tracked files.
ns_record_workspace_link() {
  local host target canonical tmp exclude git_dir
  host="$(cd -P "$1" 2>/dev/null && pwd)" || return 1
  target="$2"
  case "$target" in /*) ;; *) return 1 ;; esac
  canonical="$(cd -P "$target" 2>/dev/null && pwd)" || return 1
  [ -d "$canonical/.nightshift" ] || return 1
  if ns_is_scratch_path "$host" || ns_is_scratch_path "$canonical"; then
    return 1
  fi
  tmp="$host/.nightshift-link.$$"
  printf '%s\n' "$canonical" >"$tmp" || return 1
  mv "$tmp" "$host/.nightshift-link" || return 1
  if git_dir="$(git -C "$host" rev-parse --git-dir 2>/dev/null)"; then
    case "$git_dir" in /*) ;; *) git_dir="$host/$git_dir" ;; esac
    exclude="$git_dir/info/exclude"
    mkdir -p "${exclude%/*}" || return 1
    grep -qxF '.nightshift-link' "$exclude" 2>/dev/null || printf '%s\n' '.nightshift-link' >>"$exclude"
  fi
}

# Point the work-target at this workspace so a revival started there finds .nightshift/.
# No-op when the target is the workspace itself or already linked here.
ns_ensure_work_target_link() { # <workspace>
  local ws target existing
  ws="$(cd -P "$1" 2>/dev/null && pwd)" || return 1
  target="$(ns_work_target "$ws" 2>/dev/null)" || return 0
  [ -n "$target" ] || return 0
  [ "$target" = "$ws" ] && return 0
  [ -d "$target" ] || return 1
  if existing="$(ns_workspace_root "$target" 2>/dev/null)" && [ "$existing" = "$ws" ]; then
    return 0
  fi
  ns_record_workspace_link "$target" "$ws"
}

# ns_path_under_protected <path> <protectedDirs>
ns_path_under_protected() {
  local path="${1#./}" d
  path="${path#./}"
  IFS=' |' read -ra _ns_pd_dirs <<<"$2"
  for d in "${_ns_pd_dirs[@]}"; do
    [ -n "$d" ] || continue
    d="${d#./}"
    case "$path" in
      "$d" | "$d"/* | */"$d" | */"$d"/*) return 0 ;;
    esac
  done
  return 1
}

# ns_under_nightshift <workspace> <relative-path>
# Print the canonical path when it resolves to a valid child of .nightshift/.
# Rejects symlinks, traversal, and anything that escapes the root.
ns_under_nightshift() {
  local ws="$1" rel="$2" ns root parent base canon
  case "$rel" in
    '' | /* | *..*) return 1 ;;
  esac
  ns="$ws/.nightshift"
  root="$(cd -P "$ns" 2>/dev/null && pwd)" || return 1
  [ ! -L "$ns/$rel" ] || return 1
  if [ -d "$ns/$rel" ]; then
    canon="$(cd -P "$ns/$rel" 2>/dev/null && pwd)" || return 1
  elif [ -f "$ns/$rel" ]; then
    base="${rel##*/}"
    if [ "$rel" = "$base" ]; then
      parent="$root"
    else
      parent="$(cd -P "$ns/${rel%/*}" 2>/dev/null && pwd)" || return 1
    fi
    [ -f "$parent/$base" ] || return 1
    [ ! -L "$parent/$base" ] || return 1
    canon="$parent/$base"
  else
    return 1
  fi
  case "$canon" in
    "$root"/*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$canon"
}

# Qualify bare .nightshift/ mentions in owner-authored injection text (clock-out,
# revival, toolDeny) so a drifted cwd cannot send the agent to a nested copy, and name each
# state file where this workspace's layout keeps it: text written for one layout still sends the
# agent to the right file in another. Expansion happens at injection time; the owner's rules file
# keeps the relative form so it stays editable without a skill variable.
ns_expand_injected_paths() {
  local ws="$1" text="$2" version
  [ -n "$ws" ] || { printf '%s' "$text"; return 0; }
  text="${text//\$NIGHTSHIFT_WORKSPACE/$ws}"
  text="${text//\$NS/$ws/.nightshift}"
  ns_layout_version_set version "$ws/.nightshift"
  printf '%s' "$text" | NS_LAYOUT_ROWS="$NS_LAYOUT_ROWS" awk -v ws="$ws" -v version="$version" '
    BEGIN {
      ORS = ""
      n = split(ENVIRON["NS_LAYOUT_ROWS"], rows, "\n")
      for (k = 1; k <= n; k++) {
        if (split(rows[k], f, "\t") < 4 || f[4] == "field" || f[4] == "retired" || f[4] == "stray" || index(f[3], "*")) continue
        key[k] = f[1]
        path[k] = f[3]
        if (f[2] + 0 <= version && (!(f[1] in best) || f[2] + 0 >= bestv[f[1]])) {
          best[f[1]] = f[3]
          bestv[f[1]] = f[2] + 0
        }
      }
      m = 0
      for (k = 1; k <= n; k++) {
        if (!(k in key) || !(key[k] in best) || path[k] == best[key[k]]) continue
        from[++m] = path[k]
        to[m] = best[key[k]]
      }
      # The longest name first, so a file is never read as the folder it sits in.
      for (a = 2; a <= m; a++) {
        for (b = a; b > 1 && length(from[b]) > length(from[b - 1]); b--) {
          t = from[b]; from[b] = from[b - 1]; from[b - 1] = t
          t = to[b]; to[b] = to[b - 1]; to[b - 1] = t
        }
      }
    }
    {
      s = $0
      while (match(s, /\.nightshift[\/\\]/)) {
        prefix = substr(s, 1, RSTART - 1)
        chunk = substr(s, RSTART, RLENGTH)
        sep = substr(chunk, length(chunk), 1)
        last = (length(prefix) ? substr(prefix, length(prefix), 1) : "")
        if (last == "/" || last == "\\") {
          printf "%s%s", prefix, chunk
        } else {
          printf "%s%s/.nightshift%s", prefix, ws, sep
        }
        s = substr(s, RSTART + RLENGTH)
        for (j = 1; j <= m; j++) {
          if (substr(s, 1, length(from[j])) == from[j] && substr(s, length(from[j]) + 1, 1) !~ /[A-Za-z0-9._-]/) {
            printf "%s", to[j]
            s = substr(s, length(from[j]) + 1)
            break
          }
        }
      }
      printf "%s", s
    }
  '
}

# ns_is_scratch_path <absolute-path>
# ChatGPT disposable workspaces live under /workspace/scratch/. Local non-git folders are not
# scratch merely because they lack Git.
ns_is_scratch_path() {
  local p="${1%/}"
  p="${p//\\//}"
  case "$p" in
    /workspace/scratch | /workspace/scratch/*) return 0 ;;
  esac
  return 1
}

# ns_work_mode <workspace>
# Print repository or artifact. A missing record is repository — the historical default.
# Return 1 when the record exists and is not one of those two words.
ns_work_mode() {
  local record mode=""
  ns_layout_set record "$1/.nightshift" work-mode
  if [ -L "$record" ]; then
    return 1
  fi
  if [ ! -s "$record" ]; then
    printf 'repository'
    return 0
  fi
  IFS= read -r mode <"$record" || true
  mode="${mode%$'\r'}"
  case "$mode" in
    repository | artifact)
      printf '%s' "$mode"
      return 0
      ;;
  esac
  return 1
}

# ns_record_work_mode <workspace> <repository|artifact>
ns_record_work_mode() {
  local project="$1" mode="$2" record tmp
  case "$mode" in repository | artifact) ;; *) return 1 ;; esac
  ns_state_dir_ensure "$project" || return 1
  ns_layout_parent "$project/.nightshift" work-mode || return 1
  ns_layout_set record "$project/.nightshift" work-mode
  tmp="${record%/*}/.work-mode.$$"
  printf '%s\n' "$mode" >"$tmp" || return 1
  mv "$tmp" "$record"
}

# ns_propose_work_mode <workspace>
# Detect the mode Setup should offer. Does not persist. 0 prints repository or artifact;
# 2 is a disposable scratch path; 1 is undecidable.
ns_propose_work_mode() {
  local project="$1" child base top found=""
  if ns_is_scratch_path "$project"; then
    return 2
  fi
  project="$(cd -P "$project" 2>/dev/null && pwd)" || return 1
  if ns_is_scratch_path "$project"; then
    return 2
  fi
  if git -C "$project" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf 'repository'
    return 0
  fi
  for child in "$project"/*/; do
    base="${child%/}"; base="${base##*/}"
    case "$base" in .*) continue ;; esac
    [ -L "${child%/}" ] && continue
    top="$(git -C "$child" rev-parse --show-toplevel 2>/dev/null)" || continue
    if [ -n "$found" ] && [ "$found" != "$top" ]; then
      printf 'repository'
      return 0
    fi
    found="$top"
  done
  if [ -n "$found" ]; then
    printf 'repository'
    return 0
  fi
  printf 'artifact'
  return 0
}

# ns_normalize_path <path> — the path with its `.` and `..` segments resolved as text, the way a
# relative link is read. A `..` above the start is kept.
ns_normalize_path() {
  local in="$1" out="" seg rest lead=""
  case "$in" in /*) lead=/ ;; esac
  rest="$in"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
    case "$seg" in
      '' | .) ;;
      ..)
        case "$out" in
          '' | .. | */..) out="${out:+$out/}.." ;;
          */*) out="${out%/*}" ;;
          *) out="" ;;
        esac
        ;;
      *) out="${out:+$out/}$seg" ;;
    esac
  done
  printf '%s%s' "$lead" "$out"
}

# ns_relative_path <from-dir> <to-path> — <to-path> relative to <from-dir>. Both are absolute and
# spelled alike up to where they part, as two paths built from one state directory are.
ns_relative_path() {
  local common="${1%/}" to="$2" up=""
  while [ -n "$common" ]; do
    case "$to" in "$common"/*) break ;; esac
    common="${common%/*}"
    up="../$up"
  done
  printf '%s%s' "$up" "${to#"$common"/}"
}

# ns_state_dir_ensure <workspace> — create <workspace>/.nightshift/ when it does not exist yet. A
# state directory is born in the current layout, so a new one gets its state-version before any
# file lands in it; an existing one is left exactly as it is.
ns_state_dir_ensure() {
  [ -d "$1/.nightshift" ] && return 0
  mkdir -p "$1/.nightshift" || return 1
  ns_write_state_version "$1" "$NS_LAYOUT_VERSION"
}

# ns_layout_parent <state-dir> <key> — create the directory <key> lives in, for a writer that may
# be the first to use it.
ns_layout_parent() {
  local _nsl_out
  ns_layout_set _nsl_out "$1" "$2" || return 1
  mkdir -p "${_nsl_out%/*}" 2>/dev/null
}
