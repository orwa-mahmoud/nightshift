#!/usr/bin/env bash
# migrate-state.sh — move a workspace's state files into the current layout.
#
#   migrate-state.sh [--project DIR] [--apply]
#
# Previews by default: every move, every settings block renamed, every link written again so it
# still resolves, every conflict, and everything left in place because no Nightshift file has its
# name. Nothing changes until it runs with --apply, which performs exactly what the preview lists.
# It refuses while the shift is armed, while a watchman is alive and while a lock is held, and it
# never deletes or overwrites: a destination that already holds different content refuses the whole
# run by name. The state-version marker is written last, so a run that stops part way is finished by
# running it again, and a second run changes nothing.
#
# Explicit owner action only. Hooks, Start, Status, Archive and recovery never invoke this.
#
# Exit: 0 previewed, applied, or nothing to do · 1 refused (armed, watchman, lock) · 2 unsupported
#       state · 3 a move or write failed · 4 usage · 5 conflict
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"
# shellcheck source=plugins/nightshift/lib/migrate.sh
. "$_here/../lib/migrate.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'migrate-state: --project needs a value\n' >&2; exit 4; }
      PROJECT="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 4
      ;;
    *) printf 'migrate-state: unknown argument: %s\n' "$1" >&2; exit 4 ;;
  esac
done

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'migrate-state: cannot cd to %s\n' "$PROJECT" >&2
  exit 4
}

WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" || {
    printf 'migrate-state: invalid .nightshift-link — Nightshift will not guess a workspace\n' >&2
    exit 2
  }
fi

PLAN="$(mktemp "${TMPDIR:-/tmp}/ns-migrate-plan.XXXXXX")" || exit 3
trap 'rm -f "$PLAN"' EXIT
ns_migrate_plan "$WORKSPACE" >"$PLAN"
rc=$?
if [ "$rc" -ne 0 ]; then
  sed -n 's/^refuse\t/migrate-state: /p' "$PLAN" >&2
  exit 2
fi

FROM="$(sed -n 's/^state\t//p' "$PLAN")"
printf 'migrate-state: %s/.nightshift is state-version %s; version %s groups it by purpose\n' \
  "$WORKSPACE" "$FROM" "$NS_STATE_VERSION"

if grep -q '^refuse' "$PLAN"; then
  ns_migrate_render preview <"$PLAN"
  exit 1
fi
if grep -q '^conflict' "$PLAN"; then
  ns_migrate_render preview <"$PLAN"
  exit 5
fi
if [ "$APPLY" -eq 0 ]; then
  ns_migrate_render preview <"$PLAN"
  exit 0
fi
if ! ns_migrate_apply "$WORKSPACE" "$PLAN"; then
  grep -v '^marker' "$PLAN" | ns_migrate_render preview
  printf 'migrate-state: stopped part way - what finished stands and state-version is unchanged; run it again to finish\n' >&2
  exit 3
fi
ns_migrate_render apply <"$PLAN"
exit 0
