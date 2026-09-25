#!/usr/bin/env bash
# Exercise the runtime from inside a real Remote SSH or devcontainer boundary.
set -euo pipefail

MODE="${1:-}"
ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
case "$MODE" in
  remote-ssh)
    [ -n "${SSH_CONNECTION:-}" ] || {
      printf 'environment probe: remote-ssh requires a real SSH connection\n' >&2
      exit 1
    }
    ;;
  devcontainer)
    [ -f /etc/nightshift-devcontainer-fixture ] || {
      printf 'environment probe: devcontainer fixture marker is missing\n' >&2
      exit 1
    }
    ;;
  *)
    printf 'usage: probe.sh remote-ssh|devcontainer [repository-root]\n' >&2
    exit 2
    ;;
esac

[ "$(uname -s)" = "Linux" ] || {
  printf 'environment probe: the checked matrix currently covers Linux remotes\n' >&2
  exit 1
}
for command_name in bash git jq ps; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'environment probe: missing prerequisite: %s\n' "$command_name" >&2
    exit 1
  }
done

ROOT="$(cd "$ROOT" && pwd)"
LIB="$ROOT/plugins/nightshift/lib/lib.sh"
LINK="$ROOT/plugins/nightshift/runtime/link-workspace.sh"
CLAUDE_HARDHAT="$ROOT/plugins/nightshift/hooks/hardhat.sh"
CODEX_HARDHAT="$ROOT/plugins/nightshift/hooks/codex/hardhat.sh"
WATCHMAN="$ROOT/plugins/nightshift/runtime/claude/watchman.sh"
RULES="$ROOT/plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json"
for shipped_file in "$LIB" "$LINK" "$CLAUDE_HARDHAT" "$CODEX_HARDHAT" "$WATCHMAN" "$RULES"; do
  [ -f "$shipped_file" ] || {
    printf 'environment probe: shipped file is missing: %s\n' "${shipped_file#"$ROOT"/}" >&2
    exit 1
  }
done

fixture="$(mktemp -d "${TMPDIR:-/tmp}/nightshift-environment.XXXXXX")"
watchman_pid=""
cleanup() {
  if [ -n "$watchman_pid" ] && kill -0 "$watchman_pid" 2>/dev/null; then
    kill "$watchman_pid" 2>/dev/null || true
    wait "$watchman_pid" 2>/dev/null || true
  fi
  rm -rf -- "$fixture"
  if [ -e "$fixture" ] || [ -L "$fixture" ]; then
    printf 'environment probe: fixture cleanup failed\n' >&2
    return 1
  fi
}
cleanup_best_effort() { cleanup >/dev/null 2>&1 || true; }
trap cleanup_best_effort EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

workspace="$fixture/state workspace"
host_root="$fixture/task root"
work_target="$workspace/work target"
mkdir -p "$workspace/.nightshift" "$host_root" "$work_target"
git -C "$host_root" init -q
git -C "$work_target" init -q
cp "$RULES" "$workspace/.nightshift/rules.json"
printf '1\n' >"$workspace/.nightshift/state-version"
printf '# Shift Log\n' >"$workspace/.nightshift/shift-log.md"
printf '## Items\n- [ ] **1. environment fixture.**\n' >"$workspace/.nightshift/punch-list.md"
: >"$workspace/.nightshift/.shift-armed"

bash "$LINK" --host-root "$host_root" --workspace "$workspace" >/dev/null

# shellcheck source=plugins/nightshift/lib/lib.sh
. "$LIB"
resolved_workspace="$(ns_workspace_root "$host_root")"
resolved_target="$(ns_work_target "$resolved_workspace")"
[ "$resolved_workspace" = "$(cd "$workspace" && pwd)" ]
[ "$resolved_target" = "$(cd "$work_target" && pwd)" ]

claude_bound="$(
  jq -nc --arg cwd "$host_root" \
    '{tool_name:"Bash",session_id:"environment-claude",transcript_path:"",cwd:$cwd,tool_input:{command:": nightshift-binding-probe"}}' |
    env CLAUDE_PROJECT_DIR="$host_root" bash "$CLAUDE_HARDHAT"
)"
[ -z "$claude_bound" ]
claude_output="$(
  jq -nc --arg cwd "$host_root" \
    '{tool_name:"AskUserQuestion",session_id:"environment-claude",transcript_path:"",cwd:$cwd,tool_input:{}}' |
    env CLAUDE_PROJECT_DIR="$host_root" bash "$CLAUDE_HARDHAT"
)"
printf '%s' "$claude_output" |
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
[ "$(stat -c '%a' "$workspace/.nightshift/.shift-lease")" = "600" ]

