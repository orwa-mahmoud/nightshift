#!/usr/bin/env bash
# archive-receipts.sh — copy the live receipts into a dated archive folder.
#
# Every regular file directly under receipts/ travels: the artifact receipts an item wrote and
# the shift's own morning-<YYYY-MM-DD>-<shiftId>.md, or morning-<YYYY-MM-DD>.md when the shift
# wrote no policy to take an id from. The shift report travels with them.
#
# Filing is a copy. Nothing leaves live storage unless it is named: an ended shift can still hold
# an item nobody finished, and the baseline that item links to is needed exactly where it is. So
# the caller says which records are closed and this retires those, having read each archived copy
# back and found it identical. A name it did not file, or one whose copy does not match, is
# refused by name and its source stays. While a shift is armed nothing is retired at all.
#
# Two different records under one name never overwrite each other: the filed one stands and the
# live one is kept. Skips hidden files and does not follow symlinks. Missing or empty receipts is
# success and does not create an empty dated folder.
# Archive-only. Hooks, start, status, Doctor, and recovery must never invoke this.
#
#   archive-receipts.sh [--project DIR] [--date YYYY-MM-DD] [--retire NAME]...
#
#   --retire NAME   a record established as closed, by file name. Repeatable. Without any, this
#                   copies and retires nothing.
#
# Exit: 0 copied or nothing to copy · 1 usage · 2 refused
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
DATE=""
RETIRE=""
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
    --retire)
      [ $# -ge 2 ] || { printf 'archive-receipts: --retire needs a value\n' >&2; exit 1; }
      case "$2" in
        '' | */* | .*) printf 'archive-receipts: --retire takes a record name, not a path: %s\n' "$2" >&2; exit 1 ;;
      esac
      RETIRE="$RETIRE$2
"
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

# A closed record leaves live storage only when a shift has actually ended and the archived copy
# has been read back and matches. While a shift is armed nothing is removed at all: its receipts
# are what its own progress checks read, and a half-filed night is worse than an unfiled one.
ARMED=0
{ [ -e "$NS/.shift-armed" ] || [ -L "$NS/.shift-armed" ]; } && ARMED=1
ENDED=0
{ [ -f "$NS/.ended" ] && [ ! -L "$NS/.ended" ]; } && ENDED=1
ROTATE=0
[ "$ARMED" -eq 0 ] && [ "$ENDED" -eq 1 ] && ROTATE=1
if [ "$ROTATE" -eq 0 ] && [ -n "$RETIRE" ]; then
  if [ "$ARMED" -eq 1 ]; then
    printf 'archive-receipts: refuse to retire anything while the shift is armed\n' >&2
  else
    printf 'archive-receipts: refuse to retire anything before the shift has ended\n' >&2
  fi
  exit 2
fi

# retire_named <name> — status 0 when the caller named this record as closed.
retire_named() {
  case "
$RETIRE" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

# The names actually filed, so a --retire the run never copied is refused rather than ignored.
FILED=""
ARCHIVED_PATHS=""

# same_bytes <a> <b> — the archived copy is read back and compared, so a copy that silently
# truncated or landed on another filesystem is never mistaken for a safe one.
same_bytes() {
  [ -f "$1" ] && [ -f "$2" ] || return 1
  cmp -s "$1" "$2"
}

copied=0
removed=0
kept=""
ensure_dest() {
  mkdir -p "$dest" || {
    printf 'archive-receipts: cannot create %s\n' "$dest" >&2
    exit 2
  }
  if [ -L "$dest" ]; then
    printf 'archive-receipts: refuse to write through a symlink archive path\n' >&2
    exit 2
  fi
}

# file_one <path> — copy one record, verify it, and retire the source when this shift is closed.
file_one() {
  local f="$1" base
  base="${f##*/}"
  case "$base" in
    .* | '') return 0 ;;
  esac
  ensure_dest
  # The leaf is checked too. A link left where this record is about to land would carry its bytes
  # somewhere else and then read back as a faithful copy, so the source stays put instead.
  if ! ns_archive_dest "$dest/$base"; then
    kept="$kept$base (a link or a directory is in the way of its archived copy)
"
    return 0
  fi
  if [ -e "$dest/$base" ]; then
    if same_bytes "$f" "$dest/$base"; then
      : # already filed, byte for byte — retiring the source below is safe
    else
      # Two different records under one name. Neither is worth losing, so the one already
      # filed stands and the live one stays exactly where it is.
      kept="$kept$base (a different record is already filed under that name)
"
      return 0
    fi
  else
    cp "$f" "$dest/$base" || {
      printf 'archive-receipts: failed to copy %s\n' "$base" >&2
      exit 2
    }
    copied=$((copied + 1))
  fi
  if ! same_bytes "$f" "$dest/$base"; then
    kept="$kept$base (the archived copy does not match the source)
