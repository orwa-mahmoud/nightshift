#!/usr/bin/env bash
# plan-new.sh — start a named plan: a punch list that waits its turn.
#
#   plan-new.sh --project DIR --name NAME
#
# Writes `<plans>/<key>.md`, where <key> is the name lowercased with every other character a
# hyphen. The file holds the shipped punch-list contract and its empty gates block, with the
# workspace's paths written in as Setup writes them, under the title `# Punch List — NAME` and an
# empty `## Items` section. The live punch list is not read: a new plan never inherits the last
# shift's branch, scans or permissions. The planning conversation writes the plan's own contract
# and gates into this file, and Start cuts it into the punch list whole. A plan that already has
# the key is kept exactly as it is.
#
# Prints `wrote <path>` or `kept <path>`, relative to the workspace.
# Exit: 0 done · 1 usage/resolve · 2 refused
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT=""
NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'plan-new: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --name)
      [ $# -ge 2 ] || { printf 'plan-new: --name needs a value\n' >&2; exit 1; }
      NAME="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'plan-new: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$PROJECT" ] || { printf 'plan-new: --project is required\n' >&2; exit 1; }
NAME="$(printf '%s' "$NAME" | tr -d '\r\n')"
[ -n "${NAME//[[:space:]]/}" ] || { printf 'plan-new: --name is required\n' >&2; exit 1; }

WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || { printf 'plan-new: no workspace at %s\n' "$PROJECT" >&2; exit 1; }
NS="$WORKSPACE/.nightshift"
if [ ! -d "$NS" ] || [ -L "$NS" ]; then
  printf 'plan-new: no .nightshift/ at %s — run Setup first\n' "$WORKSPACE" >&2
  exit 1
fi
DIR="$(ns_plans_dir "$NS")" || {
  printf 'plan-new: this workspace keeps plans in its drafting table; ns migrate-state moves it to the layout with plan files\n' >&2
  exit 2
}
TEMPLATE="$(ns_templates_dir)/punch-list.md"
[ -f "$TEMPLATE" ] || { printf 'plan-new: no shipped punch-list template at %s\n' "$TEMPLATE" >&2; exit 1; }

KEY="$(ns_receipt_slug "$NAME")"
[ -n "$KEY" ] || { printf 'plan-new: %s has no letters or digits to name a file by\n' "$NAME" >&2; exit 1; }
REL="$(ns_layout_name "$NS" plans)/$KEY.md"
FILE="$DIR/$KEY.md"

if [ -L "$DIR" ] || { [ -e "$DIR" ] && [ ! -d "$DIR" ]; }; then
  printf 'plan-new: %s is not a folder\n' "$(ns_layout_name "$NS" plans)" >&2
  exit 2
fi
if [ -e "$FILE" ] || [ -L "$FILE" ]; then
  [ -f "$FILE" ] && [ ! -L "$FILE" ] || { printf 'plan-new: %s is not a plain file\n' "$REL" >&2; exit 2; }
  printf 'kept %s\n' "$REL"
  exit 0
fi
mkdir -p "$DIR" || { printf 'plan-new: could not create %s\n' "$(ns_layout_name "$NS" plans)" >&2; exit 1; }

TMP="$DIR/.$KEY.md.tmp.$$"
written=no
if {
  printf '# Punch List — %s\n' "$NAME"
  # The shipped contract and gates: everything after the template's title line and before
  # `## Items`.
  ns_owner_template "$TEMPLATE" "$WORKSPACE" | awk '
    NR == 1 { next }
    /^## Items[[:space:]]*$/ { exit }
    { print }
  '
  printf '## Items\n\n'
} >"$TMP" 2>/dev/null; then
  mv -f "$TMP" "$FILE" 2>/dev/null && written=yes
fi
if [ "$written" != yes ]; then
  rm -f "$TMP"
  printf 'plan-new: could not write %s\n' "$REL" >&2
  exit 1
fi
printf 'wrote %s\n' "$REL"
