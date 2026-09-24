#!/usr/bin/env bash
# path.sh — where a state file lives in this workspace's layout.
#
#   path.sh [--project DIR] <key>...    one absolute path per key, in the order named
#   path.sh [--project DIR] --list      every key with its path, tab separated
#
# The layout table beside the library is the one answer. A skill command names a key instead of
# spelling a path under .nightshift/, so the same command lands in the right place whichever
# layout the workspace keeps. Nothing is created or changed.
#
# Exit: 0 printed · 1 usage or a key this layout does not have
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
LIST=no
KEYS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'path: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --list)
      LIST=yes
      shift
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    -*) printf 'path: unknown argument: %s\n' "$1" >&2; exit 1 ;;
    *)
      KEYS="$KEYS $1"
      shift
      ;;
  esac
done

WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || {
  printf 'path: invalid .nightshift-link — Nightshift will not guess a workspace\n' >&2
  exit 1
}
NS="$WORKSPACE/.nightshift"

if [ "$LIST" = yes ]; then
  printf '%s' "$NS_LAYOUT_ROWS" | while IFS="$(printf '\t')" read -r key _ _ kind; do
    case "$kind" in field | retired | stray) continue ;; esac
    ns_layout_set path "$NS" "$key" '*' || continue
    printf '%s\t%s\n' "$key" "$path"
  done | awk -F '\t' '!seen[$1]++'
  exit 0
fi

[ -n "$KEYS" ] || { printf 'path: name a state key, or --list\n' >&2; exit 1; }
for key in $KEYS; do
  ns_layout_set path "$NS" "$key" || {
    printf 'path: layout %s has no %s\n' "$(ns_layout_version_set v "$NS"; printf '%s' "$v")" "$key" >&2
    exit 1
  }
  printf '%s\n' "$path"
done
