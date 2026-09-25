#!/usr/bin/env bash
# archive-receipts.sh — file a shift into its archive folder, laid out the way it was live.
#
# The folder holds the shift's records at the paths they have under .nightshift/: the punch list,
# receipts/ with its index and the morning page, the parking lot and the snag log where the
# workspace keeps them (inbox/), and the shift log, the usage readings and the policy where the
# runtime keeps them (run/). Links between those records keep working as written. A link to one
# that stays live is repointed back to it, and the untouched original is kept beside the repointed
# page as <name>.original.md.
#
# Filing is a copy: each record is filed as it stands, and then the live side keeps only what is
# still open. The punch list keeps its contract and its open items, receipts/ keeps the receipts of
# open items, and the parking lot and snag log keep the entries with no disposition, plus one
# Filed: pointer to the filed copy. Once the shift has ended, its shift log moves and starts again,
# its usage readings and a policy of that shift still live move too, and a usage-<id>/ folder the
# Start preflight retired moves into the folder of the shift it belongs to. While a shift is armed,
# or before it has ended, nothing leaves live storage. A leftover shift report leaves only when
# named.
#
# Two different records under one name never overwrite each other: the filed one stands and the
# live one is kept. Skips hidden files and does not follow symlinks. Missing or empty receipts is
# success and creates no receipts folder.
# Archive-only. Hooks, start, status, Doctor, and recovery must never invoke this.
#
#   archive-receipts.sh [--project DIR] [--date YYYY-MM-DD] [--retire NAME]...
#
#   --retire NAME   a record established as closed, by file name. Repeatable. On an ended shift the
#                   receipts of ticked items and the shift's own records leave without a name; an
#                   open item's receipt never does.
#
# Exit: 0 filed or nothing to file · 1 usage · 2 refused
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
declare ARMED_FILE ENDED_FILE USAGE_DIR USAGE_PREFIX POLICY_FILE RECEIPTS_REL USAGE_REL POLICY_REL JOURNAL_REL PUNCH_REL
urel=""
krel=""
ns_layout_set ARMED_FILE "$NS" armed
ns_layout_set ENDED_FILE "$NS" ended
ns_layout_set USAGE_DIR "$NS" usage
ns_layout_set USAGE_PREFIX "$NS" usage-shift ""
ns_layout_set POLICY_FILE "$NS" shift-policy
ns_layout_rel_set RECEIPTS_REL "$NS" receipts
ns_layout_rel_set USAGE_REL "$NS" usage
ns_layout_rel_set POLICY_REL "$NS" shift-policy
ns_layout_rel_set JOURNAL_REL "$NS" shift-log
ns_layout_rel_set PUNCH_REL "$NS" punch-list
if [ -z "$DATE" ]; then
  DATE="$(date +%Y-%m-%d)"
fi
case "$DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) printf 'archive-receipts: --date must be YYYY-MM-DD\n' >&2; exit 1 ;;
esac

# A closed record leaves live storage only when a shift has actually ended and the archived copy
# has been read back and matches. While a shift is armed nothing is removed at all: its receipts
# are what its own progress checks read, and a half-filed night is worse than an unfiled one.
ARMED=0
{ [ -e "$ARMED_FILE" ] || [ -L "$ARMED_FILE" ]; } && ARMED=1
ENDED=0
{ [ -f "$ENDED_FILE" ] && [ ! -L "$ENDED_FILE" ]; } && ENDED=1
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

src="$(ns_receipts_dir "$WORKSPACE")"
# Where a shift is filed is the owner's, inside the state area. A root that would climb out of it,
# or reach through a symlink, is refused rather than followed.
if ! root="$(ns_archive_root "$WORKSPACE")"; then
  printf 'archive-receipts: archive.root must name a directory inside .nightshift/ — an absolute path, a path with .., or a symlink is not supported\n' >&2
  exit 2
fi
# Whose records these are. Once the shift has ended, the ending marker says which shift that was,
# even when a policy for the next one is already live; before then the live policy answers.
policy_id="$(ns_policy_shift_id "$WORKSPACE" 2>/dev/null)" || policy_id=""
ended_id="$(ns_ended_field "$WORKSPACE" shiftId)"
shift_id="$policy_id"
if [ "$ROTATE" -eq 1 ] && [ -n "$ended_id" ]; then
  shift_id="$ended_id"