rm -f "$workspace/.nightshift/.shift-session" "$workspace/.nightshift/.shift-lease"
codex_bound="$(
  jq -nc --arg cwd "$host_root" \
    '{tool_name:"Bash",session_id:"12345678-1234-1234-1234-123456789abc",cwd:$cwd,tool_input:{command:": nightshift-binding-probe"}}' |
    env CODEX_PROJECT_DIR="$host_root" bash "$CODEX_HARDHAT"
)"
[ -z "$codex_bound" ]
codex_output="$(
  jq -nc --arg cwd "$host_root" \
    '{tool_name:"request_user_input",session_id:"12345678-1234-1234-1234-123456789abc",cwd:$cwd,tool_input:{}}' |
    env CODEX_PROJECT_DIR="$host_root" bash "$CODEX_HARDHAT"
)"
printf '%s' "$codex_output" |
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

process_start="$(ns_process_start "$$")"
[ -n "$process_start" ]
ns_recorded_process "$$" "$process_start"
if ns_recorded_process "$$" "not-the-recorded-start"; then
  printf 'environment probe: mismatched process start time was accepted\n' >&2
  exit 1
fi

state_file="$workspace/.nightshift/.environment-atomic"
printf 'old\n' >"$state_file"
chmod 600 "$state_file"
state_tmp="$state_file.$$"
(umask 077; printf 'atomic\n' >"$state_tmp")
mv -f "$state_tmp" "$state_file"
[ "$(sed -n '1p' "$state_file")" = "atomic" ]
[ "$(stat -c '%a' "$state_file")" = "600" ]
rm -f "$state_file"

rm -f "$workspace/.nightshift/.shift-session" "$workspace/.nightshift/.shift-lease"
env NIGHTSHIFT_WATCH_SLEEP=1 \
  bash "$WATCHMAN" --project "$workspace" --interval 1 --agent true --max-wakes 1 \
  >"$fixture/watchman.log" 2>&1 &
watchman_pid=$!
attempt=0
while [ ! -s "$workspace/.nightshift/.watchman" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || {
    printf 'environment probe: watchman did not publish its pid\n' >&2
    exit 1
  }
  sleep 0.02
done
[ "$(sed -n '1p' "$workspace/.nightshift/.watchman")" = "$watchman_pid" ]
[ "$(ns_proc_cwd "$watchman_pid")" = "$(cd "$workspace" && pwd)" ]
: >"$workspace/.nightshift/STOP"
attempt=0
while [ -e "$workspace/.nightshift/.watchman" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 200 ] || {
    kill "$watchman_pid" 2>/dev/null || true
    wait "$watchman_pid" 2>/dev/null || true
    watchman_pid=""
    printf 'environment probe: watchman ignored STOP\n' >&2
    exit 1
  }
  sleep 0.05
done
if ! wait "$watchman_pid"; then
  watchman_pid=""
  printf 'environment probe: watchman failed while handling STOP\n' >&2
  exit 1
fi
watchman_pid=""
[ ! -e "$workspace/.nightshift/.watchman" ]

architecture="$(uname -m)"
case "$architecture" in *[!A-Za-z0-9_.-]* | '') exit 1 ;; esac
cleanup
trap - EXIT INT TERM
printf '%s\n' \
  '{' \
  '  "schema": 1,' \
  "  \"environment\": \"$MODE\"," \
  '  "platform": "linux",' \
  "  \"architecture\": \"$architecture\"," \
  '  "result": "pass",' \
  '  "checks": {' \
  '    "boundary": "pass",' \
  '    "filesystem": "pass",' \
  '    "hookExecution": "pass",' \
  '    "processIdentity": "pass",' \
  '    "watchmanPlacement": "pass",' \
  '    "workspaceResolution": "pass"' \
  '  }' \
  '}'