"
    return 0
  fi
  FILED="$FILED$base
"
  ARCHIVED_PATHS="$ARCHIVED_PATHS${f#"$NS"/}
"
  # A verified copy makes retiring safe; it does not make it right. Only a record the caller
  # established as closed leaves, so an ended shift still holding open work keeps what that work
  # needs — and an old .ended marker beside a freshly drafted report retires neither.
  if [ "$ROTATE" -eq 1 ] && retire_named "$base"; then
    rm -f "$f" || {
      kept="$kept$base (could not be removed from live storage)
"
      return 0
    }
    removed=$((removed + 1))
  fi
}

if [ -d "$src" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    file_one "$f"
  done <<FIND
$(find "$src" -maxdepth 1 -type f ! -name '.*' 2>/dev/null)
FIND
fi

# The shift report travels with the receipts it describes.
report="$(ns_report_path "$WORKSPACE")"
report_base=""
report_relocated=0
if [ -f "$report" ] && [ ! -L "$report" ]; then
  report_base="${report##*/}"
  report_original="$group/${report_base%.md}.original.md"
  if [ -f "$report_original" ] && [ ! -L "$report_original" ] && same_bytes "$report" "$report_original"; then
    # Filed already, on a run that relocated its links. The archived page differs from the source
    # by design, so the preserved original is what says whether this is the same report.
    FILED="$FILED$report_base
"
    report_relocated=1
    if [ "$ROTATE" -eq 1 ] && retire_named "$report_base"; then
      if rm -f "$report"; then
        removed=$((removed + 1))
      else
        kept="$kept$report_base (could not be removed from live storage)
"
      fi
    fi
  else
    src_dir="$dest"
    dest="$group"
    file_one "$report"
    dest="$src_dir"
  fi
fi

# The report is the shift's reading entry point, so its links have to keep working from where it
# now sits. A record that travelled with it is still a sibling and its link is already right; one
# that stayed live — a parking decision nobody has answered, a snag log the next shift adds to —
# is now further away, and the link has to say so.
#
# Rewriting changes bytes, so the untouched original is kept beside the relocated view rather than
# replaced by it. Evidence stays evidence; the page you open is the one that navigates.
if [ -n "$report_base" ] && [ "$report_relocated" -eq 0 ] &&
  [ -f "$group/$report_base" ] && [ ! -L "$group/$report_base" ]; then
  back=""
  rel="${group#"$NS"/}"
  saved_ifs="$IFS"
  IFS=/
  # shellcheck disable=SC2086 # splitting the relative path into components is the point
  set -- $rel
  IFS="$saved_ifs"
  for _ in "$@"; do back="../$back"; done
  awk_bin="$(ns_rules_awk_bin)" || awk_bin="awk"
  if NS_ARCHIVED_PATHS="$ARCHIVED_PATHS" "$awk_bin" -v back="$back" \
    -f "$_here/archive-links.awk" <"$group/$report_base" >"$group/.$report_base.relocated" 2>/dev/null; then
    if cmp -s "$group/$report_base" "$group/.$report_base.relocated"; then
      rm -f "$group/.$report_base.relocated"
    else
      original="${report_base%.md}.original.md"
      if ns_archive_dest "$group/$original" && cp "$group/$report_base" "$group/$original"; then
        mv "$group/.$report_base.relocated" "$group/$report_base" || rm -f "$group/.$report_base.relocated"
      else
        rm -f "$group/.$report_base.relocated"
        kept="$kept$report_base (its links were left as written: the original could not be preserved beside a relocated view)
"
      fi
    fi
  else
    rm -f "$group/.$report_base.relocated"
    kept="$kept$report_base (its links were left as written)
"
  fi
fi

unmatched=""
while IFS= read -r wanted; do
  [ -n "$wanted" ] || continue
  case "
$FILED" in
    *"
$wanted
"*) continue ;;
  esac
  unmatched="$unmatched  $wanted
"
done <<RETIRE_NAMES
$RETIRE
RETIRE_NAMES
if [ -n "$unmatched" ]; then
  printf 'archive-receipts: refused to retire — this run filed no such record:\n' >&2
  printf '%s' "$unmatched" >&2
fi

if [ -n "$kept" ]; then
  printf 'archive-receipts: kept in live storage:\n' >&2
  printf '%s' "$kept" >&2
fi

if [ "$copied" -eq 0 ] && [ "$removed" -eq 0 ]; then
  exit 0
fi
printf '%s\n' "$dest"
[ "$removed" -eq 0 ] || printf 'archive-receipts: retired %s closed record(s) from live storage\n' "$removed"
exit 0
