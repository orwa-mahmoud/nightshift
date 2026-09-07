#!/usr/bin/env bash
# pulse.sh — Cursor postToolUse / afterAgentThought / stop pulse. Silent stdout.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh"
# shellcheck source=plugins/nightshift/hooks/cursor/lib-io.sh
. "$_here/lib-io.sh"
# shellcheck source=plugins/nightshift/hooks/pulse.sh
. "$_here/../pulse.sh"

cursor_read_input "$@"
HOST_DIR="$(cursor_project_dir)"
PROJECT_DIR="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)" || exit 0
STATE_KIND="$(ns_state_kind "$PROJECT_DIR")"
case "$STATE_KIND" in
  malformed | future) exit 0 ;;
esac
ns_pulse_emit "$PROJECT_DIR/.nightshift" "${CURSOR_SESSION_ID:-}"
# Cursor puts the figures on the payload itself — there is no transcript carrying them — so the
# reading is taken from what the host just delivered.
ns_pulse_usage "$PROJECT_DIR/.nightshift" cursor "${CURSOR_SESSION_ID:-}" "${CURSOR_RAW:-}"
ns_pulse_marks "$PROJECT_DIR/.nightshift" "$PROJECT_DIR"
ns_pulse_context cursor "$(ns_pulse_report_due "$PROJECT_DIR/.nightshift" "$PROJECT_DIR")"
exit 0
