E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/toil-reduction.md"

@test "toil reduction uses operational evidence helpers" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "toil reduction requires repetition evidence" {
  grep -qi 'frequency, failure cost' "$E"
  grep -qi 'one-time annoyances' "$E"
}

@test "toil reduction refuses false repetition claims" {
  grep -qi 'without repetition evidence' "$E"
  grep -qi 'Never automate a one-time annoyance' "$E"
}

@test "toil reduction has a finite verified ending" {
  grep -qi 'Ends when every in-scope task is automated' "$E"
  grep -qi 'item gate is green at every commit' "$E"
}
