#!/usr/bin/env bash
# pulse.sh — Codex PostToolUse pulse. Silent stdout.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh"
# shellcheck source=plugins/nightshift/hooks/codex/lib-io.sh
. "$_here/lib-io.sh"
# shellcheck source=plugins/nightshift/hooks/pulse.sh
. "$_here/../pulse.sh"

codex_read_input "$@"
HOST_DIR="$(codex_project_dir)"
PROJECT_DIR="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)" || exit 0
STATE_KIND="$(ns_state_kind "$PROJECT_DIR")"
case "$STATE_KIND" in
  malformed | future) exit 0 ;;
esac
ns_pulse_emit "$PROJECT_DIR/.nightshift" "${CODEX_SESSION_ID:-}"
# The rollout the host handed this hook carries the session's running token total; one tail reads
# it. Nothing else is opened, and no other session is looked at.
ns_pulse_usage "$PROJECT_DIR/.nightshift" codex "${CODEX_SESSION_ID:-}" "${CODEX_TRANSCRIPT_PATH:-}"
exit 0
