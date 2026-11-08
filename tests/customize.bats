#!/usr/bin/env bats
# /nightshift:customize shows every customisation on one screen and changes only what the owner
# names, through the helpers that already exist. It is a convenience, never a gate.

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
SKILL="$PLUGIN/skills/customize/SKILL.md"
REFS="$PLUGIN/skills/nightshift/references"

@test "the skill ships on every host and is one sentence long in its description" {
  [ -f "$SKILL" ]
  sed -n '1,7p' "$SKILL" | grep -qx 'name: customize'
  sed -n '1,7p' "$SKILL" | grep -qx '  internal: true'
  # Every host loads the plugin's skills folder, so the skill is registered wherever the others are.
  jq -e '.skills == "./skills/"' "$PLUGIN/.codex-plugin/plugin.json" >/dev/null
  jq -e '.skills == "./skills/"' "$PLUGIN/.cursor-plugin/plugin.json" >/dev/null
  if jq -e 'has("skills")' "$PLUGIN/.claude-plugin/plugin.json" >/dev/null; then
    return 1
  fi
}

@test "the screen covers every group of settings, the templates, the catalogs and the profiles" {
  for group in '**Guards**' '**Recovery and watching**' '**Shift defaults**' '**Evidence**' \
    '**Receipts, handoff and archive**' '**Retention**' '**Catalogs**' '**Profiles**'; do
    grep -qF "$group" "$SKILL" || { echo "no $group"; return 1; }
  done
  for name in shifts evidence gates edge-cases; do
    grep -qF "catalog-index --catalog $name" "$SKILL" || { echo "does not list $name"; return 1; }
  done
  grep -qF 'templatePath' "$SKILL"
  grep -qF 'shift-policy resolve --table' "$SKILL"
}

@test "it writes through the existing helpers, keeps every unnamed value, and refuses while armed" {
  grep -qF 'shift-policy defaults-set' "$SKILL"
  grep -qF 'apply-profile --profile <name>' "$SKILL"
  grep -qF 'catalog-new --catalog <catalog> --key <key>' "$SKILL"
  grep -qF 'keeping every other value byte for byte' "$SKILL"
  grep -qF 'Refuse while a shift is armed' "$SKILL"
  grep -qF 'Ask nothing' "$SKILL"
  # Every helper and reference it names exists.
  for helper in shift-policy apply-profile catalog-new catalog-index; do
    [ -x "$PLUGIN/runtime/$helper.sh" ] || { echo "missing helper $helper"; return 1; }
  done
  [ -f "$REFS/nightshift-rules-template.json" ]
  [ -f "$REFS/nightshift-rules.schema.json" ]
  [ -d "$REFS/profiles" ]
}

@test "it is never a gate, and the docs say so too" {
  grep -qF 'never a gate' "$SKILL"
  grep -qF 'in plain words' "$SKILL"
  grep -qF '/nightshift:customize' "$ROOT/docs/knobs.md"
  grep -qF 'None of them requires the others' "$ROOT/docs/knobs.md"
  grep -qF '/nightshift:customize' "$ROOT/docs/commands.md"
  grep -qF '/nightshift:customize' "$ROOT/README.md"
}
