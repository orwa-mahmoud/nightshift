E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/localization-parity.md"

@test "localization parity uses product-truth validation" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "localization parity refuses unsupported projects" {
  grep -qi 'Supported only when' "$E"
  grep -qi 'must not start' "$E"
  grep -qi 'Never introduce localization' "$E"
}

@test "localization parity uses established sources and tooling" {
  grep -qi 'canonical source locale' "$E"
  grep -qi 'localization check, generator' "$E"
  grep -qi 'repository-wide reference check' "$E"
}

@test "localization parity parks language judgment and refuses invention" {
  grep -qi 'requires language judgment' "$E"
  grep -qi 'drafting-table.md' "$E"
  grep -qi 'Never invent or machine-generate translations' "$E"
}

@test "localization parity verifies objective drift is gone" {
  grep -qi 'Ends when existing localization checks' "$E"
  grep -qi 'item gate is green at every commit' "$E"
  grep -qi 'relevant application tests' "$E"
}
