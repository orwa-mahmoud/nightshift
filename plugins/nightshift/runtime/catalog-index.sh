#!/usr/bin/env bash
# catalog-index.sh — what a catalog holds, one line per entry.
#
#   catalog-index.sh [--plugin-root DIR] [--catalog NAME] [--project DIR]
#                    [--template | --check-draft FILE | --path KEY]
#
# NAME is a row of lib/catalogs.tsv: shifts (the default), evidence, gates, or edge-cases. Every
# catalog reads the shipped entries, the project folder, the user folder, and the folders the rules
# file names, with the precedence lib/catalog-sources.sh describes.
#
# shifts prints slug, ending, title and summary. The others print key, title, description, source,
# and the sources a same key replaced; gates prints them in match order. --template prints the
# template in force. --check-draft FILE checks what code reads in one draft and names each problem.
# --path KEY prints the file in force for one key.
#
# Every entry opens with an H1, and that header is the metadata, so there is no second registry
# of entries to keep in step: a new file is listed the moment it exists. A symlink is skipped.
#
# Reads the catalog and nothing else, writes nothing, and decides nothing — which entry suits an
# item is the model's judgement, not a score this helper computes.
#
# Exit: 0 listed · 1 usage, or a draft that fails its check · 2 no catalog to read, no such key,
# or a template path that is not a file
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.

PLUGIN_ROOT="$_here/.."
CATALOG="shifts"
WORKSPACE=""
MODE=list
ARG=""
need_value() {
  [ "$2" -ge 2 ] || {
    printf 'catalog-index: %s needs a value\n' "$1" >&2
    exit 1
  }
}
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin-root) need_value "$1" $#; PLUGIN_ROOT="$2"; shift 2 ;;
    --catalog) need_value "$1" $#; CATALOG="$2"; shift 2 ;;
    --project) need_value "$1" $#; WORKSPACE="$2"; shift 2 ;;
    --template) MODE=template; shift ;;
    --check-draft) need_value "$1" $#; MODE=check; ARG="$2"; shift 2 ;;
    --path) need_value "$1" $#; MODE=path; ARG="$2"; shift 2 ;;
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

# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"
# shellcheck source=plugins/nightshift/lib/catalog-sources.sh
. "$_here/../lib/catalog-sources.sh"

ns_catalog_row "$CATALOG" || {
  printf 'catalog-index: unknown catalog: %s\n' "$CATALOG" >&2
  exit 1
}

case "$MODE" in
  template)
    resolved="$(ns_catalog_template "$PLUGIN_ROOT" "$WORKSPACE" "$CATALOG")"
    printf '%s\n' "$resolved"
    [ -f "$resolved" ] && [ ! -L "$resolved" ] || exit 2
    exit 0
    ;;
  check)
    problems="$(ns_catalog_entry_problems "$ARG" "$NS_CAT_RULE" notes || true)"
    # A note says what the draft leaves to the owner; it never fails the check.
    printf '%s\n' "$problems" | sed -n "s|^note: |catalog-index: $ARG: |p"
    problems="$(printf '%s\n' "$problems" | grep -v '^note: ' || true)"
    if [ -n "$problems" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf 'catalog-index: %s: %s\n' "$ARG" "$line" >&2
      done <<EOF
$problems
EOF
      exit 1
    fi
    exit 0
    ;;
esac

[ -d "$PLUGIN_ROOT/$NS_CAT_SHIPPED" ] || {
  printf 'catalog-index: no catalog at %s\n' "$PLUGIN_ROOT/$NS_CAT_SHIPPED" >&2
  exit 2
}

if [ "$MODE" = path ]; then
  ns_catalog_file catalog-index "$PLUGIN_ROOT" "$CATALOG" "$WORKSPACE" "$ARG" || {
    printf 'catalog-index: %s holds no entry %s\n' "$CATALOG" "$ARG" >&2
    exit 2
  }
  printf '\n'
  exit 0
fi

# _shift_line <slug> <file> — slug, ending, title and summary. The summary is the H1's third part
# onward, or the first line of prose when the H1 has none.
_shift_line() {
  LC_ALL=C awk -v slug="$1" '
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
  ' "$2"
}

index_lines="$(_ns_catalog_index catalog-index "$PLUGIN_ROOT" "$CATALOG" "$WORKSPACE")"
if [ -z "$index_lines" ]; then
  printf 'catalog-index: the catalog holds no entries\n' >&2
  exit 2
fi
if [ "$CATALOG" = shifts ]; then
  # Split by hand: a tab is IFS whitespace, so read would collapse an empty column.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _shift_line "${line%%$'\t'*}" "${line##*$'\t'}"
  done <<EOF
$index_lines
EOF
else
  printf '%s\n' "$index_lines" | cut -f 1-5
fi
exit 0
