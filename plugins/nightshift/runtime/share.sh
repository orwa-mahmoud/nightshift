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

# The block as it stands now, or nothing.
current_block() {
  [ -f "$IGNORE" ] || return 0
  awk -v b="$NS_SHARE_BEGIN" -v e="$NS_SHARE_END" '$0 == b { on = 1 } on { print } $0 == e { on = 0 }' "$IGNORE"
}
# The file with the block taken out.
without_block() {
  [ -f "$IGNORE" ] || return 0
  awk -v b="$NS_SHARE_BEGIN" -v e="$NS_SHARE_END" '$0 == b { on = 1; next } $0 == e { on = 0; next } !on' "$IGNORE"
}

BLOCK=""
[ -z "$RECORDS" ] || BLOCK="$(ns_share_ignore_block "$WORKSPACE")" ||
  refuse "layout the shared records have no paths in this plugin's layout" "run ns doctor"

if [ "$APPLY" -eq 0 ]; then
  if [ "$(current_block)" = "$BLOCK" ]; then
    ok "gitignore $(ns_layout_name "$NS" gitignore) already matches"
  elif [ -n "$BLOCK" ]; then
    ok "gitignore would write this block to $(ns_layout_name "$NS" gitignore):"
    printf '%s\n' "$BLOCK" | sed 's/^/  /'
    printf 'next run ns share --apply to write it\n'
  else
    ok "gitignore would take the sharing block out of $(ns_layout_name "$NS" gitignore)"
    printf 'next run ns share --apply to take it out\n'
  fi
  exit 0
fi

# ---------------------------------------------------------------- write the block
TMP="$IGNORE.tmp.$$"
if ! {
  [ -z "$BLOCK" ] || printf '%s\n' "$BLOCK"
  without_block
} >"$TMP" || ! mv -f "$TMP" "$IGNORE"; then
  rm -f "$TMP"
  refuse "gitignore could not write $IGNORE" "check that .nightshift/ is writable, then run this again"
fi
[ -s "$IGNORE" ] || rm -f "$IGNORE"
if [ -n "$BLOCK" ]; then
  ok "gitignore wrote the sharing block to $(ns_layout_name "$NS" gitignore)"
else
  ok "gitignore took the sharing block out of $(ns_layout_name "$NS" gitignore)"
  exit 0
fi

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