elif [ -z "$shift_id" ] || [ "$shift_id" = unknown ]; then
  [ -z "$ended_id" ] || shift_id="$ended_id"
fi
if ! group="$(ns_archive_group "$WORKSPACE" "$DATE" "$shift_id")"; then
  printf 'archive-receipts: archive.root must name a directory inside .nightshift/\n' >&2
  exit 2
fi
dest="$group/$RECEIPTS_REL"
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

# The receipts of items nobody finished. They are filed as they stand and stay live, exactly as the
# box stays in the punch list, so the next shift extends the same file rather than a copy of it.
OPEN_NAMES="$(ns_receipts_open_names "$WORKSPACE")
"
TICKED_NAMES="$(ns_receipts_ticked_names "$WORKSPACE")
"

# in_list <name> <list> — status 0 when the newline-separated list holds that name.
in_list() {
  case "
$2" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

# The names actually filed, so a --retire the run never copied is refused rather than ignored.
FILED=""
copied=0
removed=0
kept=""
filed_lines=""

# ensure_dir <dir> — create a folder inside the shift's folder, refusing one reached through a link.
ensure_dir() {
  mkdir -p "$1" || {
    printf 'archive-receipts: cannot create %s\n' "$1" >&2
    exit 2
  }
  if [ -L "$1" ]; then
    printf 'archive-receipts: refuse to write through a symlink archive path\n' >&2
    exit 2
  fi
}

# file_one <path> <dir> <keep|closed|own> — copy one record into dir, verify it, and retire the
# source when the shift has ended: `closed` when it was named or its item is ticked, `own` always,
# `keep` never. FILE_ONE_FILED says whether the record now has a verified archived copy.
FILE_ONE_FILED=0
file_one() {
  local f="$1" dir="$2" rule="$3" base
  FILE_ONE_FILED=0
  base="${f##*/}"
  case "$base" in
    .* | '') return 0 ;;
  esac
  ensure_dir "$dir"
  # The leaf is checked too. A link left where this record is about to land would carry its bytes
  # somewhere else and then read back as a faithful copy, so the source stays put instead.
  if ! ns_archive_dest "$dir/$base"; then
    kept="$kept$base (a link or a directory is in the way of its archived copy)
"
    return 0
  fi
  if [ -e "$dir/$base" ]; then
    if ! ns_archive_same "$f" "$dir/$base"; then
      # Two different records under one name. Neither is worth losing, so the one already filed
      # stands and the live one stays exactly where it is.
      kept="$kept$base (a different record is already filed under that name)
"
      return 0
    fi
  else
    cp "$f" "$dir/$base" || {
      printf 'archive-receipts: failed to copy %s\n' "$base" >&2
      exit 2
    }
    copied=$((copied + 1))
    if ! cmp -s "$f" "$dir/$base"; then
      kept="$kept$base (the archived copy does not match the source)
"
      return 0
    fi
  fi
  FILED="$FILED$base
"
  FILE_ONE_FILED=1
  [ "$ROTATE" -eq 1 ] || return 0
  case "$rule" in
    own) ;;
    closed) in_list "$base" "$RETIRE" || in_list "$base" "$TICKED_NAMES" || return 0 ;;
    *) return 0 ;;
  esac
  rm -f "$f" || {
    kept="$kept$base (could not be removed from live storage)
"
    return 0
  }
  removed=$((removed + 1))
}

# file_folder <live-dir> <archived-dir> <name> — one folder of readings, filed as one record: under
# its own name, only when every record in it was, and removed from live storage only then.
file_folder() {
  local live="$1" to="$2" name="$3" whole=1 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$f" ] && [ ! -L "$f" ]; then
      file_one "$f" "$to" keep
      [ "$FILE_ONE_FILED" -eq 1 ] || whole=0
    else
      whole=0
    fi
  done <<FIND
$(find "$live" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null)
FIND
  if [ "$whole" -eq 0 ]; then
    kept="$kept$name (not every record in it could be filed)
"
    return 0
  fi
  FILED="$FILED$name
"
  [ "$ROTATE" -eq 1 ] || return 0
  if rm -rf "$live" 2>/dev/null && [ ! -e "$live" ]; then
    removed=$((removed + 1))
  else
    kept="$kept$name (could not be removed from live storage)
"
  fi
}

