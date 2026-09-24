#!/usr/bin/env bash
# Hosts fire every registered hook on every event. When the host named the
# project (CURSOR_PROJECT_DIR / CLAUDE_PROJECT_DIR / CODEX_PROJECT_DIR) and
# that site has no armed shift, exit before loading the library or reading
# stdin. Cursor sets that env even when it hands over a descriptor that never
# closes — that is the hang this stands down. Only the path helper is loaded,
# to find the markers wherever the workspace's layout keeps them.
#
# If the host did not name a project, the payload cwd is the documented
# locator. Do not guess from $PWD: that is the runner, not the shift.
# Revival workers stay in. Stop hooks use cold-stop.sh instead.
if [ "${NIGHTSHIFT_REVIVAL:-}" != "1" ]; then
  _ns_idle_host="${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-}}}"
  if [ -n "$_ns_idle_host" ] \
    && [ ! -e "$_ns_idle_host/.nightshift-link" ] && [ ! -L "$_ns_idle_host/.nightshift-link" ]; then
    # shellcheck source=plugins/nightshift/lib/paths.sh
    . "${BASH_SOURCE[0]%/*}/../../lib/paths.sh"
    declare _ns_idle_armed _ns_idle_ended
    ns_layout_set _ns_idle_armed "$_ns_idle_host/.nightshift" armed
    ns_layout_set _ns_idle_ended "$_ns_idle_host/.nightshift" ended
    if [ ! -f "$_ns_idle_armed" ] \
      || { [ -f "$_ns_idle_ended" ] && [ ! -L "$_ns_idle_ended" ]; }; then
      unset _ns_idle_host _ns_idle_armed _ns_idle_ended
      exit 0
    fi
    unset _ns_idle_armed _ns_idle_ended
  fi
  unset _ns_idle_host
fi
