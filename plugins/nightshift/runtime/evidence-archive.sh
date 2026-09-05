#!/usr/bin/env bash
# evidence-archive.sh — file tonight's findings ledger beside the shift policy archive.
#
#   evidence-archive.sh --project DIR [--shift-id ID]
#
# Copies $NS/evidence/findings.jsonl to archive/<YYYY-MM-DD>/findings-<shiftId>.jsonl when the
# ledger exists and is non-empty, then truncates the live file so the next shift starts lean.
# Best effort: a missing ledger or unreadable shiftId exits 0 with no output.
#
# Exit: 0 ok or nothing to do · 1 usage · 2 contract failure
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0" >&2
  exit 1
}

die() {
  printf 'evidence-archive: %s\n' "$1" >&2
  exit "$2"
}

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
SHIFT_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || usage
      PROJECT="$2"
      shift 2
      ;;
    --shift-id)
      [ $# -ge 2 ] || usage
      SHIFT_ID="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1" 1 ;;
  esac
done

WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || WORKSPACE="$PROJECT"
NS="$WORKSPACE/.nightshift"
JSONL="$NS/evidence/findings.jsonl"

[ -f "$JSONL" ] && [ ! -L "$JSONL" ] || exit 0
[ -s "$JSONL" ] || exit 0

if [ -z "$SHIFT_ID" ]; then
  SHIFT_ID="$(ns_policy_shift_id "$WORKSPACE" 2>/dev/null)" || SHIFT_ID=""
fi
[ -n "$SHIFT_ID" ] || SHIFT_ID=unknown

# The owner chooses where and how a shift is filed; the shift id names the file either way.
dated="$(ns_archive_dir "$WORKSPACE" "$(date '+%Y-%m-%d')" "$SHIFT_ID")" ||
  die 'archive.root must name a directory inside .nightshift/' 2
dest="$dated/findings-$SHIFT_ID.jsonl"
mkdir -p "$dated" || die "cannot create $dated" 2
cp "$JSONL" "$dest" || die "cannot copy $JSONL to $dest" 2
: >"$JSONL"
printf '%s\n' "$dest"
exit 0
