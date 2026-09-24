#!/usr/bin/env bash
# preflight-needs.sh — which elevation categories tonight's work will need, and which it has.
#
#   preflight-needs.sh --project DIR [--json]
#
# Reads the open items under `## Items` in punch-list.md and every open item under a
# `## Work order` heading in work-orders.md, matches each item's own text against the same
# elevation patterns the guard uses, and reports per item what it needs, what the resolver
# allows, and the gap between them. A ticked item is finished work and is never scanned. Only a
# category the resolver reports as `allow` is allowed outright; a denial and an exact-plan
# narrowing are both gaps, because the preflight reads words and cannot know the command.
#
# This is a filter for surprises, not a guarantee: it reads words, not intent. Anything it misses
# is discovered mid-shift and parked under the red-tag rule. It reports and never refuses, so the
# exit status is always 0 — 1 for a usage error, 2 when no JSON parser is installed.
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0" >&2
  exit 1
}

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
FORMAT=text

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || usage
      PROJECT="$2"
      shift 2
      ;;
    --json)
      FORMAT=json
      shift
      ;;
    --text)
      FORMAT=text
      shift
      ;;
    -h | --help) usage ;;
    *)
      printf 'preflight-needs: unknown argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'preflight-needs: cannot cd to %s\n' "$PROJECT" >&2
  exit 1
}
WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" || {
    printf 'preflight-needs: invalid .nightshift-link — Nightshift will not guess a workspace\n' >&2
    exit 1
  }
fi
NS="$WORKSPACE/.nightshift"

no_parser() {
  printf 'preflight-needs: JSON parser unavailable; park gaps in the skill\n' >&2
  exit 2
}

ns_policy_json_tool >/dev/null || no_parser

TAB="$NS_POLICY_TAB"
TMPD="$(mktemp -d)" || {
  printf 'preflight-needs: cannot create a temporary directory\n' >&2
  exit 2
}
trap 'rm -rf "$TMPD"' EXIT

# An item is its checkbox line plus the sub-bullets under it, up to the next top-level box or
# heading. Every top-level box is numbered so the report's item numbers are the ones the owner
# counts in the file; only the open ones are scanned and reported. Control characters and tabs
# become spaces, so one item line stays one line of the scan stream.
scan() { # <source-label> <file>
  [ -f "$2" ] || return 0
  awk -v src="$1" '
    function emit(text,   t) {
      t = text
      gsub(/[\001-\010\013\014\016-\037\177]/, " ", t)
      gsub(/\t/, " ", t)
      gsub(/[*`]/, " ", t)
      printf "L\t%s\t%d\t%s\n", src, idx, t
    }
    /^[[:space:]]*-[[:space:]]*\[[[:space:]xX]\]/ {
      n++
      idx = n
      open = ($0 ~ /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/)
      if (open) {
        title = $0
        sub(/^[[:space:]]*-[[:space:]]*\[[[:space:]xX]\][[:space:]]*/, "", title)
        gsub(/[*`]/, "", title)
        gsub(/[\001-\037\177]/, " ", title)
        gsub(/[[:space:]]+/, " ", title)
        sub(/^ /, "", title)
        sub(/ $/, "", title)
        printf "T\t%s\t%d\t%s\n", src, idx, title
        emit($0)
      }
      next
    }
    /^##[[:space:]]/ { open = 0; next }
    open { emit($0) }
  ' "$2"
}

declare PUNCH WORK_ORDERS
ns_layout_set PUNCH "$NS" punch-list
ns_layout_set WORK_ORDERS "$NS" work-orders
{
  if [ -f "$PUNCH" ]; then
    ns_items_section "$PUNCH" >"$TMPD/items.md"
    scan punch-list "$TMPD/items.md"
  fi
  if [ -f "$WORK_ORDERS" ]; then
    sed -n '/^## Work order/,$p' "$WORK_ORDERS" >"$TMPD/orders.md"
    scan work-orders "$TMPD/orders.md"
  fi
} >"$TMPD/scan"

grep "^T$TAB" "$TMPD/scan" | cut -f2- >"$TMPD/titles" || :
grep "^L$TAB" "$TMPD/scan" | cut -f2- >"$TMPD/lines" || :

# One grep per category over every item line at once. The leading "<source><TAB><index><TAB>" is
# whitespace to the pattern, so a command at the head of an item line still matches. An invalid
# owner pattern fails closed — the category counts as needed — and is named in patternErrors.
: >"$TMPD/needs"
: >"$TMPD/patternerrors"
while IFS= read -r category; do
  [ -n "$category" ] || continue
  pattern="$(ns_policy_elevation_pattern "$WORKSPACE" "$category")"
  if valid_ere "$pattern"; then
    grep -E "$pattern" "$TMPD/lines" 2>/dev/null | cut -f1,2 |
      sed "s/\$/${TAB}${category}/" >>"$TMPD/needs"
  else
    printf '%s\n' "$category" >>"$TMPD/patternerrors"
    cut -f1,2 <"$TMPD/lines" | sed "s/\$/${TAB}${category}/" >>"$TMPD/needs"
  fi
