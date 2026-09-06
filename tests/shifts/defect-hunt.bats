E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/defect-hunt.md"
HUNT="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/hunt/SKILL.md"
MODES="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md"
COMMANDS="$BATS_TEST_DIRNAME/../../docs/commands.md"
HOW="$BATS_TEST_DIRNAME/../../docs/how-it-works.md"
SHIFT_MODES="$BATS_TEST_DIRNAME/../../docs/shift-modes.md"

@test "defect hunt rotates lenses and tracks cycle state" {
  grep -qi 'defect-cycle receipt' "$E"
  grep -qi 'rotate lenses' "$E"
  grep -qi 'correctness' "$E"
  grep -qi 'recent-change' "$E"
}

@test "defect hunt deduplicates every finding against the snag log" {
  grep -qi 'snag-log.md' "$E"
  grep -qi 'ALL seen' "$E"
  grep -qi 'never re-reports' "$E"
}

@test "defect hunt fixes behind the gate and records dispositions" {
  grep -qi 'fix each behind the item gate' "$E"
  grep -qi 'append dispositions' "$E"
}

@test "defect hunt ends at convergence or quitting time" {
  grep -qi 'nothing NEW' "$E"
  grep -qi 'quitting time' "$E"
  grep -qi 'Zero new findings is success' "$E"
}

@test "defect hunt verifies every commit" {
  grep -qi 'item gate is green at every commit' "$E"
}

@test "defect hunt is skipped in artifact mode" {
  grep -qi 'Never select this entry in artifact mode' "$E"
  grep -qi 'Never select this entry when work mode is artifact' "$E"
  grep -qF 'Do not `git init` a notes folder' "$E"
  grep -qi 'Never select defect hunt when work mode is artifact' "$HUNT"
  grep -qi 'Skip the defect hunt when work mode is artifact' "$MODES"
  grep -qi 'skips the defect hunt in artifact mode' "$COMMANDS"
  grep -qi 'skips the defect hunt in artifact mode' "$HOW"
  grep -qF 'The defect hunt is skipped in artifact mode' "$SHIFT_MODES"
}
