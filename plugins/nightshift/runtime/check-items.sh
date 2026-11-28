#!/usr/bin/env bash
# check-items.sh — check the shape of drafted items before they are promoted.
#
#   check-items.sh --project DIR [--file PATH]
#
# Reads the drafting table, or the file named: the items under its `## Items` heading when it has
# one (a punch list), else the items below its first `---` rule, else the whole file. For each item
# it reports what the gate and the item's own definition of done would trip over:
#
#   no Verify: line · a Verify: that names no command, path, number, quoted text, URL or WHEN/THEN
#   (a question, since a plain sentence can be checkable) · no Commit: line
#   (or Receipt: in artifact mode) · an Evidence: line that names nothing · a Budget: line that
#   does not parse · a nested checkbox
#
# Evidence: is optional; an item without it reads exactly as one written before the line existed.
#
# and, anywhere in that part of the file, a checkbox outside an item line, which the gate would count
# as an open item. It checks the shape of the plan, never the work behind a tick, and refuses
# nothing: Start and promotion never wait on it. Read-only.
#
# Exit: 0 checked · 1 usage/resolve
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# The programs this script runs sit beside lib.sh.
PROGRAMS="$_here/../lib"
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT=""
FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'check-items: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --file)
      [ $# -ge 2 ] || { printf 'check-items: --file needs a value\n' >&2; exit 1; }
      FILE="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'check-items: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$PROJECT" ] || { printf 'check-items: --project is required\n' >&2; exit 1; }

if [ -z "$FILE" ]; then
  WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || { printf 'check-items: no workspace at %s\n' "$PROJECT" >&2; exit 1; }
  ns_layout_set FILE "$WORKSPACE/.nightshift" drafting-table
fi
if [ ! -f "$FILE" ] || [ -L "$FILE" ]; then
  printf 'no items to check: %s is not there\n' "$FILE"
  exit 0
fi

# Events, in file order: `item <label>`, `find <finding>`, `budget <text>` for the item being read,
# and `outside <line>` for a box no item owns.
EVENTS="$(awk -f "$PROGRAMS/check-items-events.awk" "$FILE")"

ITEMS=0
WITH=0
LABEL=""
ITEM_FINDINGS=0
# close_item — the `ok` line for an item that had nothing to report.
close_item() {
  [ -n "$LABEL" ] || return 0
  if [ "$ITEM_FINDINGS" -eq 0 ]; then
    printf '%s: ok\n' "$LABEL"
  else
    WITH=$((WITH + 1))
  fi
  LABEL=""
}
finding() {
  printf '%s: %s\n' "$LABEL" "$1"
  ITEM_FINDINGS=$((ITEM_FINDINGS + 1))
}
OUTSIDE=0
while IFS=$'\t' read -r kind text; do
  case "$kind" in
    item)
      close_item
      LABEL="$text"
      ITEM_FINDINGS=0
      ITEMS=$((ITEMS + 1))
      ;;
    find) finding "$text" ;;
    budget) ns_budget_parse "$text" >/dev/null 2>&1 || finding "Budget: does not parse ($text)" ;;
    outside)
      close_item
      printf 'line %s: a checkbox outside an item line counts as an open item\n' "$text"
      OUTSIDE=$((OUTSIDE + 1))
      ;;
  esac
done <<<"$EVENTS"
close_item

if [ "$ITEMS" -eq 0 ] && [ "$OUTSIDE" -eq 0 ]; then
  printf 'no items to check\n'
  exit 0
fi
printf 'checked %s items: %s with findings' "$ITEMS" "$WITH"
case "$OUTSIDE" in
  0) ;;
  1) printf ', 1 stray checkbox' ;;
  *) printf ', %s stray checkboxes' "$OUTSIDE" ;;
esac
printf '\n'
