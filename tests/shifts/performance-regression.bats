E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/performance-regression.md"

@test "performance regression uses operational evidence helpers" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "performance regression requires distributions and baseline" {
  grep -qi 'at least two samples' "$E"
  grep -qi 'Never invent a baseline' "$E"
  grep -qi 'Never write faster or regression language without a present baseline' "$E"
}

@test "performance regression refuses unsafe load and correctness tradeoffs" {
  grep -qi 'refuse production or over-budget targets' "$E"
  grep -qi 'weaken correctness' "$E"
}

@test "performance regression has a finite verified ending" {
  grep -qi 'Ends when the scoped change is verified against distributions' "$E"
  grep -qi 'item gate is green at every commit' "$E"
}
