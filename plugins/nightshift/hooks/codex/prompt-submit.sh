#!/usr/bin/env bash
# prompt-submit.sh — Codex UserPromptSubmit hook. The owner's own command closes the plan room.
#
# Codex documents `prompt` as the user prompt about to be sent, and records a skill mention as the
# text the owner typed. A prompt whose first word is $nightshift:plan-exit or $nightshift:start (or
# the same name after `/`) closes the room; any other prompt, the same words mid-sentence included,
# leaves it as it is. A skill the model invokes is not a prompt, so it never reaches this hook.
#
# The prompt always goes through: this hook never blocks one.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/hooks/shared/idle.sh
. "$_here/../shared/idle.sh"
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh"
# shellcheck source=plugins/nightshift/hooks/codex/lib-io.sh
. "$_here/lib-io.sh"

codex_read_input "$@"
WORD="$(ns_plan_room_exit_word "${CODEX_PROMPT:-}")" || exit 0
PROJECT_DIR="$(ns_workspace_root "$(codex_project_dir)" 2>/dev/null)" || exit 0
ns_plan_room_leave "$PROJECT_DIR/.nightshift" "typed the $WORD command" || exit 0
codex_emit_prompt_context "$(ns_plan_room_left_context "$WORD")"
exit 0
