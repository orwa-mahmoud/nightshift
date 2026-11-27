#!/usr/bin/env bash
# share.sh — let Git see the project records the team shares, and nothing private.
#
#   share.sh [--project DIR] [--apply]
#
# sharing.records in rules.json names the records a team shares through Git: plans, decisions,
# rules, receipts and summaries. This prints the block of .nightshift/.gitignore that matches it:
# everything under .nightshift/ is ignored, then each shared record is let back in, while raw
# evidence folders, private messages, the runtime's own folders, STOP, leases and locks stay
# ignored. With --apply it writes that block, keeping every line outside it, and removes it again
# when sharing.records is empty. It never stages, commits or pushes; when to do that is the team's.
#
# When the repository above ignores .nightshift/ through the one line Setup writes, --apply takes
# that line out; any other pattern is named for the owner to change. Files Git already tracks that
# are now private are named with the command that untracks them.
#
# Prints one verdict per line: `ok`, `warn` or `refuse`, each refusal followed by its `repair`.
# Exit: 0 written or previewed · 1 refused · 2 usage
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
_here="$(cd -P "$_here" && pwd)" || exit 2
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-$PWD}}}"
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'share: --project needs a value\n' >&2; exit 2; }
      PROJECT="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 2
      ;;
    *) printf 'share: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

ok() { printf 'ok %s\n' "$1"; }
warn() { printf 'warn %s\n' "$1"; }
refuse() {
  printf 'refuse %s\n' "$1"
  [ -z "${2:-}" ] || printf 'repair %s\n' "$2"
  exit 1
}

WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || refuse "workspace no workspace at $PROJECT" "run Setup in the project first"
NS="$WORKSPACE/.nightshift"
[ -d "$NS" ] && [ ! -L "$NS" ] || refuse "workspace no .nightshift/ at $WORKSPACE" "run Setup in the project first"

UNKNOWN="$(ns_share_unknown "$WORKSPACE")"
[ -z "$UNKNOWN" ] ||
  refuse "records sharing.records names $(printf '%s' "$UNKNOWN" | paste -sd ' ' -), which is no record" \
    "use only $(printf '%s' "$NS_SHARE_RECORDS" | sed 's/ /, /g') in sharing.records"
RECORDS="$(ns_shared_records "$WORKSPACE" | paste -sd ' ' -)"
IGNORE="$NS/.gitignore"

if [ -n "$RECORDS" ]; then
  ns_layout_per_run "$NS" punch-list ||
    refuse "layout this workspace keeps one shift at a time, so teammates' runs would share its files" \
      "preview the move to run folders with ns migrate-state, make it with --apply, then run this again"
  [ ! -e "$NS/.git" ] ||
    refuse "receipts-repo .nightshift/ is a Git repository of its own, so the project's Git cannot see into it" \
      "move .nightshift/.git out of .nightshift/ to stop keeping the receipts repo, then run this again"
  ok "records $RECORDS"
else
  ok "records none: the site stays private to its runner"
fi

# current_block <file> — the block as it stands in <file> now, or nothing.
current_block() {
  [ -f "$1" ] || return 0
  awk -v b="$NS_SHARE_BEGIN" -v e="$NS_SHARE_END" '$0 == b { on = 1 } on { print } $0 == e { on = 0 }' "$1"
}
# without_block <file> — <file> with the block taken out.
without_block() {
  [ -f "$1" ] || return 0
  awk -v b="$NS_SHARE_BEGIN" -v e="$NS_SHARE_END" '$0 == b { on = 1; next } $0 == e { on = 0; next } !on' "$1"
}

# preview <file> <block> <label> — what --apply would do to <file>.
preview() {
  if [ "$(current_block "$1")" = "$2" ]; then
    ok "$3 .nightshift/${1##*/} already matches"
  elif [ -n "$2" ]; then
    ok "$3 would write this block to .nightshift/${1##*/}:"
    printf '%s\n' "$2" | sed 's/^/  /'
  else
    ok "$3 would take the sharing block out of .nightshift/${1##*/}"
  fi
}

