#!/usr/bin/env bash
# send-message.sh — send a running shift a question or an answer.
#
#   send-message.sh --project DIR [--run NAME] [--text TEXT]
#
# Appends the message, with the local time, under `## Owner · <time>` in the run's
# inbox/messages.md. The run's worker is shown it at its next tool call and appends its reply under
# `## Worker · <time>` in the same file, where the sender reads it. Without --text the message is
# read from stdin, so multiline text reaches the file exactly as written. In a workspace that keeps
# runs, the run is the one named with --run, by NIGHTSHIFT_RUN, or the only one.
#
# Prints the messages file. Exit: 0 sent · 1 usage or refused
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-$PWD}}}"
RUN_NAME=""
TEXT=""
HAVE_TEXT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'send-message: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --run)
      [ $# -ge 2 ] || { printf 'send-message: --run needs a value\n' >&2; exit 1; }
      RUN_NAME="$2"
      shift 2
      ;;
    --text)
      [ $# -ge 2 ] || { printf 'send-message: --text needs a value\n' >&2; exit 1; }
      TEXT="$2"
      HAVE_TEXT=1
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'send-message: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
if [ "$HAVE_TEXT" -eq 0 ]; then
  TEXT="$(cat)"
fi
[ -n "${TEXT//[[:space:]]/}" ] || { printf 'send-message: the message is empty\n' >&2; exit 1; }

WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || {
  printf 'send-message: no workspace at %s\n' "$PROJECT" >&2
  exit 1
}
NS="$WORKSPACE/.nightshift"
[ -d "$NS" ] && [ ! -L "$NS" ] || { printf 'send-message: no .nightshift/ at %s\n' "$WORKSPACE" >&2; exit 1; }
ns_run_choose "$NS" "$RUN_NAME" || {
  printf 'send-message: %s\n' "$NS_RUN_ERR" >&2
  exit 1
}
ns_message_append "$NS" Owner "$TEXT" || exit 1
ns_layout_path "$NS" messages
printf '\n'
