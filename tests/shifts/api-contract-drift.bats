E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/api-contract-drift.md"

@test "API drift uses product-truth evidence classification" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "API drift requires an authoritative source and existing comparison" {
  grep -qi 'authoritative API source' "$E"
  grep -qi 'configured generation' "$E"
  grep -qi 'must not start' "$E"
}

@test "API drift distinguishes non-breaking and potentially breaking changes" {
  grep -qi 'non-breaking artifact drift' "$E"
  grep -qi 'potentially breaking change' "$E"
  grep -qi 'affected consumers' "$E"
}

@test "API drift parks breaking decisions and refuses silent API changes" {
  grep -qi 'drafting-table.md' "$E"
  grep -qi 'Never silently change a public API' "$E"
  grep -qi 'Never add contract tooling' "$E"
  grep -qi 'accept a generated diff blindly' "$E"
}

@test "API drift ends with clean existing contract checks" {
  grep -qi 'Ends when configured contract checks' "$E"
  grep -qi 'item gate is green at every commit' "$E"
  grep -qi 'relevant server/client tests pass' "$E"
}
