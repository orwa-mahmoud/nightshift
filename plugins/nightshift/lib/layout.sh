#!/usr/bin/env bash
# layout.sh — where each state file sits under .nightshift/. It needs nothing else, so the idle
# and cold-stop hooks load it on its own to find the markers before the library loads, and so
# does the evidence ledger; lib.sh loads it with the rest of the library.

# State layout. Every path under .nightshift/ comes from state-layout.tsv beside this file, read
# once when this file loads: a key resolves to the path its workspace's layout gives it. Layout
# 3 is the one this plugin writes; a workspace on an earlier layout keeps the paths it has, so an
# upgraded plugin goes on guarding it, a shift armed before the upgrade included.
#
# Layout 3 keeps each shift in its own folder, `runs/<run>/`. A per-run key resolves inside the run
# the caller names in NIGHTSHIFT_RUN; with none named, inside the only run the workspace has. With
# several runs and none named, a per-run key does not resolve: nothing guesses between two runs.
NS_LAYOUT_VERSION=3

_ns_layout_load() { # <table>
  local key since path kind v
  NS_LAYOUT_ROWS=''
  while IFS=$'\t' read -r key since path kind; do
    case "$key" in '' | '#'*) continue ;; esac
    NS_LAYOUT_ROWS="$NS_LAYOUT_ROWS$key	$since	$path	$kind
"
    case "$kind" in field | retired | stray) continue ;; esac
    v="$since"
    while [ "$v" -le "$NS_LAYOUT_VERSION" ]; do
      printf -v "_NS_L${v}_${key//-/_}" '%s' "$path"
      v=$((v + 1))
    done
  done <"$1"
}

# ns_layout_version_set <var> <state-dir> — the layout this state directory uses: its
# state-version when that is a layout this plugin knows, 1 for version 1, legacy and a marker that
# cannot be read. A newer marker reads as the newest layout; the state-version check refuses it.
ns_layout_version_set() {
  local _nsv=""
  if [ -f "$2/state-version" ] && [ ! -L "$2/state-version" ]; then
    { IFS= read -r _nsv <"$2/state-version"; } 2>/dev/null || :
  fi
  _nsv="${_nsv%$'\r'}"
  case "$_nsv" in
    '' | *[!0-9]* | 0?* | ?????????*) _nsv=1 ;;
  esac
  if [ "$_nsv" -lt 1 ]; then
    _nsv=1
  elif [ "$_nsv" -gt "$NS_LAYOUT_VERSION" ]; then
    _nsv="$NS_LAYOUT_VERSION"
  fi
  printf -v "$1" '%s' "$_nsv"
}

# ns_run_name_ok <name> — status 0 for a name a run folder may have: one path segment, not hidden.
ns_run_name_ok() {
  case "$1" in '' | .* | */* | *\\* | *$'\n'*) return 1 ;; esac
  return 0
}

# ns_layout_run_set <var> <state-dir> — the run a per-run key resolves in: NIGHTSHIFT_RUN when it
# names one, else the only run folder under runs/. Status 1 when the name is not a run folder name,
# when there is no run, and when there are several and none is named. <var> must not begin with
# _nsr.
ns_layout_run_set() {
  local _nsr_d _nsr_found="" _nsr_n=0
  if [ -n "${NIGHTSHIFT_RUN-}" ]; then
    ns_run_name_ok "$NIGHTSHIFT_RUN" || return 1
    printf -v "$1" '%s' "$NIGHTSHIFT_RUN"
    return 0
  fi
  for _nsr_d in "$2"/runs/*/; do
    [ -d "$_nsr_d" ] && [ ! -L "${_nsr_d%/}" ] || continue
    _nsr_d="${_nsr_d%/}"
    _nsr_found="${_nsr_d##*/}"
    _nsr_n=$((_nsr_n + 1))
  done
  [ "$_nsr_n" -eq 1 ] || return 1
  printf -v "$1" '%s' "$_nsr_found"
}