# write_block <file> <block> <label> — the block first, every other line of <file> after it; the
# file goes when nothing is left.
write_block() {
  local tmp="$1.tmp.$$"
  if ! {
    [ -z "$2" ] || printf '%s\n' "$2"
    without_block "$1"
  } >"$tmp" || ! mv -f "$tmp" "$1"; then
    rm -f "$tmp"
    refuse "$3 could not write $1" "check that .nightshift/ is writable, then run this again"
  fi
  [ -s "$1" ] || rm -f "$1"
  if [ -n "$2" ]; then
    ok "$3 wrote the sharing block to .nightshift/${1##*/}"
  else
    ok "$3 took the sharing block out of .nightshift/${1##*/}"
  fi
}

ATTRIBUTES="$NS/.gitattributes"
BLOCK=""
ATTR_BLOCK=""
if [ -n "$RECORDS" ]; then
  if ! BLOCK="$(ns_share_ignore_block "$WORKSPACE")" || ! ATTR_BLOCK="$(ns_share_attributes_block "$WORKSPACE")"; then
    refuse "layout the shared records have no paths in this plugin's layout" "run ns doctor"
  fi
fi

if [ "$APPLY" -eq 0 ]; then
  preview "$IGNORE" "$BLOCK" gitignore
  preview "$ATTRIBUTES" "$ATTR_BLOCK" gitattributes
  if [ "$(current_block "$IGNORE")" != "$BLOCK" ] || [ "$(current_block "$ATTRIBUTES")" != "$ATTR_BLOCK" ]; then
    printf 'next run ns share --apply to write it\n'
  fi
  exit 0
fi

# ---------------------------------------------------------------- write the blocks
write_block "$IGNORE" "$BLOCK" gitignore
write_block "$ATTRIBUTES" "$ATTR_BLOCK" gitattributes
[ -n "$BLOCK" ] || exit 0

# ---------------------------------------------------------------- the repository above
TOP="$(git -C "$NS" rev-parse --show-toplevel 2>/dev/null)" || {
  warn "repository .nightshift/ is in no Git repository, so nothing is shared until one holds it"
  exit 0
}
ok "repository $TOP"
# Where the site sits in the repository, as Git names it.
SITE_REL="$(git -C "$NS" rev-parse --show-prefix 2>/dev/null)"
SITE_REL="${SITE_REL%/}"
REL="$SITE_REL/state-version"
if HIT="$(git -C "$TOP" check-ignore -v -- "$REL" 2>/dev/null)" && [ -n "$HIT" ]; then
  # source:line:pattern<TAB>path
  SRC="${HIT%%:*}"
  REST="${HIT#*:}"
  LINE="${REST%%:*}"
  PATTERN="${REST#*:}"
  PATTERN="${PATTERN%%	*}"
  case "$SRC" in /*) SRC_FILE="$SRC" ;; *) SRC_FILE="$TOP/$SRC" ;; esac
  case "$PATTERN" in
    "$SITE_REL/" | "/$SITE_REL/" | "$SITE_REL" | "/$SITE_REL")
      if [ "$SRC_FILE" = "$TOP/.gitignore" ] || [ "$SRC_FILE" = "$WORKSPACE/.gitignore" ]; then
        if ! awk -v n="$LINE" 'NR != n' "$SRC_FILE" >"$SRC_FILE.tmp.$$" || ! mv -f "$SRC_FILE.tmp.$$" "$SRC_FILE"; then
          rm -f "$SRC_FILE.tmp.$$"
          refuse "repository could not edit $SRC_FILE" "take the line $PATTERN out of $SRC_FILE by hand"
        fi
        ok "repository took the line $PATTERN out of $SRC_FILE so Git can see the shared records"
      else
        refuse "repository $SRC line $LINE ($PATTERN) hides .nightshift/ from Git" "take that line out, then run this again"
      fi
      ;;
    *)
      refuse "repository $SRC line $LINE ($PATTERN) hides .nightshift/ from Git" "change that pattern so it no longer covers .nightshift/, then run this again"
      ;;
  esac
fi

# Files Git tracks that the block now keeps private.
git -C "$NS" ls-files -ci --exclude-standard -- . 2>/dev/null | while IFS= read -r f; do
  [ -n "$f" ] || continue
  warn "tracked-private Git still tracks $f, which stays private"
  printf 'repair git -C %s rm --cached -- %s\n' "$NS" "$f"
done
ok "next stage and commit .nightshift/ when the team chooses; nothing was staged"
exit 0
