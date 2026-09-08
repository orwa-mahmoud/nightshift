load ../helpers

ROOT="$BATS_TEST_DIRNAME/../../"
HOW="$ROOT/docs/how-it-works.md"
KNOBS="$ROOT/docs/knobs.md"
START="$ROOT/plugins/nightshift/skills/start/SKILL.md"
README="$ROOT/README.md"
MARKET="$ROOT/.claude-plugin/marketplace.json"
CODEX_MARKET="$ROOT/.agents/plugins/marketplace.json"
CURSOR_MARKET="$ROOT/.cursor-plugin/marketplace.json"

@test "docs name the Cursor IDE and CLI store split" {
  grep -qF '~/.cursor/projects/' "$HOW"
  grep -qF 'agent-transcripts' "$HOW"
  grep -qF '~/.cursor/chats' "$HOW"
  grep -qF 'agent --resume' "$HOW"
  grep -qF 'Never pass the IDE id to `agent --resume`' "$KNOBS"
}

@test "docs forbid resuming an IDE conversation_id" {
  grep -qF 'never pass the IDE' "$HOW"
  grep -qF 'conversation_id' "$HOW"
  if grep -qE 'agent --resume .*conversation_id' "$HOW" "$KNOBS" "$START"; then
    return 1
  fi
}

@test "docs name the Cursor CLI file-hook limitation" {
  grep -qF 'currently ignores' "$HOW"
  grep -qF 'marketplace and local plugin hooks' "$HOW"
  grep -qF 'a Cursor limitation' "$HOW"
  grep -qF 'not a Nightshift skip' "$HOW"
}

@test "Cursor installation names the repository flow and retains recovery limits" {
  grep -qE '^### Cursor$' "$README"
  grep -qF 'Customize → Add → From GitHub Repository' "$README"
  grep -qF 'is for discovery' "$README"
  grep -qF '](docs/how-it-works.md#recovery)' "$README"
  grep -qF 'marketplace listing waits' "$HOW"
  if grep -qi cursor "$MARKET"; then
    return 1
  fi
  if grep -qi cursor "$CODEX_MARKET"; then
    return 1
  fi
}

@test "the Cursor marketplace file points at the shipped plugin" {
  [ -f "$CURSOR_MARKET" ]
  [ "$(jq -r '.plugins[0].name' "$CURSOR_MARKET")" = "nightshift" ]
  [ "$(jq -r '.plugins[0].source' "$CURSOR_MARKET")" = "./plugins/nightshift" ]
  [ -f "$ROOT/plugins/nightshift/.cursor-plugin/plugin.json" ]
}

@test "Cursor listing uses the same in-repo logo as Codex" {
  logo="$ROOT/plugins/nightshift/assets/nightshift-logo.png"
  [ -f "$logo" ]
  [ "$(jq -r '.logo' "$ROOT/plugins/nightshift/.cursor-plugin/plugin.json")" = "./assets/nightshift-logo.png" ]
  [ "$(jq -r '.plugins[0].logo' "$CURSOR_MARKET")" = "./assets/nightshift-logo.png" ]
  [ "$(jq -r '.interface.logo' "$ROOT/plugins/nightshift/.codex-plugin/plugin.json")" = "./assets/nightshift-logo.png" ]
}

@test "Release Please bumps the Cursor host manifest with the others" {
  cfg="$ROOT/release-please-config.json"
  jq -e '.packages["."]."extra-files" | map(.path) | index("plugins/nightshift/.claude-plugin/plugin.json")' "$cfg" >/dev/null
  jq -e '.packages["."]."extra-files" | map(.path) | index("plugins/nightshift/.codex-plugin/plugin.json")' "$cfg" >/dev/null
  jq -e '.packages["."]."extra-files" | map(.path) | index("plugins/nightshift/.cursor-plugin/plugin.json")' "$cfg" >/dev/null
}
