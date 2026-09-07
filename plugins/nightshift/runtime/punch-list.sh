#!/usr/bin/env bash
# punch-list.sh — the gates block and one item, printed exactly as the owner wrote them.
#
#   punch-list.sh --project <ws> next        the gates block, then the first still-open item
#   punch-list.sh --project <ws> item <id>   the gates block, then that named item
#
# The `## Gates` block may legitimately change mid-shift, so an item needs it fresh — and reading
# the whole punch list to see one block is thousands of tokens per item on a long list. This prints
# the two things an item actually needs and nothing else.
#
# It is a reader and only a reader. Nothing here rewrites, reorders, renumbers or summarises an
# item: what comes out is the file's own text, byte for byte, so a model working from it is
# working from the contract rather than from someone's précis of it.
#
# An item is one top-level checkbox line plus the indented lines that follow it, up to the next
# top-level line — the same bounded rule the gate and Status already use for counting boxes, not a
# Markdown parser. Fenced code and nested lists inside an item are indented, so they come through
# whole.
#
# Exit: 0 printed, or `none` when nothing is open · 1 usage · 2 refused
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
VERB=""
WANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'punch-list: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    next)
      VERB=next
      shift
      ;;
    item)
      [ $# -ge 2 ] || { printf 'punch-list: item needs an id\n' >&2; exit 1; }
      VERB=item
      WANT="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'punch-list: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$VERB" ] || { printf 'punch-list: usage: punch-list.sh [--project DIR] next|item <id>\n' >&2; exit 1; }

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'punch-list: cannot cd to %s\n' "$PROJECT" >&2
  exit 1
}
WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" || {
    printf 'punch-list: invalid .nightshift-link — Nightshift will not guess a workspace\n' >&2
    exit 2
  }
fi
PUNCH="$WORKSPACE/.nightshift/punch-list.md"
if [ ! -f "$PUNCH" ] || [ -L "$PUNCH" ]; then
  printf 'punch-list: no punch list at %s\n' "$PUNCH" >&2
  exit 2
fi

# The gates block, verbatim: everything from its heading to the next top-level heading. The owner
# may change it mid-shift by design, which is the whole reason this is printed every time.
ns_punch_gates "$PUNCH"

if [ "$VERB" = next ]; then
  body="$(ns_punch_item "$PUNCH" "")"
else
  body="$(ns_punch_item "$PUNCH" "$WANT")"
fi
if [ -z "$body" ]; then
  if [ "$VERB" = item ]; then
    printf 'punch-list: no item %s in %s\n' "$WANT" "$PUNCH" >&2
    exit 2
  fi
  printf 'none\n'
  exit 0
fi
printf '%s\n' "$body"
exit 0
