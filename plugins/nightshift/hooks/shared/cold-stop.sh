#!/usr/bin/env bash
# Stop hooks only. When the host named the project and that site is cold,
# do not read stdin or load the library. Claude and Cursor release by
# silence. Codex documents JSON on every Stop that exits 0, so an unarmed
# Codex stop prints {"continue":true} and leaves.
# Set NS_COLD_STOP_HOST=claude|codex|cursor before sourcing.
#
# No host project env means the payload cwd must be read; do not guess $PWD.
if [ "${NIGHTSHIFT_REVIVAL:-}" != "1" ]; then
  _ns_cold_host="${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-}}}"
  if [ -n "$_ns_cold_host" ] \
    && [ ! -e "$_ns_cold_host/.nightshift-link" ] && [ ! -L "$_ns_cold_host/.nightshift-link" ]; then
    if [ ! -f "$_ns_cold_host/.nightshift/.shift-armed" ] \
      || { [ -f "$_ns_cold_host/.nightshift/.ended" ] && [ ! -L "$_ns_cold_host/.nightshift/.ended" ]; }; then
      case "${NS_COLD_STOP_HOST:-claude}" in
        codex) printf '%s\n' '{"continue":true}' ;;
      esac
      unset _ns_cold_host
      exit 0
    fi
  fi
  unset _ns_cold_host
fi
