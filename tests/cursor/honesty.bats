load ../helpers

ROOT="$BATS_TEST_DIRNAME/../../"
START="$ROOT/plugins/nightshift/skills/start/SKILL.md"
CURSOR_MARKET="$ROOT/.cursor-plugin/marketplace.json"

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
