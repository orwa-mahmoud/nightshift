#!/usr/bin/env bash
# retain-history.sh — preview or apply Nightshift history retention.
#
# Archive-only. Hooks, start, status, Doctor, and recovery must never invoke this.
# Default is a dry run: print eligible paths, ages, and the governing rule.
# --apply deletes only that allowlist, and only while the workspace is unarmed.
#
#   retain-history.sh [--project DIR] [--apply]
#
# Exit: 0 previewed or applied · 1 usage · 2 armed / refused · 3 apply failed
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'retain-history: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'retain-history: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'retain-history: cannot cd to %s\n' "$PROJECT" >&2
  exit 1
}

WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" || {
    printf 'retain-history: invalid .nightshift-link — Nightshift will not guess a workspace\n' >&2
    exit 2
  }
fi

KIND="$(ns_state_kind "$WORKSPACE")"
case "$KIND" in
  malformed | future)
    printf 'retain-history: %s\n' "$(ns_state_refuse_message "$KIND")" >&2
    exit 2
    ;;
  absent)
    printf 'retain-history: no .nightshift/ at %s\n' "$WORKSPACE" >&2
    exit 2
    ;;
esac

NS="$WORKSPACE/.nightshift"
LOG_DAYS="$(ns_retention_days "$WORKSPACE" runtimeLogDays)"
ARCH_DAYS="$(ns_retention_days "$WORKSPACE" archiveDays)"
ARMED=0
declare ARMED_FILE
ns_layout_set ARMED_FILE "$NS" armed
[ -f "$ARMED_FILE" ] && ARMED=1

printf 'Nightshift retention preview\n'
printf 'Workspace:      %s\n' "$WORKSPACE"
printf 'runtimeLogDays: %s\n' "$LOG_DAYS"
printf 'archiveDays:    %s\n' "$ARCH_DAYS"
if [ "$ARMED" -eq 1 ]; then
  printf 'Armed:          yes — deletion is refused until the shift is unarmed\n'
else
  printf 'Armed:          no\n'
fi
printf '\n'

ELIGIBLE="$(ns_retention_eligible "$WORKSPACE")"
if [ -z "$ELIGIBLE" ]; then
  printf 'Eligible: none\n'
  if [ "$LOG_DAYS" -eq 0 ] && [ "$ARCH_DAYS" -eq 0 ]; then
    printf 'Both rules are 0 (keep forever). Upgrading changes nothing until the owner opts in.\n'
  fi
  exit 0
fi

printf 'Eligible\n'
printf '%s\n' "$ELIGIBLE" | while IFS="$(printf '\t')" read -r kind rel age days; do
  [ -n "$rel" ] || continue
  printf '  %s  age=%sd  rule=%s:%s\n' "$rel" "$age" "$kind" "$days"
done

if [ "$APPLY" -eq 0 ]; then
  printf '\nDry run. Re-run with --apply after explicit confirmation to delete only the listed paths.\n'
  exit 0
fi

if [ "$ARMED" -eq 1 ]; then
  printf 'retain-history: refuse to delete while the shift is armed\n' >&2
  exit 2
fi

ns_retention_apply "$WORKSPACE"
rc=$?
case "$rc" in
  0)
    printf '\nDeleted the eligible allowlisted paths.\n'
    exit 0
    ;;
  1)
    printf 'retain-history: refuse to delete while the shift is armed\n' >&2
    exit 2
    ;;
  *)
    printf 'retain-history: refused or failed to delete a target\n' >&2
    exit 3
    ;;
esac