done <<EOF
$NS_POLICY_CATEGORIES
EOF
LC_ALL=C sort -u "$TMPD/needs" -o "$TMPD/needs"

NS_POLICY_VERDICT_PY='
import json, sys

d = json.load(sys.stdin)["settings"]
for k in sorted(d):
    if k.startswith("elevation."):
        v = d[k]["value"]
        sys.stdout.write("%s\t%s\n" % (k[len("elevation."):], v))
'

# The verdicts come from the one resolver, read once.
if [ "$(ns_policy_json_tool)" = jq ]; then
  ns_policy_resolve "$WORKSPACE" | jq -r '.settings | to_entries[]
    | select(.key | startswith("elevation."))
    | (.key | ltrimstr("elevation.")) + "\t" + .value.value' >"$TMPD/verdict" || no_parser
else
  ns_policy_resolve "$WORKSPACE" | python3 -c "$NS_POLICY_VERDICT_PY" >"$TMPD/verdict" || no_parser
fi

verdict_of() {
  local v
  v="$(grep "^$1$TAB" "$TMPD/verdict" | cut -f2)"
  [ -n "$v" ] || v=deny
  printf '%s' "$v"
}

json_strings() { # one JSON string per input line, on stdin
  if [ "$(ns_policy_json_tool)" = jq ]; then
    jq -R .
  else
    python3 -c 'import json, sys
for line in sys.stdin.read().split("\n")[:-1]:
    sys.stdout.write(json.dumps(line, ensure_ascii=False) + "\n")'
  fi
}

cut -f3- <"$TMPD/titles" >"$TMPD/titletext"
json_strings <"$TMPD/titletext" >"$TMPD/titlejson"

ITEMS=0
GAPPED=0
GAPSUMMARY=""
GAP_JSON=""
JSON_ITEMS=""
TEXT=""
ROW=0

while IFS="$TAB" read -r source index _; do
  [ -n "$source" ] || continue
  ROW=$((ROW + 1))
  ITEMS=$((ITEMS + 1))
  title_json="$(sed -n "${ROW}p" "$TMPD/titlejson")"
  title="$(sed -n "${ROW}p" "$TMPD/titletext")"
  needs_json=""
  block=""
  gapped=0
  while IFS= read -r category; do
    [ -n "$category" ] || continue
    grep -qxF "$source$TAB$index$TAB$category" "$TMPD/needs" || continue
    resolved="$(verdict_of "$category")"
    if [ "$resolved" = allow ]; then
      needs_json="$needs_json{\"allowed\":true,\"category\":\"$category\",\"resolved\":\"$resolved\"},"
      block="$block  needs $category (allowed)$NS_POLICY_NL"
      continue
    fi
    needs_json="$needs_json{\"allowed\":false,\"category\":\"$category\",\"resolved\":\"$resolved\"},"
    GAP_JSON="$GAP_JSON{\"category\":\"$category\",\"title\":$title_json},"
    GAPSUMMARY="$GAPSUMMARY$category (item $index), "
    gapped=1
    if [ "$resolved" = exact-plan ]; then
      block="$block  needs $category (allowed only for the approved plan)$NS_POLICY_NL"
    else
      block="$block  needs $category (denied)$NS_POLICY_NL"
    fi
  done <<EOF
$NS_POLICY_CATEGORIES
EOF
  [ "$gapped" -eq 0 ] || GAPPED=$((GAPPED + 1))
  [ -n "$block" ] || block="  needs nothing$NS_POLICY_NL"
  TEXT="${TEXT}item $index [$source] $title$NS_POLICY_NL$block"
  JSON_ITEMS="$JSON_ITEMS{\"needs\":[${needs_json%,}],\"source\":\"$source\",\"title\":$title_json},"
done <"$TMPD/titles"

PATTERN_JSON=""
if [ -s "$TMPD/patternerrors" ]; then
  while IFS= read -r category; do
    [ -n "$category" ] || continue
    PATTERN_JSON="$PATTERN_JSON\"$category\","
  done <"$TMPD/patternerrors"
fi

if [ "$FORMAT" = json ]; then
  printf '{"gaps":[%s],"items":[%s],"patternErrors":[%s],"schemaVersion":1}\n' \
    "${GAP_JSON%,}" "${JSON_ITEMS%,}" "${PATTERN_JSON%,}" | ns_policy_canon_text || no_parser
  exit 0
fi

printf 'preflight: %s open items, %s with gaps\n' "$ITEMS" "$GAPPED"
[ -z "$TEXT" ] || printf '%s' "$TEXT"
if [ -n "$PATTERN_JSON" ]; then
  while IFS= read -r category; do
    [ -n "$category" ] || continue
    printf 'pattern error: elevation.%s.pattern is not a valid grep -E pattern; the category counts as needed\n' \
      "$category"
  done <"$TMPD/patternerrors"
fi
if [ -n "$GAPSUMMARY" ]; then
  printf 'gaps: %s\n' "${GAPSUMMARY%, }"
else
  printf 'gaps: none\n'
fi
exit 0
