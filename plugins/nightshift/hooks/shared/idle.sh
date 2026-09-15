# Hosts fire every registered hook on every event. An install with no armed
# shift must not load the library or read stdin. Revival workers stay in so
# they can refuse to continue after clock-out. A .nightshift-link is resolved
# after the library loads.
if [ "${NIGHTSHIFT_REVIVAL:-}" != "1" ]; then
  _ns_idle_host="${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}}"
  if [ ! -e "$_ns_idle_host/.nightshift-link" ] && [ ! -L "$_ns_idle_host/.nightshift-link" ]; then
    if [ ! -f "$_ns_idle_host/.nightshift/.shift-armed" ] \
      || { [ -f "$_ns_idle_host/.nightshift/.ended" ] && [ ! -L "$_ns_idle_host/.nightshift/.ended" ]; }; then
      unset _ns_idle_host
      exit 0
    fi
  fi
  unset _ns_idle_host
fi
