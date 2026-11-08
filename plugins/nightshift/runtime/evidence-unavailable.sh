#!/usr/bin/env bash
# evidence-unavailable.sh — apply the item's unavailable setting.
#
#   evidence-unavailable.sh --project DIR --item LABEL --reason TEXT
#
# hold closes the item as stopped, with the reason on its receipt and the snag log.
# park writes one parking-lot entry and leaves the item. note ticks it and records the reason.
# The item's setting wins; when it sets none, hold is used while check is block, and note otherwise.
#
# --project is required. Does not use the current working directory.
#
# Exit: 0 applied · 1 usage or no such item
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT=""
ITEM=""
REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'evidence-unavailable: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --item)
      [ $# -ge 2 ] || { printf 'evidence-unavailable: --item needs a value\n' >&2; exit 1; }
      ITEM="$2"
      shift 2
      ;;
    --reason)
      [ $# -ge 2 ] || { printf 'evidence-unavailable: --reason needs a value\n' >&2; exit 1; }
      REASON="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'evidence-unavailable: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$PROJECT" ] || { printf 'evidence-unavailable: --project is required\n' >&2; exit 1; }
[ -n "$ITEM" ] || { printf 'evidence-unavailable: --item is required\n' >&2; exit 1; }

applied="$(ns_evidence_unavailable "$PROJECT" "$ITEM" "$REASON")" || {
  printf 'evidence-unavailable: no such item: %s\n' "$ITEM" >&2
  exit 1
}
printf '%s\n' "$applied"
exit 0
