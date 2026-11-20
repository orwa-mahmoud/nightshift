#!/usr/bin/env bash
# write-rules-elevation.sh — set one elevation category's permanent policy in a project's rules.
#
#   write-rules-elevation.sh --project DIR --category NAME --policy allow|deny
#
# rules.json is the owner's permanent boundary and hardhat guards it during a shift, so the
# fixture edits the copy Setup left in the project rather than reaching for the helper.
set -eu

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
TEMPLATE="$_here/../../../plugins/nightshift/config/nightshift-rules-template.json"

PROJECT=""
CATEGORY=""
POLICY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      PROJECT="$2"
      shift 2
      ;;
    --category)
      CATEGORY="$2"
      shift 2
      ;;
    --policy)
      POLICY="$2"
      shift 2
      ;;
    *)
      printf 'write-rules-elevation: unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$PROJECT" ] || [ -z "$CATEGORY" ] || [ -z "$POLICY" ]; then
  printf 'write-rules-elevation: --project, --category and --policy are required\n' >&2
  exit 1
fi

RULES="$PROJECT/.nightshift/rules.json"
mkdir -p "$PROJECT/.nightshift"
[ -f "$RULES" ] || cp "$TEMPLATE" "$RULES"

jq --arg c "$CATEGORY" --arg p "$POLICY" '.elevation[$c].policy = $p' "$RULES" >"$RULES.tmp.$$"
mv "$RULES.tmp.$$" "$RULES"
