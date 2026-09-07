#!/usr/bin/env bash
# catalog-index.sh — what the shift catalog holds, one line per entry.
#
#   catalog-index.sh [--plugin-root DIR]
#
# Every entry already opens with `# <title> — <ending> — <what it is for>` and a line or two of
# prose. That header is the metadata, so there is no second registry to keep in step: a new entry
# is discovered the moment its file exists, and one that is deleted stops being offered.
#
# Prints, tab-separated: slug, ending, title, summary. Reads the catalog and nothing else, writes
# nothing, and decides nothing — which entry suits an objective is the model's judgement, not a
# score this helper computes.
#
# Exit: 0 listed · 1 usage · 2 no catalog to read
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.

PLUGIN_ROOT="$_here/.."
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
    # The H1 carries the title, the ending and the one-line purpose, in that order.
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
    # The first prose line after it fills in a purpose the header did not spell out.
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
