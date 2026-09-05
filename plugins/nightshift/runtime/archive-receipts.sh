#!/usr/bin/env bash
# archive-receipts.sh — copy the live receipts into a dated archive folder.
#
# Every regular file directly under receipts/ travels: the artifact receipts an item wrote and
# the shift's own morning-<YYYY-MM-DD>-<shiftId>.md, or morning-<YYYY-MM-DD>.md when the shift
# wrote no policy to take an id from.
# Leaves live copies in place so stall progress still sees them. Skips hidden
# files and does not follow symlinks. Missing or empty receipts is success and
# does not create an empty dated folder.
# Archive-only. Hooks, start, status, Doctor, and recovery must never invoke this.
#
#   archive-receipts.sh [--project DIR] [--date YYYY-MM-DD]
#
# Exit: 0 copied or nothing to copy · 1 usage · 2 refused
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
DATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'archive-receipts: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --date)
      [ $# -ge 2 ] || { printf 'archive-receipts: --date needs a value\n' >&2; exit 1; }
      DATE="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'archive-receipts: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'archive-receipts: cannot cd to %s\n' "$PROJECT" >&2
  exit 1
}

WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" || {
    printf 'archive-receipts: invalid .nightshift-link — Nightshift will not guess a workspace\n' >&2
    exit 2
  }
fi

KIND="$(ns_state_kind "$WORKSPACE")"
case "$KIND" in
  malformed | future)
    printf 'archive-receipts: %s\n' "$(ns_state_refuse_message "$KIND")" >&2
    exit 2
    ;;
  absent)
    printf 'archive-receipts: no .nightshift/ at %s\n' "$WORKSPACE" >&2
    exit 2
    ;;
esac

NS="$WORKSPACE/.nightshift"
if [ -z "$DATE" ]; then
  DATE="$(date +%Y-%m-%d)"
fi
case "$DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) printf 'archive-receipts: --date must be YYYY-MM-DD\n' >&2; exit 1 ;;
esac

src="$(ns_receipts_dir "$WORKSPACE")"
# Where a shift is filed is the owner's, inside the state area. A root that would climb out of it,
# or reach through a symlink, is refused rather than followed.
if ! root="$(ns_archive_root "$WORKSPACE")"; then
  printf 'archive-receipts: archive.root must name a directory inside .nightshift/ — an absolute path, a path with .., or a symlink is not supported\n' >&2
  exit 2
fi
shift_id="$(ns_policy_shift_id "$WORKSPACE" 2>/dev/null)" || shift_id=""
if ! group="$(ns_archive_dir "$WORKSPACE" "$DATE" "$shift_id")"; then
  printf 'archive-receipts: archive.root must name a directory inside .nightshift/\n' >&2
  exit 2
fi
dest="$group/receipts"
if [ -L "$src" ]; then
  printf 'archive-receipts: refuse to write through a symlink receipts path\n' >&2
  exit 2
fi
if [ -e "$src" ] && [ ! -d "$src" ]; then
  printf 'archive-receipts: receipts path is not a directory\n' >&2
  exit 2
fi
if [ -L "$root" ] || [ -L "$group" ] || [ -L "$dest" ]; then
  printf 'archive-receipts: refuse to write through a symlink archive path\n' >&2
  exit 2
fi
if { [ -e "$root" ] && [ ! -d "$root" ]; } \
  || { [ -e "$group" ] && [ ! -d "$group" ]; } \
  || { [ -e "$dest" ] && [ ! -d "$dest" ]; }; then
  printf 'archive-receipts: refuse to write through a non-directory archive path\n' >&2
  exit 2
fi

copied=0
if [ -d "$src" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    base="${f##*/}"
    case "$base" in
      .* | '') continue ;;
    esac
    if [ "$copied" -eq 0 ]; then
      mkdir -p "$dest" || {
        printf 'archive-receipts: cannot create %s\n' "$dest" >&2
        exit 2
      }
      if [ -L "$dest" ]; then
        printf 'archive-receipts: refuse to write through a symlink archive path\n' >&2
        exit 2
      fi
    fi
    cp "$f" "$dest/$base" || {
      printf 'archive-receipts: failed to copy %s\n' "$base" >&2
      exit 2
    }
    copied=$((copied + 1))
  done <<FIND
$(find "$src" -maxdepth 1 -type f ! -name '.*' 2>/dev/null)
FIND
fi

if [ "$copied" -eq 0 ]; then
  exit 0
fi
printf '%s\n' "$dest"
exit 0
