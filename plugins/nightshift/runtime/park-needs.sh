#!/usr/bin/env bash
# park-needs.sh — park the items whose elevation the owner has not granted.
#
#   park-needs.sh --project DIR
#
# Start asks nothing. It arms, parks every item the permission preflight found a gap for, and
# works the rest. This helper is that parking step, so it is mechanical rather than remembered:
# one entry per item and category, appended to parking-lot.md, and running it again adds nothing.
# It reads the preflight's own report, so the guard, the preflight and the parking entry can
# never name different categories.
#
# Prints one `parked <category>: <title>` line per entry added, then `park-needs: added N`.
# Exit: 0 ok · 1 usage · 2 no JSON parser, or the parking lot cannot be written
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PREFLIGHT="$_here/preflight-needs.sh"
TEMPLATE="$_here/../skills/nightshift/references/templates/parking-lot.md"

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0" >&2
  exit 1
}

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || usage
      PROJECT="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    *)
      printf 'park-needs: unknown argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'park-needs: cannot cd to %s\n' "$PROJECT" >&2
  exit 1
}
WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" || {
    printf 'park-needs: invalid .nightshift-link — Nightshift will not guess a workspace\n' >&2
    exit 1
  }
fi
NS="$WORKSPACE/.nightshift"
LOT="$NS/parking-lot.md"

no_parser() {
  printf 'park-needs: JSON parser unavailable; write the parking-lot row in the skill\n' >&2
  exit 2
}

cannot_write() {
  printf 'park-needs: cannot write %s\n' "$LOT" >&2
  exit 2
}

ns_policy_json_tool >/dev/null || no_parser
[ -d "$NS" ] || {
  printf 'park-needs: no .nightshift/ at %s — run setup first\n' "$WORKSPACE" >&2
  exit 2
}

TAB="$NS_POLICY_TAB"
TMPD="$(mktemp -d)" || {
  printf 'park-needs: cannot create a temporary directory\n' >&2
  exit 2
}
trap 'rm -rf "$TMPD"' EXIT

bash "$PREFLIGHT" --project "$WORKSPACE" --json >"$TMPD/preflight.json" || no_parser

GAPS_PY='
import json, sys

for gap in json.load(open(sys.argv[1]))["gaps"]:
    sys.stdout.write("%s\t%s\n" % (gap["category"], gap["title"]))
'

if [ "$(ns_policy_json_tool)" = jq ]; then
  jq -r '.gaps[] | .category + "\t" + .title' "$TMPD/preflight.json" >"$TMPD/gaps" || no_parser
else
  python3 -c "$GAPS_PY" "$TMPD/preflight.json" >"$TMPD/gaps" || no_parser
fi

# The entry the owner reads over coffee: what is missing, which item it holds, and the default
# taken so the night could continue. The line is also the idempotency key — an entry already in
# the file is the same work already parked.
entry() { # <category> <title>
  printf '**needs allowance: %s** — item "%s" needs the %s elevation category, which is denied for this shift. Default: parked, worked last if the owner allows it before then.' \
    "$1" "$2" "$1"
}

ADDED=0
: >"$TMPD/new"
: >"$TMPD/said"
while IFS="$TAB" read -r category title; do
  [ -n "$category" ] || continue
  line="$(entry "$category" "$title")"
  if [ -f "$LOT" ] && grep -qxF "$line" "$LOT"; then
    continue
  fi
  grep -qxF "$line" "$TMPD/new" 2>/dev/null && continue
  printf '%s\n' "$line" >>"$TMPD/new"
  printf 'parked %s: %s\n' "$category" "$title" >>"$TMPD/said"
  ADDED=$((ADDED + 1))
done <"$TMPD/gaps"

if [ "$ADDED" -gt 0 ]; then
  if [ ! -f "$LOT" ]; then
    if [ -f "$TEMPLATE" ]; then
      cp "$TEMPLATE" "$LOT" || cannot_write
    else
      printf '# Parking Lot\n\n---\n\n(empty)\n' >"$LOT" || cannot_write
    fi
  fi
  {
    cat "$LOT"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '\n%s\n' "$line"
    done <"$TMPD/new"
  } >"$LOT.tmp.$$" || {
    rm -f "$LOT.tmp.$$"
    cannot_write
  }
  mv "$LOT.tmp.$$" "$LOT" || {
    rm -f "$LOT.tmp.$$"
    cannot_write
  }
  cat "$TMPD/said"
fi
printf 'park-needs: added %s\n' "$ADDED"
exit 0
