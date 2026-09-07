load helpers

# The plugin root can live at a path containing spaces (e.g. a local marketplace checkout);
# an unquoted ${CLAUDE_PLUGIN_ROOT} makes the shell split the path and every hook fails.

@test "hooks.json declares every hook command" {
  json="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/hooks.json"
  # The names, not a count: a hook added to the tree but never registered here never runs, and a
  # number alone cannot say which one is missing.
  for hook in claude-hardhat claude-pulse claude-session-start claude-session-end claude-clock-out; do
    jq -r '[.. | .command? // empty][]' "$json" | grep -qF "$hook" \
      || { echo "hooks.json does not declare $hook"; return 1; }
  done
  n="$(jq -r '[.. | .command? // empty] | length' "$json")"
  [ "$n" -eq 5 ] || { echo "hooks.json declares $n commands, expected 5"; return 1; }
}

@test "every hooks.json command quotes the plugin root (spaced-path safe)" {
  while IFS= read -r cmd; do
    case "$cmd" in
      '. "${CLAUDE_PLUGIN_ROOT}'*'"') : ;;
      *) echo "unquoted command: $cmd"; return 1 ;;
    esac
  done < <(jq -r '.. | .command? // empty' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/hooks.json")
}

@test "hook commands run from a directory whose path contains a space" {
  dir="$BATS_TEST_TMPDIR/plugin root with spaces"
  mkdir -p "$dir"
  cp -R "$BATS_TEST_DIRNAME/../plugins/nightshift/." "$dir/"
  p="$(new_project)"
  cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/hooks.json")"
  CLAUDE_PLUGIN_ROOT="$dir" CLAUDE_PROJECT_DIR="$p" run sh -c "printf '{}' | $cmd"
  [ "$status" -eq 0 ]
}

# A path or matcher that no longer resolves disables a guard in total silence: the hook simply
# never runs, and every other test — which invokes the scripts directly — stays green. These
# assert the wiring itself, which is the only thing standing between the config and no guard.

@test "every hooks.json command points at a file that exists" {
  root="$BATS_TEST_DIRNAME/../plugins/nightshift"
  while IFS= read -r cmd; do
    path="${cmd#*\"}"
    path="${path%\"}"
    path="${path/\$\{CLAUDE_PLUGIN_ROOT\}/$root}"
    [ -f "$path" ] || { echo "hooks.json names a file that does not exist: $path"; return 1; }
  done < <(jq -r '.. | .command? // empty' "$root/hooks/hooks.json")
}

@test "hooks.json registers the events and matchers the guards rely on" {
  f="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/hooks.json"
  [ "$(jq -r '[.hooks.PreToolUse[].matcher] | join(",")' "$f")" = "*" ]
  [ "$(jq -r '.hooks.Stop | length' "$f")" -eq 1 ]
  [ "$(jq -r '.hooks.SessionEnd | length' "$f")" -eq 1 ]
  [ "$(jq -r '.hooks.PostToolUse | length' "$f")" -eq 1 ]
  jq -e '.hooks.SessionEnd[0].hooks[0].command | test("session-end")' "$f" >/dev/null
  jq -e '.hooks.PostToolUse[0].hooks[0].command | test("pulse")' "$f" >/dev/null
  jq -e '.hooks.PreToolUse[] | select(.matcher=="*") | .hooks[0].command | test("hardhat")' "$f" >/dev/null
  jq -e '.hooks.Stop[0].hooks[0].command | test("clock-out")' "$f" >/dev/null
}

@test "the hooks wired in hooks.json actually decide when driven through their own config" {
  root="$BATS_TEST_DIRNAME/../plugins/nightshift"
  p="$(new_project)"
  punch_open "$p"
  cmd="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="*") | .hooks[0].command' "$root/hooks/hooks.json")"
  out="$(jq -nc '{tool_name:"Bash",tool_input:{command:"git push"}}' |
    CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PROJECT_DIR="$p" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push' sh -c "$cmd")"
  is_deny "$out"
  out="$(jq -nc '{tool_name:"WebSearch",tool_input:{query:"nightshift"}}' |
    CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PROJECT_DIR="$p" NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"","request_user_input":"","WebSearch":"no browsing"}' sh -c "$cmd")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "no browsing"

  cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$root/hooks/hooks.json")"
  out="$(printf '{}' | CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PROJECT_DIR="$p" sh -c "$cmd")"
  is_block "$out"
}