if [ -d "$src" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    base="${f##*/}"
    # The index is a view of a set of receipts, so each side of the move gets its own, written
    # below from what is actually there. The live one is never filed as a record of its own.
    [ "$base" = README.md ] && continue
    if in_list "$base" "$OPEN_NAMES"; then
      file_one "$f" "$dest" keep
    else
      file_one "$f" "$dest" closed
    fi
  done <<FIND
$(find "$src" -maxdepth 1 -type f ! -name '.*' 2>/dev/null)
FIND
fi

# Once the shift has ended, its own records follow it: the usage readings, the policy when no
# clock-out filed it, and the shift log.
if [ "$ROTATE" -eq 1 ]; then
  if [ -d "$USAGE_DIR" ] && [ ! -L "$USAGE_DIR" ]; then
    file_folder "$USAGE_DIR" "$group/$USAGE_REL" "${USAGE_DIR##*/}"
  fi
  if [ -f "$POLICY_FILE" ] && [ ! -L "$POLICY_FILE" ] && [ -n "$policy_id" ] && [ "$policy_id" = "$shift_id" ]; then
    policy_dir="$group"
    case "$POLICY_REL" in */*) policy_dir="$group/${POLICY_REL%/*}" ;; esac
    file_one "$POLICY_FILE" "$policy_dir" own
    [ "$FILE_ONE_FILED" -eq 0 ] || filed_lines="${filed_lines}archive-receipts: filed the shift policy as $group/$POLICY_REL
"
  fi
  if journal="$(ns_archive_file_journal "$WORKSPACE" "$group")"; then
    [ -z "$journal" ] || filed_lines="${filed_lines}archive-receipts: filed the shift log as $journal
"
  else
    kept="$kept${JOURNAL_REL##*/} (the shift log could not be filed)
"
  fi
fi

# A usage-<id>/ folder is a closed shift's readings, set aside by the Start preflight. It goes to the
# folder that shift claimed, at the path the readings have live, or into this shift's folder under
# its own name when no folder is that shift's or its readings are already there.
for u in "$USAGE_PREFIX"*; do
  if ! { [ -d "$u" ] && [ ! -L "$u" ]; }; then continue; fi
  ubase="${u##*/}"
  [ "$ubase" != "${USAGE_PREFIX##*/}" ] || continue
  owner_dir="$(ns_archive_folder_of "$WORKSPACE" "${ubase#"${USAGE_PREFIX##*/}"}")"
  if [ -n "$owner_dir" ] && [ ! -e "$owner_dir/$USAGE_REL" ]; then
    to="$owner_dir/$USAGE_REL"
  else
    ns_layout_rel_set urel "$NS" usage-shift "${ubase#"${USAGE_PREFIX##*/}"}"
    to="$group/$urel"
  fi
  file_folder "$u" "$to" "$ubase"
done

# A leftover shift-report.md (not yet migrated into receipts/) still travels.
ns_layout_rel_at report 0 previous-report
report="$NS/$report"
if [ -f "$report" ] && [ ! -L "$report" ]; then
  file_one "$report" "$group" closed
fi

# The parking lot and the snag log, whole, then only their open entries live.
label="$(ns_archive_review_label "${group##*/}" "$shift_id" "$(ns_archive "$WORKSPACE" layout)")"
for key in snag-log parking-lot; do
  ns_archive_file_review_source "$WORKSPACE" "$key" "$group" "$label"
  case "$?" in
    0) ;;
    3)
      ns_layout_rel_set krel "$NS" "$key"
      kept="$kept$krel (this shift's copy is already filed; its handled entries stay live for the next filing)
"
      ;;
    *)
      printf 'archive-receipts: could not file snag or parking records\n' >&2
      exit 2
      ;;
  esac
done
ns_archive_check_review_pointers "$WORKSPACE" || {
  printf 'archive-receipts: could not check the filed pointers\n' >&2
  exit 2
}