# ns_layout_per_run <state-dir> <key> — status 0 when <key> belongs to one run in that directory's
# layout (its path starts `runs/*/`).
ns_layout_per_run() {
  local _nslp_v _nslp_name
  ns_layout_version_set _nslp_v "$1"
  _nslp_name="_NS_L${_nslp_v}_${2//-/_}"
  case "${!_nslp_name-}" in 'runs/*/'*) return 0 ;; esac
  return 1
}

# ns_layout_runs <state-dir> — every run folder name under runs/, one per line, sorted.
ns_layout_runs() {
  local d
  for d in "$1"/runs/*/; do
    [ -d "$d" ] && [ ! -L "${d%/}" ] || continue
    d="${d%/}"
    ns_run_name_ok "${d##*/}" && printf '%s\n' "${d##*/}"
  done
}

# ns_layout_rel_set <var> <state-dir> <key> [instance] — the path of <key> relative to the state
# directory, in that directory's layout. A per-run key (`runs/*/…`) takes its run from
# ns_layout_run_set; <instance> fills the remaining `*` of a family such as usage-*. Status 1 for a
# key this layout does not have, and for a per-run key with no run to resolve in. <var> must not
# begin with _nsl or __nsl.
ns_layout_rel_set() {
  local __nsl_v __nsl_name __nsl_rel __nsl_run
  ns_layout_version_set __nsl_v "$2"
  __nsl_name="_NS_L${__nsl_v}_${3//-/_}"
  __nsl_rel="${!__nsl_name-}"
  [ -n "$__nsl_rel" ] || return 1
  case "$__nsl_rel" in
    'runs/*/'*)
      ns_layout_run_set __nsl_run "$2" || return 1
      __nsl_rel="runs/$__nsl_run/${__nsl_rel#runs/\*/}"
      ;;
  esac
  case "$__nsl_rel" in *'*'*) __nsl_rel="${__nsl_rel/\*/$4}" ;; esac
  printf -v "$1" '%s' "$__nsl_rel"
}

# ns_layout_rel_at <var> <version> <key> — the path <key> had in layout <version>, relative to the
# state directory, for code that must still find a file an older layout left behind. Status 1
# when that layout had no such key.
ns_layout_rel_at() {
  local __nsl_name __nsl_rel
  __nsl_name="_NS_L${2}_${3//-/_}"
  __nsl_rel="${!__nsl_name-}"
  [ -n "$__nsl_rel" ] || return 1
  printf -v "$1" '%s' "$__nsl_rel"
}

# ns_layout_set <var> <state-dir> <key> [instance] — the absolute path of <key>.
ns_layout_set() {
  local _nsl_path
  ns_layout_rel_set _nsl_path "$2" "$3" "${4-}" || return 1
  printf -v "$1" '%s/%s' "$2" "$_nsl_path"
}

# ns_layout_path <state-dir> <key> [instance] — print the absolute path of <key>.
ns_layout_path() {
  local _nsl_out
  ns_layout_set _nsl_out "$@" || return 1
  printf '%s' "$_nsl_out"
}

# ns_layout_name <state-dir> <key> — a state file as a message names it, `.nightshift/<path>` in
# that directory's layout.
ns_layout_name() {
  local _nsl_rel
  ns_layout_rel_set _nsl_rel "$1" "$2" || _nsl_rel="$2"
  printf '.nightshift/%s' "$_nsl_rel"
}

# The table is read once, whether the library or a hook loaded this file first.
if [ -z "${NS_LAYOUT_ROWS:-}" ]; then
  _ns_layout_dir="${BASH_SOURCE[0]%/*}"
  [ "$_ns_layout_dir" != "${BASH_SOURCE[0]}" ] || _ns_layout_dir=.
  _ns_layout_load "$_ns_layout_dir/state-layout.tsv"
  unset _ns_layout_dir
fi
