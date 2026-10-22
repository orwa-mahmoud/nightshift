E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/environment-example-drift.md"

@test "environment example drift is finite and names its supported input" {
  head -n1 "$E" | grep -qE '^# .+ — finite — '
  grep -qi 'tracked root `.env.example`' "$E"
}

@test "environment example drift compares literal names without exposing values" {
  grep -qi 'literal environment-variable reads' "$E"
  grep -qi 'variable names' "$E"
  grep -qi 'name-only projection' "$E"
  grep -qi 'empty or non-empty' "$E"
  grep -qi 'never record right-hand-side values' "$E"
  grep -qi 'second name-only comparison' "$E"
}

@test "environment example drift uses the shared cycle receipt" {
  grep -qi 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'mode: env-example-drift' "$E"
  grep -qi 'Unparsed projection or search output is `unavailable`, never an empty result' "$E"
}

@test "environment example drift refuses secrets, guesses, and unsafe deletions" {
  grep -qi 'Never reveal, copy, or record right-hand-side contents' "$E"
  grep -qi 'Never read, display, copy, or record values from `.env`, `.env.local`' "$E"
  grep -qi 'add, guess, or expose a credential' "$E"
  grep -qi 'Never remove a template name' "$E"
  grep -qi 'uncertain' "$E"
}

@test "environment example drift records duplicates under the shared rule" {
  grep -qi 'already recorded in `snag-log.md` is a `duplicate` under Snag log discipline' "$E"
}

@test "environment example drift parks ambiguity and stays out of runtime behavior" {
  grep -qi 'parked with a reason' "$E"
  grep -qi 'Never change application code' "$E"
  grep -qi 'item gate must be green at every commit' "$E"
}

@test "environment example drift is repository-only" {
  grep -qi 'Never select this entry in artifact mode' "$E"
  grep -qF 'do not `git init` a notes folder' "$E"
}
