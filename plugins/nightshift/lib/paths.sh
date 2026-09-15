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
# has no armed shift. Hooks/shared/idle.sh already covers the no-link case
# before this file is sourced; this catches a .nightshift-link to an unarmed
# workspace. Revival workers stay in.
ns_hook_idle_exit() {
  [ "${NIGHTSHIFT_REVIVAL:-}" != "1" ] || return 0
  local host project ns
  host="$(ns_hook_host_dir)"
  project="$(ns_workspace_root "$host" 2>/dev/null)" || exit 0
  ns="$project/.nightshift"
  [ -f "$ns/.shift-armed" ] || exit 0
  if [ -f "$ns/.ended" ] && [ ! -L "$ns/.ended" ]; then
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
# revival, toolDeny) so a drifted cwd cannot send the agent to a nested copy.
# Expansion happens at injection time; the owner's rules file keeps the relative
# form so it stays editable without a skill variable.
ns_expand_injected_paths() {
  local ws="$1" text="$2"
  [ -n "$ws" ] || { printf '%s' "$text"; return 0; }
  text="${text//\$NIGHTSHIFT_WORKSPACE/$ws}"
  text="${text//\$NS/$ws/.nightshift}"
  printf '%s' "$text" | awk -v ws="$ws" '
    BEGIN { ORS="" }
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
  local record="$1/.nightshift/work-mode" mode=""
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
  local project="$1" mode="$2" tmp
  case "$mode" in repository | artifact) ;; *) return 1 ;; esac
  mkdir -p "$project/.nightshift" || return 1
  tmp="$project/.nightshift/.work-mode.$$"
  printf '%s\n' "$mode" >"$tmp" || return 1
  mv "$tmp" "$project/.nightshift/work-mode"
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
