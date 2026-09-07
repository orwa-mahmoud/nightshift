E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/release-readiness.md"
HUNT="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/hunt/SKILL.md"
QUALITY="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/quality/SKILL.md"
MODES="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md"

@test "release readiness compares named baseline and candidate" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'named baseline' "$E"
  grep -qi 'package contents and digests' "$E"
  grep -qi 'install/upgrade smoke' "$E"
}

@test "release readiness produces ready not-ready or conditionally ready verdict" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'Not ready' "$E"
  grep -qi 'Conditionally ready' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "release readiness never publishes or claims human acceptance" {
  grep -qi 'Never publish' "$E"
  grep -qi 'Green CI alone is not complete release evidence' "$E"
  grep -qi 'Nightshift verdict is not human acceptance' "$E"
  grep -qi 'without explicit owner authority' "$E"
}

@test "release readiness wires public-claims mode to documentation drift" {
  grep -qi 'public-claims mode' "$E"
  grep -qF 'public-claims-matrix' "$E"
  grep -qi 'documentation-drift' "$E"
}

@test "release readiness is skipped in artifact mode" {
  grep -qi 'Never select this entry in artifact mode' "$E"
  grep -qi 'Never select this entry when work mode is artifact' "$E"
  grep -qF 'Do not `git init` a notes folder' "$E"
}

@test "release readiness gates every commit and ends finitely" {
  grep -qi 'item gate is green at every commit' "$E"
  grep -qi 'Ends when every scoped blocker' "$E"
  grep -qi 'snag-log.md' "$E"
}