@test "Codex hooks use the catch-all PreToolUse matcher and valid commands" {
  root="$BATS_TEST_DIRNAME/../plugins/nightshift"
  f="$root/hooks/codex/hooks.json"
  [ "$(jq -r '[.hooks.PreToolUse[].matcher] | join(",")' "$f")" = "*" ]
  [ "$(jq -r '[.. | .command? // empty] | length' "$f")" -eq 4 ]
  [ "$(jq -r '[.. | .commandWindows? // empty] | length' "$f")" -eq 4 ]
  jq -e '.hooks.PreToolUse[0].hooks[0].command | test("codex/hardhat")' "$f" >/dev/null
  jq -e '.hooks.PostToolUse[0].hooks[0].command | test("codex/pulse")' "$f" >/dev/null
  jq -e '.hooks.SessionEnd[0].hooks[0].command | test("codex/session-end")' "$f" >/dev/null
  jq -e '.hooks.Stop[0].hooks[0].command | test("codex/clock-out-gate")' "$f" >/dev/null
  jq -e '.hooks.PreToolUse[0].hooks[0].commandWindows | test("windows\\\\hardhat.ps1")' "$f" >/dev/null
  jq -e '.hooks.PostToolUse[0].hooks[0].commandWindows | test("windows\\\\pulse.ps1")' "$f" >/dev/null
  jq -e '.hooks.SessionEnd[0].hooks[0].commandWindows | test("windows\\\\session-end.ps1")' "$f" >/dev/null
  jq -e '.hooks.Stop[0].hooks[0].commandWindows | test("windows\\\\clock-out-gate.ps1")' "$f" >/dev/null
  jq -e '.hooks.SessionEnd[0].hooks[0].commandWindows | test("-HostName codex")' "$f" >/dev/null
  jq -e '[.. | .commandWindows? // empty]
    | all(contains("powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File"))
    and all(contains("%PLUGIN_ROOT%"))' "$f" >/dev/null
  while IFS= read -r cmd; do
    path="${cmd%\"}"
    path="${path#\"}"
    path="${path/\$\{PLUGIN_ROOT\}/$root}"
    [ -f "$path" ] || { echo "Codex hooks.json names a missing file: $path"; return 1; }
  done < <(jq -r '.. | .command? // empty' "$f")
}

@test "Cursor hooks.json wires hardhat, clock-out, session-end, and pulse" {
  root="$BATS_TEST_DIRNAME/../plugins/nightshift"
  f="$root/hooks/cursor/hooks.json"
  [ "$(jq -r '.version' "$f")" = "1" ]
  [ "$(jq -r '[.hooks.preToolUse[].command] | length' "$f")" -eq 1 ]
  [ "$(jq -r '[.hooks.postToolUse[].command] | length' "$f")" -eq 1 ]
  [ "$(jq -r '[.hooks.afterAgentThought[].command] | length' "$f")" -eq 1 ]
  [ "$(jq -r '[.hooks.stop[].command] | length' "$f")" -eq 2 ]
  [ "$(jq -r '[.hooks.sessionEnd[].command] | length' "$f")" -eq 1 ]
  [ "$(jq -r '[.hooks.beforeSubmitPrompt[].command] | length' "$f")" -eq 1 ]
  jq -e '.hooks.preToolUse[0].command | test("cursor/hardhat")' "$f" >/dev/null
  jq -e '.hooks.postToolUse[0].command | test("cursor/pulse")' "$f" >/dev/null
  jq -e '.hooks.afterAgentThought[0].command | test("cursor/pulse")' "$f" >/dev/null
  jq -e '.hooks.stop[0].command | test("cursor/clock-out-gate")' "$f" >/dev/null
  jq -e '.hooks.stop[1].command | test("cursor/pulse")' "$f" >/dev/null
  jq -e '.hooks.sessionEnd[0].command | test("cursor/session-end")' "$f" >/dev/null
  jq -e '.hooks.beforeSubmitPrompt[0].command | test("cursor/before-submit")' "$f" >/dev/null
  while IFS= read -r cmd; do
    path="${cmd/\$\{CURSOR_PLUGIN_ROOT\}/$root}"
    [ -f "$path" ] || { echo "Cursor hooks.json names a missing file: $path"; return 1; }
  done < <(jq -r '.. | .command? // empty' "$f")
}

@test "Codex catch-all wiring reaches configured MCP tools" {
  root="$BATS_TEST_DIRNAME/../plugins/nightshift"
  f="$root/hooks/codex/hooks.json"
  p="$(new_project)"
  punch_open "$p"
  cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$f")"
  out="$(jq -nc '{tool_name:"mcp__web__search",tool_input:{query:"nightshift"}}' |
    PLUGIN_ROOT="$root" CODEX_PROJECT_DIR="$p" NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"","request_user_input":"","mcp__web__search":"no MCP browsing"}' sh -c "$cmd")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "no MCP browsing"
}
