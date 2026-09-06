E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/todo-fixme-debt.md"
HUNT="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/hunt/SKILL.md"
QUALITY="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/quality/SKILL.md"
MODES="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md"
COMMANDS="$BATS_TEST_DIRNAME/../../docs/commands.md"
HOW="$BATS_TEST_DIRNAME/../../docs/how-it-works.md"
SHIFT_MODES="$BATS_TEST_DIRNAME/../../docs/shift-modes.md"

@test "todo-fixme debt classifies markers with engineering evidence" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "TODO debt inventories tracked human-authored markers" {
  grep -qi 'tracked, human-authored' "$E"
  grep -qi 'TODO, FIXME, HACK, and XXX' "$E"
  grep -qi 'generated, vendored' "$E"
}

@test "TODO debt distinguishes actionable work from decisions" {
  grep -qi 'Actionable means' "$E"
  grep -qi 'Ambiguous means' "$E"
  grep -qi 'underlying work' "$E"
}

@test "TODO debt stages ambiguity and refuses invented features" {
  grep -qi 'drafting-table.md' "$E"
  grep -qi 'do not guess the answer' "$E"
  grep -qi 'Never invent a feature' "$E"
  grep -qi 'Never delete or reword a marker' "$E"
}

@test "TODO debt has a verifiable finite ending" {
  grep -qi 'Ends when every discovered marker' "$E"
  grep -qi 'item gate is green at every commit' "$E"
  grep -qi 'final scoped search' "$E"
}

@test "TODO debt is skipped in artifact mode" {
  grep -qi 'Never select this entry in artifact mode' "$E"
  grep -qi 'Never select this entry when work mode is artifact' "$E"
  grep -qF 'Do not `git init` a notes folder' "$E"
  grep -qi 'Never select TODO and FIXME debt when work mode is artifact' "$HUNT"
  grep -qi 'Skip TODO and FIXME debt when work mode is artifact' "$QUALITY"
  grep -qi 'Skip TODO and FIXME debt when work mode is artifact' "$MODES"
  grep -qi 'skips TODO and FIXME debt in artifact mode' "$COMMANDS"
  grep -qi 'skips TODO and FIXME debt in artifact mode' "$HOW"
  grep -qF 'TODO and FIXME debt is skipped in artifact mode' "$SHIFT_MODES"
}
