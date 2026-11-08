#!/usr/bin/env bash
# catalog-new.sh — start one catalog entry from the template in force.
#
#   catalog-new.sh --catalog NAME --key KEY [--user] [--project DIR] [--plugin-root DIR]
#
# Copies the template in force into the project folder (.nightshift/catalogs/<NAME>/), or with
# --user into the user folder (<user config>/nightshift/catalogs/<NAME>/), as <KEY>.md, and prints
# the new file's path. The owner fills its sections; catalog-index --check-draft names any that
# are missing. Refuses a key that is not lowercase words joined by hyphens, and a file that
# already exists: nothing is overwritten.
#
# Exit: 0 written · 1 usage · 2 refused
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.

PLUGIN_ROOT="$_here/.."
CATALOG=""
KEY=""
SCOPE=project
WORKSPACE=""
need_value() {
  [ "$2" -ge 2 ] || {
    printf 'catalog-new: %s needs a value\n' "$1" >&2
    exit 1
  }
}
while [ $# -gt 0 ]; do
  case "$1" in
    --catalog) need_value "$1" $#; CATALOG="$2"; shift 2 ;;
    --key) need_value "$1" $#; KEY="$2"; shift 2 ;;
    --user) SCOPE=user; shift ;;
    --project) need_value "$1" $#; WORKSPACE="$2"; shift 2 ;;
    --plugin-root) need_value "$1" $#; PLUGIN_ROOT="$2"; shift 2 ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *)
      printf 'catalog-new: unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done
[ -n "$CATALOG" ] && [ -n "$KEY" ] || {
  printf 'catalog-new: --catalog and --key are required\n' >&2
  exit 1
}

# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"
# shellcheck source=plugins/nightshift/lib/catalog-sources.sh
. "$_here/../lib/catalog-sources.sh"

ns_catalog_row "$CATALOG" || {
  printf 'catalog-new: unknown catalog: %s (one of: %s)\n' "$CATALOG" "$(ns_catalog_names | tr '\n' ' ' | sed 's/ $//')" >&2
  exit 1
}
case "$KEY" in
  '' | *[!a-z0-9-]* | -* | *- | *--*)
    printf 'catalog-new: %s is not a key: use lowercase words joined by hyphens\n' "$KEY" >&2
    exit 2
    ;;
esac

if [ "$SCOPE" = user ]; then
  dir="$(ns_catalog_user_root)/catalogs/$CATALOG"
else
  [ -n "$WORKSPACE" ] || {
    printf 'catalog-new: --project is required for a project entry; pass --user for every project\n' >&2
    exit 1
  }
  dir="$(ns_layout_path "$WORKSPACE/.nightshift" "catalog-$CATALOG")" || {
    printf 'catalog-new: cannot resolve the %s folder under %s/.nightshift\n' "$CATALOG" "$WORKSPACE" >&2
    exit 2
  }
fi

template="$(ns_catalog_template "$PLUGIN_ROOT" "$WORKSPACE" "$CATALOG")"
[ -f "$template" ] && [ ! -L "$template" ] || {
  printf 'catalog-new: no template at %s\n' "$template" >&2
  exit 2
}
target="$dir/$KEY.md"
if [ -e "$target" ] || [ -L "$target" ]; then
  printf 'catalog-new: %s already exists\n' "$target" >&2
  exit 2
fi
mkdir -p "$dir" || {
  printf 'catalog-new: cannot create %s\n' "$dir" >&2
  exit 2
}
cp "$template" "$target" || {
  printf 'catalog-new: cannot write %s\n' "$target" >&2
  exit 2
}
printf '%s\n' "$target"
exit 0
