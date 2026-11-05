#!/usr/bin/env bats

load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/session-end-logic.ps1"
REASONS="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/session-end-reasons.sh"
PS1="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/session-end.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"

@test "owner session-end reasons are one list per host" {
  for word in clear resume logout prompt_input_exit; do
    grep -qF "$word" "$REASONS"
    grep -qF "$word" "$PS1"
  done
  grep -qF 'aborted | user_close' "$REASONS"
  grep -qF "'aborted', 'user_close'" "$PS1"
  grep -qF 'ns_session_end_owner_reason claude' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/session-end.sh"
  grep -qF 'ns_session_end_owner_reason cursor' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/cursor/session-end.sh"
  grep -qF 'ns_lease_allows' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/codex/session-end.sh"
  grep -qF 'session-end-logic.ps1' "$RUN"
}

@test "Windows session-end logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh not installed'
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
