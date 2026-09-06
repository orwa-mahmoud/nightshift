E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/coverage-hunt.md"
HUNT="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/hunt/SKILL.md"
QUALITY="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/quality/SKILL.md"
MODES="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md"
COMMANDS="$BATS_TEST_DIRNAME/../../docs/commands.md"
HOW="$BATS_TEST_DIRNAME/../../docs/how-it-works.md"
SHIFT_MODES="$BATS_TEST_DIRNAME/../../docs/shift-modes.md"

@test "coverage hunt maps behavior risks before writing tests" {
  grep -qi 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'red state' "$E"
  grep -qi 'containing suites' "$E"
}

@test "coverage hunt chooses valuable untested behaviour" {
  grep -qi 'highest-priority uncovered cluster' "$E"
  grep -qi 'behavior-protecting tests' "$E"
}

@test "coverage hunt refuses padding and unexplained exclusions" {
  grep -qi 'tripwire, never a target' "$E"
  grep -qi 'no padding tests' "$E"
  grep -qi 'exclusion needs a written reason' "$E"
}

@test "coverage hunt is clock-bounded and leaves cycle receipts" {
  grep -qi 'Log one line per cycle' "$E"
  grep -qi 'Stop only at quitting time' "$E"
  grep -qi 'clock out orderly' "$E"
}

@test "coverage hunt gates every commit" {
  grep -qi 'item gate is green at every commit' "$E"
}

@test "coverage hunt is skipped in artifact mode" {
  grep -qi 'Never select this entry in artifact mode' "$E"
  grep -qi 'Never select this entry when work mode is artifact' "$E"
  grep -qF 'Do not `git init` a notes folder' "$E"
  grep -qi 'Never select coverage hunt when work mode is artifact' "$HUNT"
  grep -qi 'Skip coverage hunt when work mode is artifact' "$QUALITY"
  grep -qi 'Skip coverage hunt when work mode is artifact' "$MODES"
  grep -qi 'skips coverage hunt in artifact mode' "$COMMANDS"
  grep -qi 'skips coverage hunt in artifact mode' "$HOW"
  grep -qF 'Coverage hunt is skipped in artifact mode' "$SHIFT_MODES"
}