# The punch list, once the shift has ended: filed whole, then only the contract and the open items
# live. While it is armed the list is its contract and nothing here touches it.
if [ "$ROTATE" -eq 1 ]; then
  punch_filed="$(ns_archive_punch_list "$WORKSPACE" "$group" "$shift_id" "$DATE")"
  case "$?" in
    0) [ -z "$punch_filed" ] || filed_lines="${filed_lines}archive-receipts: filed the punch list as $punch_filed
" ;;
    3) printf 'archive-receipts: a different punch list is already filed at %s; the live list is unchanged\n' \
         "$group/$PUNCH_REL" >&2 ;;
    *) printf 'archive-receipts: could not file the punch list into %s\n' "$group" >&2 ;;
  esac
fi

# The archive gets the index of what landed in it, written before the link pass so a receipt that
# links to its index has one to link to.
if [ -d "$dest" ]; then
  ns_receipts_write_archive_index "$dest" "$(ns_receipts_shift_date "$WORKSPACE")" "$OPEN_NAMES"
fi

# Every filed page keeps working from where it now sits. A record filed beside it is reached
# exactly as written; one that stayed live is further away and its link says so. Rewriting changes
# bytes, so the untouched original is kept beside the repointed page as <name>.original.md, and a
# page repointed on an earlier filing is left alone. The shift log is raw evidence and stays as
# written.
ARCHIVED_PATHS="$(cd "$group" 2>/dev/null && find . -type f ! -name '.*' ! -name '*.original.md' 2>/dev/null |
  sed 's#^\./##')"
# rewrite_moved <filed page> <its directory before the move, relative to the state directory>
rewrite_moved() {
  local page="$1" from="$2" base original back rel saved_ifs awk_bin
  [ -f "$page" ] && [ ! -L "$page" ] || return 0
  base="${page##*/}"
  original="${page%.md}.original.md"
  [ ! -e "$original" ] || return 0
  back=""
  rel="${page#"$NS"/}"
  rel="${rel%/*}"
  saved_ifs="$IFS"
  IFS=/
  # shellcheck disable=SC2086
  set -- $rel
  IFS="$saved_ifs"
  for _ in "$@"; do back="../$back"; done
  awk_bin="$(ns_rules_awk_bin)" || awk_bin="awk"
  if NS_ARCHIVED_PATHS="$ARCHIVED_PATHS" "$awk_bin" -v back="$back" -v dir="$from" \
    -f "$_here/archive-links.awk" <"$page" >"${page%/*}/.$base.relocated" 2>/dev/null; then
    if cmp -s "$page" "${page%/*}/.$base.relocated"; then
      rm -f "${page%/*}/.$base.relocated"
    elif ns_archive_dest "$original" && cp "$page" "$original"; then
      mv "${page%/*}/.$base.relocated" "$page" || rm -f "${page%/*}/.$base.relocated"
    else
      rm -f "${page%/*}/.$base.relocated"
      kept="$kept$base (its links were left as written: the original could not be preserved beside a relocated view)
"
    fi
  else
    rm -f "${page%/*}/.$base.relocated"
    kept="$kept$base (its links were left as written)
"
  fi
}
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in
    *.md) ;;
    *) continue ;;
  esac
  [ "$rel" != "$JOURNAL_REL" ] || continue
  # The index is written into the folder it describes, so its links are already siblings there.
  [ "$rel" != "$RECEIPTS_REL/README.md" ] || continue
  case "$rel" in
    */*) rewrite_moved "$group/$rel" "${rel%/*}" ;;
    *) rewrite_moved "$group/$rel" "" ;;
  esac
done <<PAGES
$ARCHIVED_PATHS
PAGES

# The live folder lists the work still in hand, and loses its index when there is nothing left
# to list.
ns_receipts_write_index "$WORKSPACE" remaining

unmatched=""
while IFS= read -r wanted; do
  [ -n "$wanted" ] || continue
  in_list "$wanted" "$FILED" && continue
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

if [ "$copied" -ne 0 ] || [ "$removed" -ne 0 ] || [ -n "$filed_lines" ]; then
  printf '%s\n' "$group"
  [ "$removed" -eq 0 ] || printf 'archive-receipts: retired %s closed record(s) from live storage\n' "$removed"
fi
printf '%s' "$filed_lines"
exit 0
