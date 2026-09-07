E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/dead-code-cleanup.md"

@test "dead-code cleanup evaluates guard rails before deletion" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "dead-code cleanup requires existing repository tooling" {
  grep -qi "repository already has" "$E"
  grep -qi 'must not start' "$E"
  grep -qi 'introduce a new analyzer without owner approval' "$E"
}

@test "dead-code cleanup checks dynamic and external references" {
  grep -qi 'reflection, dynamic' "$E"
  grep -qi 'public exports' "$E"
  grep -qi 'external consumers' "$E"
}

@test "dead-code cleanup parks uncertainty instead of deleting" {
  grep -qi 'Park uncertain findings' "$E"
  grep -qi 'Uncertainty is not permission to delete' "$E"
  grep -qi 'Never infer dead code from intuition' "$E"
}

@test "dead-code cleanup verifies every deletion and its ending" {
  grep -qi 'Ends when the original analyzer reports' "$E"
  grep -qi 'item gate is green at every commit' "$E"
  grep -qi 'every deletion and the final repository' "$E"
}
