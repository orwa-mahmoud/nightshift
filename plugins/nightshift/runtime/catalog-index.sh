#!/usr/bin/env bash
# catalog-index.sh — what a catalog holds, one line per entry.
#
#   catalog-index.sh [--plugin-root DIR] [--catalog shifts|evidence]
#
# shifts, the default, reads references/compose/shifts and prints slug, ending, title and summary.
# evidence reads references/evidence/kinds and prints key, title and description. Callers that pass
# no catalog keep the shift listing, unchanged.
#
# Every entry opens with an H1, and that header is the metadata, so there is no second registry
# to keep in step: a new file is listed the moment it exists, and one that is deleted stops being
# listed. A symlink is skipped.
#
# Reads the catalog and nothing else, writes nothing, and decides nothing — which entry suits an
# item is the model's judgement, not a score this helper computes.
#
# Exit: 0 listed · 1 usage · 2 no catalog to read
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.

PLUGIN_ROOT="$_here/.."
CATALOG="shifts"
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

case "$CATALOG" in
  shifts)
    DIR="$PLUGIN_ROOT/skills/nightshift/references/compose/shifts"
    mode="shift"
    ;;
  evidence)
    DIR="$PLUGIN_ROOT/skills/nightshift/references/evidence/kinds"
    mode="kind"
    ;;
  *)
    printf 'catalog-index: unknown catalog: %s\n' "$CATALOG" >&2
    exit 1
    ;;
esac

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
  LC_ALL=C awk -v slug="${base%.md}" -v mode="$mode" '
    # The H1 is the metadata. A shift carries title, ending and purpose. A kind carries title
    # and the one-line description of the items it fits. The split is the same em dash.
    /^# / && !seen {
      seen = 1
      line = substr($0, 3)
      n = split(line, part, " \xe2\x80\x94 ")
      title = part[1]
      if (mode == "kind") {
        description = ""
        for (i = 2; i <= n; i++) {
          description = description (i == 2 ? "" : " \xe2\x80\x94 ") part[i]
        }
      } else {
        ending = (n >= 2) ? part[2] : ""
        summary = ""
        for (i = 3; i <= n; i++) {
          summary = summary (summary == "" ? "" : " - ") part[i]
        }
      }
      next
    }
    # The first prose line after it fills in a purpose the shift header did not spell out.
    seen && mode == "shift" && summary == "" && /^[^#[:space:]]/ {
      summary = $0
    }
    END {
      gsub(/\t/, " ", title)
      if (mode == "kind") {
        gsub(/\t/, " ", description)
        printf "%s\t%s\t%s\n", slug, title, description
      } else {
        gsub(/\t/, " ", ending)
        gsub(/\t/, " ", summary)
        printf "%s\t%s\t%s\t%s\n", slug, ending, title, summary
      }
    }
  ' "$f"
done

[ "$found" -eq 1 ] || {
  printf 'catalog-index: the catalog holds no entries\n' >&2
  exit 2
}
exit 0
