#!/usr/bin/env bash
# scaffold.sh — copy the state templates into the workspace, never over an existing file.
#
#   scaffold.sh --project <ws> [--list]
#
# Copying a file does not require its text: the model reads none of the nine templates, and what
# that saves in context it also saves in fidelity — a copy cannot paraphrase.
#
# Never clobbers. A file already in `.nightshift/` is the owner's, whatever it now contains, so an
# existing name is reported `kept` and left exactly as it is. Running this twice is safe, and that
# is what makes it usable as a repair.
#
# The copy resolves `$NIGHTSHIFT_WORKSPACE` and `$NS` to the paths this workspace actually has,
# because the owner reads their copy and a person cannot paste a shell variable they do not have.
# The shipped template is never changed.
#
# Prints one line per template: `wrote <name>` or `kept <name>`.
# Exit: 0 done · 1 usage · 2 refused
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
_here="$(cd -P "$_here" && pwd)" || exit 2
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
LIST=no
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
    *) printf 'scaffold: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

TEMPLATES="$_here/../skills/nightshift/references/templates"
[ -d "$TEMPLATES" ] || {
  printf 'scaffold: no templates at %s\n' "$TEMPLATES" >&2
  exit 2
}

if [ "$LIST" = yes ]; then
  for f in "$TEMPLATES"/*.md; do
    [ -f "$f" ] || continue
    printf '%s\n' "${f##*/}"
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
mkdir -p "$NS" 2>/dev/null || {
  printf 'scaffold: cannot create %s\n' "$NS" >&2
  exit 2
}

for f in "$TEMPLATES"/*.md; do
  [ -f "$f" ] || continue
  name="${f##*/}"
  dest="$NS/$name"
  # A name that is already taken is the owner's, whatever it holds and whatever kind of file it is.
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    printf 'kept %s\n' "$name"
    continue
  fi
  # The owner's copy carries resolved paths: a person pasting a command out of their own punch
  # list has no `$NS`. The shipped template is never changed.
  if sed -e "s|\$NIGHTSHIFT_WORKSPACE|$WORKSPACE|g" -e "s|\$NS|$NS|g" "$f" >"$dest" 2>/dev/null; then
    printf 'wrote %s\n' "$name"
  else
    rm -f "$dest" 2>/dev/null || :
    printf 'scaffold: cannot write %s\n' "$dest" >&2
    exit 2
  fi
done
exit 0
