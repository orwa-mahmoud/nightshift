#!/usr/bin/env bash
# Stop hooks only. When the host named the project and that site is cold,
# do not read stdin or load the library. Claude and Cursor release by
# silence. Codex documents JSON on every Stop that exits 0, so an unarmed
# Codex stop prints {"continue":true} and leaves. Only the path helper is
# loaded, to find the markers wherever the workspace's layout keeps them.
# Set NS_COLD_STOP_HOST=claude|codex|cursor before sourcing.
#
# No host project env means the payload cwd must be read; do not guess $PWD.
if [ "${NIGHTSHIFT_REVIVAL:-}" != "1" ]; then
  _ns_cold_host="${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-}}}"
  if [ -n "$_ns_cold_host" ] \
    && [ ! -e "$_ns_cold_host/.nightshift-link" ] && [ ! -L "$_ns_cold_host/.nightshift-link" ]; then
    # shellcheck source=plugins/nightshift/lib/paths.sh
    . "${BASH_SOURCE[0]%/*}/../../lib/paths.sh"
    declare _ns_cold_armed _ns_cold_ended
    ns_layout_set _ns_cold_armed "$_ns_cold_host/.nightshift" armed
    ns_layout_set _ns_cold_ended "$_ns_cold_host/.nightshift" ended
    if [ ! -f "$_ns_cold_armed" ] \
      || { [ -f "$_ns_cold_ended" ] && [ ! -L "$_ns_cold_ended" ]; }; then
      case "${NS_COLD_STOP_HOST:-claude}" in
        codex) printf '%s\n' '{"continue":true}' ;;
      esac
      unset _ns_cold_host _ns_cold_armed _ns_cold_ended
      exit 0
    fi
    unset _ns_cold_armed _ns_cold_ended
  fi
  unset _ns_cold_host
fi
