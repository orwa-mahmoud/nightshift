#!/usr/bin/env bash
# scaffold.sh — copy the state templates into the workspace, never over an existing file.
#
#   scaffold.sh --project <ws> [--list] [<file>...]
#
# With no file named it writes what every shift uses: the punch list, the parking lot, the snag
# log, the drafting table, and the shift log's header. The rest waits until something needs it:
# `work-orders` when Hunt stages an order, `product` (the opportunity map and the research notes)
# when a product-evolution item is cut. Each file lands where the workspace's layout keeps it,
# and a `.nightshift/` this run creates gets the current state-version first.
#
# Copying a file does not require its text: the model reads none of the templates, and what that
# saves in context it also saves in fidelity — a copy cannot paraphrase.
#
# Never clobbers. A file already in `.nightshift/` is the owner's, whatever it now contains, so an
# existing name is reported `kept` and left exactly as it is. Running this twice is safe, and that
# is what makes it usable as a repair.
#
# The copy resolves `$NIGHTSHIFT_WORKSPACE` and `$NS` to the paths this workspace actually has,
# because the owner reads their copy and a person cannot paste a shell variable they do not have.
# The shipped template is never changed.
#
# Prints one line per file: `wrote <path>` or `kept <path>`, relative to `.nightshift/`.
# Exit: 0 done · 1 usage · 2 refused
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
_here="$(cd -P "$_here" && pwd)" || exit 2
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
LIST=no
NAMES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'scaffold: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --list)
      LIST=yes
      shift
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    work-orders | opportunity-map | product-research)
      NAMES="$NAMES $1"
      shift
      ;;
    product)
      NAMES="$NAMES opportunity-map product-research"
      shift
      ;;
    -*) printf 'scaffold: unknown argument: %s\n' "$1" >&2; exit 1 ;;
    *) printf 'scaffold: %s is not a file scaffold writes on request (work-orders, product)\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$NAMES" ] || NAMES="punch-list parking-lot snag-log drafting-table"

TEMPLATES="$_here/../skills/nightshift/references/templates"
[ -d "$TEMPLATES" ] || {
  printf 'scaffold: no templates at %s\n' "$TEMPLATES" >&2
  exit 2
}

if [ "$LIST" = yes ]; then
  for key in punch-list parking-lot snag-log drafting-table work-orders opportunity-map product-research; do
    [ -f "$TEMPLATES/$key.md" ] && printf '%s.md\n' "$key"
  done
  exit 0
fi

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'scaffold: cannot cd to %s\n' "$PROJECT" >&2
  exit 1
}
WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" || {
    printf 'scaffold: invalid .nightshift-link — Nightshift will not guess a workspace\n' >&2
    exit 2
  }
fi
NS="$WORKSPACE/.nightshift"
ns_state_dir_ensure "$WORKSPACE" 2>/dev/null || {
  printf 'scaffold: cannot create %s\n' "$NS" >&2
  exit 2
}

# write <key> <template|line> <source> — one file, copied from a template or holding one line,
# unless the name is taken.
write() {
  local key="$1" kind="$2" src="$3" dest rel ok
  ns_layout_set dest "$NS" "$key" || return 0
  ns_layout_rel_set rel "$NS" "$key"
  # A name that is already taken is the owner's, whatever it holds and whatever kind of file it is.
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    printf 'kept %s\n' "$rel"
    return 0
  fi
  mkdir -p "${dest%/*}" 2>/dev/null || {
    printf 'scaffold: cannot create %s\n' "${dest%/*}" >&2
    exit 2
  }
  # The owner's copy carries resolved paths: a person pasting a command out of their own punch
  # list has no `$NS`. The shipped template is never changed.
  ok=0
  if [ "$kind" = template ]; then
    sed -e "s|\$NIGHTSHIFT_WORKSPACE|$WORKSPACE|g" -e "s|\$NS|$NS|g" "$src" >"$dest" 2>/dev/null && ok=1
  else
    printf '%s\n' "$src" >"$dest" 2>/dev/null && ok=1
  fi
  if [ "$ok" -eq 1 ]; then
    printf 'wrote %s\n' "$rel"
  else
    rm -f "$dest" 2>/dev/null || :
    printf 'scaffold: cannot write %s\n' "$dest" >&2
    exit 2
  fi
}

for key in $NAMES; do
  [ -f "$TEMPLATES/$key.md" ] || {
    printf 'scaffold: no template for %s\n' "$key" >&2
    exit 2
  }
  write "$key" template "$TEMPLATES/$key.md"
done
case " $NAMES " in
  *" punch-list "*)
    write shift-log line '# Shift Log'
    # The runtime's markers land beside the shift log from the first arming on.
    ns_layout_parent "$NS" armed || :
    ;;
esac
exit 0
