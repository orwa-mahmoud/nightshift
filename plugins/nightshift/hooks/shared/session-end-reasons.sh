#!/usr/bin/env bash
# The reasons that are the owner's hand on the door, one list per host.
# Claude's list is the SessionEnd reason table: clear, resume, logout,
# prompt_input_exit. other, a missing reason, and a reason the table does not
# name write nothing, so the watchman's liveness ladder decides. Cursor's list
# is aborted and user_close. Codex does not filter on reason.

# ns_session_end_owner_reason <host> <reason> — status 0 when that reason stands
# the watchman down for that host.
ns_session_end_owner_reason() {
  case "$1" in
    claude)
      case "$2" in
        clear | resume | logout | prompt_input_exit) return 0 ;;
      esac
      ;;
    cursor)
      case "$2" in
        aborted | user_close) return 0 ;;
      esac
      ;;
  esac
  return 1
}
