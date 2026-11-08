#!/usr/bin/env bash
# catalog-index.sh — what a catalog holds, one line per entry.
#
#   catalog-index.sh [--plugin-root DIR] [--catalog shifts|evidence|gates|edge-cases]
#                    [--project DIR] [--template] [--check-draft FILE]
#
# shifts, the default, reads references/compose/shifts and prints slug, ending, title and summary.
# --project is accepted and ignored for shifts, so a caller that passes the workspace does not
# change that listing. evidence and gates read the shipped files, the project folder, the user
# folder, and the folders named in the rules file, and print key, title, description, source and
# the sources a same key replaced. gates prints that list in match order. --template prints the
# template in force. --check-draft FILE checks one draft and names each required section it lacks.
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

case "$CATALOG" in
  evidence)
    NS_CATALOG_HEADINGS='When it applies|Evidence lines|How to generate|How to verify|Never'
    NS_CATALOG_BULLET='Evidence lines'
    NS_CATALOG_FENCE='evidence-check'
    NS_CATALOG_FENCE_KEYS='files min type'
    NS_CATALOG_FENCE_TYPES='image text json any'
    NS_CATALOG_MATCH=
    template_rel='skills/nightshift/references/templates/evidence-kind.md'
    plugin_rel='skills/nightshift/references/evidence/kinds'
    layout_key='evidence-kinds'
    user_catalog=evidence
    user_entries=kinds
    template_group=receipts
    template_field=evidence.kindTemplatePath
    paths_group=receipts
    paths_field=evidence.kindsPaths
    paths_label=kindsPaths
    list_order=alpha
    ;;
  gates)
    NS_CATALOG_HEADINGS='Detect|Item gate|Site inspection|Notes'
    NS_CATALOG_BULLET=
    NS_CATALOG_FENCE=
    NS_CATALOG_FENCE_KEYS=
    NS_CATALOG_FENCE_TYPES=
    NS_CATALOG_MATCH=yes
    template_rel='skills/nightshift/references/templates/gates-stack.md'
    plugin_rel='skills/nightshift/references/compose/gates'
    layout_key='gates-stacks'
    user_catalog=gates
    user_entries=stacks
    template_group=gates
    template_field=stackTemplatePath
    paths_group=gates
    paths_field=stacksPaths
    paths_label=stacksPaths
    list_order=match
    ;;
  edge-cases)
    NS_CATALOG_HEADINGS='When it applies|Cases|Example lines'
    NS_CATALOG_BULLET='Example lines'
    NS_CATALOG_FENCE=
    NS_CATALOG_FENCE_KEYS=
    NS_CATALOG_FENCE_TYPES=
    NS_CATALOG_MATCH=
    template_rel='skills/nightshift/references/templates/edge-case-pack.md'
    plugin_rel='skills/nightshift/references/plan/edge-cases'
    layout_key='edge-case-packs'
    user_catalog='edge-cases'
    user_entries=packs
    template_group=edgeCases
    template_field=packTemplatePath
    paths_group=edgeCases
    paths_field=packsPaths
    paths_label=packsPaths
    list_order=alpha
    ;;
  *)
    printf 'catalog-index: unknown catalog: %s\n' "$CATALOG" >&2
    exit 1
    ;;
esac

# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"
# shellcheck source=plugins/nightshift/lib/catalog-sources.sh
. "$_here/../lib/catalog-sources.sh"

shipped="$PLUGIN_ROOT/$template_rel"
template_setting=""
paths_raw=""
if [ -n "$WORKSPACE" ]; then
  template_setting="$(ns_policy_pref "$WORKSPACE" "$template_group" "$template_field" 2>/dev/null || true)"
  paths_raw="$(ns_policy_pref "$WORKSPACE" "$paths_group" "$paths_field" 2>/dev/null || true)"
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

plugin_dir="$PLUGIN_ROOT/$plugin_rel"
[ -d "$plugin_dir" ] || {
  printf 'catalog-index: no catalog at %s\n' "$plugin_dir" >&2
  exit 2
}

project_dir=""
if [ -n "$WORKSPACE" ]; then
  project_dir="$(ns_layout_path "$WORKSPACE/.nightshift" "$layout_key" 2>/dev/null || true)"
fi
user_dir="$(ns_catalog_user_dir "$user_catalog" "$user_entries")"

pairs_file="$(mktemp "${TMPDIR:-/tmp}/ns-catalog-pairs.XXXXXX")" || exit 1
trap 'rm -f "$pairs_file"' EXIT
set --
if [ -n "$paths_raw" ] && [ "$paths_raw" != null ]; then
  if ! parsed="$(ns_json_string_list "$paths_raw")"; then
    printf 'catalog-index: %s could not be read\n' "$paths_label" >&2
  else
    while IFS= read -r raw; do
      [ -n "$raw" ] || continue
      resolved="$(ns_catalog_resolve "$WORKSPACE" "$raw")"
      printf '%s\t%s\n' "$raw" "$resolved" >>"$pairs_file"
      set -- "$@" "$raw" "$resolved"
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
# Print each index line prefixed by its match rank and key, so sort can order stacks
# without a second registry. A case statement here stays outside the command substitution
# that captures the result.
_ns_gates_rank_lines() {
  local line key source file rank match lab dir
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%$'\t'*}"
    source="$(printf '%s' "$line" | awk -F '\t' '{ print $4 }')"
    case "$source" in
      plugin) file="$plugin_dir/$key.md" ;;
      project) file="$project_dir/$key.md" ;;
      user) file="$user_dir/$key.md" ;;
      *)
        file=""
        while IFS= read -r lab; do
          dir="${lab#*$'\t'}"
          lab="${lab%%$'\t'*}"
          [ "$lab" = "$source" ] || continue
          file="$dir/$key.md"
          break
        done <"$pairs_file"
        ;;
    esac
    rank=0
    if [ -n "$file" ] && [ -f "$file" ]; then
      match="$(awk '/^Match:[[:space:]]*/ { sub(/^Match:[[:space:]]*/, ""); print; exit }' "$file")"
      case "$match" in
        plugin) rank=1 ;;
        fallback) rank=2 ;;
      esac
    fi
    printf '%s\t%s\t%s\n' "$rank" "$key" "$line"
  done
}

if [ "$list_order" = match ]; then
  listed="$(printf '%s\n' "$listed" | _ns_gates_rank_lines | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 | cut -f 3-)"
fi
printf '%s\n' "$listed"
exit 0
