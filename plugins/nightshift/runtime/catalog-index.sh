#!/usr/bin/env bash
# catalog-index.sh — what a catalog holds, one line per entry.
#
#   catalog-index.sh [--plugin-root DIR] [--catalog shifts|evidence]
#                    [--project DIR] [--template] [--check-draft FILE]
#
# shifts, the default, reads references/compose/shifts and prints slug, ending, title and summary.
# --project is accepted and ignored for shifts, so a caller that passes the workspace does not
# change that listing. evidence reads every evidence kind — the shipped files, the project folder,
# the user folder, and the folders in receipts.evidence.kindsPaths — and prints key, title,
# description, source and the sources a same key replaced. --template prints the kind template
# in force. --check-draft FILE checks one draft and names each required section it lacks.
#
# Every entry opens with an H1, and that header is the metadata, so there is no second registry
# to keep in step: a new file is listed the moment it exists, and one that is deleted stops being
# listed. A symlink is skipped.
#
# Reads the catalog and nothing else, writes nothing, and decides nothing — which entry suits an
# item is the model's judgement, not a score this helper computes.
#
# Exit: 0 listed · 1 usage, or a draft that fails its check · 2 no catalog to read, or a template
# path that is not a file
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.

PLUGIN_ROOT="$_here/.."
CATALOG="shifts"
WORKSPACE=""
SHOW_TEMPLATE=no
CHECK_DRAFT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin-root)
      [ $# -ge 2 ] || {
        printf 'catalog-index: --plugin-root needs a value\n' >&2
        exit 1
      }
      PLUGIN_ROOT="$2"
      shift 2
      ;;
    --catalog)
      [ $# -ge 2 ] || {
        printf 'catalog-index: --catalog needs a value\n' >&2
        exit 1
      }
      CATALOG="$2"
      shift 2
      ;;
    --project)
      [ $# -ge 2 ] || {
        printf 'catalog-index: --project needs a value\n' >&2
        exit 1
      }
      WORKSPACE="$2"
      shift 2
      ;;
    --template)
      SHOW_TEMPLATE=yes
      shift
      ;;
    --check-draft)
      [ $# -ge 2 ] || {
        printf 'catalog-index: --check-draft needs a value\n' >&2
        exit 1
      }
      CHECK_DRAFT="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *)
      printf 'catalog-index: unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

if [ -d "$PLUGIN_ROOT" ]; then
  PLUGIN_ROOT="$(cd "$PLUGIN_ROOT" && pwd -P)"
fi

if [ "$CATALOG" = shifts ]; then
  if [ "$SHOW_TEMPLATE" = yes ] || [ -n "$CHECK_DRAFT" ]; then
    printf 'catalog-index: shifts does not take that argument\n' >&2
    exit 1
  fi
  DIR="$PLUGIN_ROOT/skills/nightshift/references/compose/shifts"
  [ -d "$DIR" ] || {
    printf 'catalog-index: no catalog at %s\n' "$DIR" >&2
    exit 2
  }
  found=0
  for f in "$DIR"/*.md; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    found=1
    base="${f##*/}"
    LC_ALL=C awk -v slug="${base%.md}" '
      /^# / && !seen {
        seen = 1
        line = substr($0, 3)
        n = split(line, part, " \xe2\x80\x94 ")
        title = part[1]
        ending = (n >= 2) ? part[2] : ""
        summary = ""
        for (i = 3; i <= n; i++) {
          summary = summary (summary == "" ? "" : " - ") part[i]
        }
        next
      }
      seen && summary == "" && /^[^#[:space:]]/ {
        summary = $0
      }
      END {
        gsub(/\t/, " ", title)
        gsub(/\t/, " ", ending)
        gsub(/\t/, " ", summary)
        printf "%s\t%s\t%s\t%s\n", slug, ending, title, summary
      }
    ' "$f"
  done
  [ "$found" -eq 1 ] || {
    printf 'catalog-index: the catalog holds no entries\n' >&2
    exit 2
  }
  exit 0
fi

if [ "$CATALOG" != evidence ]; then
  printf 'catalog-index: unknown catalog: %s\n' "$CATALOG" >&2
  exit 1
fi

# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"
# shellcheck source=plugins/nightshift/lib/catalog-sources.sh
. "$_here/../lib/catalog-sources.sh"

NS_CATALOG_HEADINGS='When it applies|Evidence lines|How to generate|How to verify|Never'
NS_CATALOG_BULLET='Evidence lines'
NS_CATALOG_FENCE='evidence-check'
NS_CATALOG_FENCE_KEYS='files min type'
NS_CATALOG_FENCE_TYPES='image text json any'

shipped="$PLUGIN_ROOT/skills/nightshift/references/templates/evidence-kind.md"
template_setting=""
paths_raw=""
if [ -n "$WORKSPACE" ]; then
  template_setting="$(ns_policy_pref "$WORKSPACE" receipts evidence.kindTemplatePath 2>/dev/null || true)"
  paths_raw="$(ns_policy_pref "$WORKSPACE" receipts evidence.kindsPaths 2>/dev/null || true)"
fi

if [ "$SHOW_TEMPLATE" = yes ]; then
  if [ -n "$template_setting" ]; then
    resolved="$(ns_catalog_resolve "$WORKSPACE" "$template_setting")"
  else
    resolved="$shipped"
  fi
  printf '%s\n' "$resolved"
  [ -f "$resolved" ] && [ ! -L "$resolved" ] || exit 2
  exit 0
fi

if [ -n "$CHECK_DRAFT" ]; then
  problems="$(ns_catalog_entry_problems "$CHECK_DRAFT" || true)"
  if [ -n "$problems" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf 'catalog-index: %s: %s\n' "$CHECK_DRAFT" "$line" >&2
    done <<EOF
$problems
EOF
    exit 1
  fi
  exit 0
fi

plugin_dir="$PLUGIN_ROOT/skills/nightshift/references/evidence/kinds"
[ -d "$plugin_dir" ] || {
  printf 'catalog-index: no catalog at %s\n' "$plugin_dir" >&2
  exit 2
}

project_dir=""
if [ -n "$WORKSPACE" ]; then
  project_dir="$(ns_layout_path "$WORKSPACE/.nightshift" evidence-kinds 2>/dev/null || true)"
fi
user_dir="$(ns_catalog_user_dir evidence kinds)"

set --
if [ -n "$paths_raw" ] && [ "$paths_raw" != null ]; then
  parsed="$(python3 -c 'import json,sys
try:
    v=json.loads(sys.argv[1])
except Exception:
    sys.exit(2)
if v is None:
    sys.exit(0)
if not isinstance(v, list) or any(not isinstance(x, str) for x in v):
    sys.exit(2)
for x in v:
    sys.stdout.write(x + "\n")
' "$paths_raw" 2>/dev/null)" || parsed="__unreadable__"
  if [ "$parsed" = "__unreadable__" ]; then
    printf 'catalog-index: kindsPaths could not be read\n' >&2
  else
    while IFS= read -r raw; do
      [ -n "$raw" ] || continue
      set -- "$@" "$raw" "$(ns_catalog_resolve "$WORKSPACE" "$raw")"
    done <<EOF
$parsed
EOF
  fi
fi

listed="$(ns_catalog_list catalog-index "$plugin_dir" "$project_dir" "$user_dir" "$@")"
if [ -z "$listed" ]; then
  printf 'catalog-index: the catalog holds no entries\n' >&2
  exit 2
fi
printf '%s\n' "$listed"
exit 0
