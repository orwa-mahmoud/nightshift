E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/architecture-health.md"

@test "architecture health is review-first with concrete findings only" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'Review first writes the findings report only' "$E"
  grep -qi 'concrete dependency and boundary cost' "$E"
  grep -qi 'Reject taste-only observations' "$E"
}

@test "architecture health allows only small reversible direct edits" {
  grep -qi 'small, reversible edit' "$E"
  grep -qi 'never perform broad refactors unattended' "$E"
}

@test "architecture health refuses taste as proof" {
  grep -qi 'Never present architectural preference as proof' "$E"
  grep -qi 'Never select this entry when work mode is artifact' "$E"
}

@test "architecture health is finite and gates commits" {
  grep -qi 'Ends when every accepted finding' "$E"
  grep -qi 'item gate is green at every commit' "$E"
}
