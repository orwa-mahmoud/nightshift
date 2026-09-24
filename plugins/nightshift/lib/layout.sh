#!/usr/bin/env bash
# layout.sh — where each state file sits under .nightshift/. It needs nothing else, so the idle
# and cold-stop hooks load it on its own to find the markers before the library loads, and so
# does the evidence ledger; lib.sh loads it with the rest of the library.

# State layout. Every path under .nightshift/ comes from state-layout.tsv beside this file, read
# once when this file loads: a key resolves to the path its workspace's layout gives it. Layout
# 2 is the one this plugin writes; a version-1 or legacy workspace keeps the paths it has, so an
# upgraded plugin goes on guarding it, a shift armed before the upgrade included.
NS_LAYOUT_VERSION=2

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

# ns_layout_rel_set <var> <state-dir> <key> [instance] — the path of <key> relative to the state
# directory, in that directory's layout; <instance> fills the `*` of a family such as usage-*.
# Status 1 for a key this layout does not have. <var> must not begin with _nsl or __nsl.
ns_layout_rel_set() {
  local __nsl_v __nsl_name __nsl_rel
  ns_layout_version_set __nsl_v "$2"
  __nsl_name="_NS_L${__nsl_v}_${3//-/_}"
  __nsl_rel="${!__nsl_name-}"
  [ -n "$__nsl_rel" ] || return 1
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
