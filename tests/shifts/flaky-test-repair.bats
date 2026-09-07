E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/flaky-test-repair.md"

@test "flaky-test repair uses the engineering evidence matrix" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "flaky-test repair declares evidence and a repetition budget" {
  grep -qi 'existing flake evidence' "$E"
  grep -qi 'declare a repetition budget' "$E"
  grep -qi 'Never exceed the declared repetition budget' "$E"
}

@test "flaky-test repair records evidence for unreproduced suspects" {
  grep -qi 'do not claim a repair' "$E"
  grep -qi 'unreproduced' "$E"
  grep -qi 'snag-log.md' "$E"
}

@test "flaky-test repair refuses weaker tests and cosmetic stability" {
  grep -qi 'Never delete, skip, quarantine' "$E"
  grep -qi 'Never replace a meaningful assertion' "$E"
  grep -qi 'add retries as the fix' "$E"
}

@test "flaky-test repair has a finite verified ending" {
  grep -qi 'Ends when every discovered suspect' "$E"
  grep -qi 'item gate is green at every commit' "$E"
  grep -qi 'repetition budget and its containing suite' "$E"
}
