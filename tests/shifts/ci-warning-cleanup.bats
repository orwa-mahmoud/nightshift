E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/ci-warning-cleanup.md"

@test "CI warning cleanup normalizes warnings with engineering evidence" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "CI warning cleanup discovers from the project's own pipeline" {
  grep -qi 'Discovery' "$E"
  grep -qi 'CI-equivalent or item-gate' "$E"
  grep -qi 'snag-log.md' "$E"
}

@test "CI warning cleanup splits repository-owned from external warnings" {
  grep -qi 'repository-owned' "$E"
  grep -qi 'external' "$E"
  grep -qi 'unresolved' "$E"
}

@test "CI warning cleanup refuses suppressions and unrelated majors" {
  grep -qi 'Never add a suppression' "$E"
  grep -qi 'Never turn off a CI job' "$E"
  grep -qi 'unrelated major dependency upgrade' "$E"
}

@test "CI warning cleanup ends with an explicit external-warning receipt" {
  grep -qi 'Ends when a full recapture' "$E"
  grep -qi 'parked external' "$E"
  grep -qi 'item gate is green at every commit' "$E"
}
