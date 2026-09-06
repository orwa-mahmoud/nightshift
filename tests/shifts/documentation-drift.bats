E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/documentation-drift.md"
HUNT="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/hunt/SKILL.md"
QUALITY="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/quality/SKILL.md"
MODES="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md"
COMMANDS="$BATS_TEST_DIRNAME/../../docs/commands.md"
HOW="$BATS_TEST_DIRNAME/../../docs/how-it-works.md"
SHIFT_MODES="$BATS_TEST_DIRNAME/../../docs/shift-modes.md"

@test "documentation drift uses claim-to-authority matrix" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "documentation drift discovers local references against the tree" {
  grep -qi 'Discovery' "$E"
  grep -qi 'relative links' "$E"
  grep -qi 'Do not query the network' "$E"
}

@test "documentation drift content-architecture mode uses specialist helper" {
  grep -qi 'Content-architecture mode' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "documentation drift public-claims mode uses release-readiness matrix" {
  grep -qi 'Public-claims mode' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'Never publish or deploy from this shift' "$E"
  grep -qi 'Route full baseline-vs-candidate release comparison to release-readiness' "$E"
}

@test "documentation drift refuses to invent commands or change product behaviour" {
  grep -qi 'Never invent a command' "$E"
  grep -qi 'Never change product behaviour' "$E"
  grep -qi 'Never rewrite positioning' "$E"
}

@test "documentation drift is finite and parks unverifiable third-party URLs" {
  grep -qi 'Ends when a full local pass' "$E"
  grep -qi 'third-party URL' "$E"
  grep -qi 'snag-log.md' "$E"
}

@test "documentation drift gates every commit" {
  grep -qi 'item gate is green at every commit' "$E"
}

@test "documentation drift is skipped in artifact mode" {
  grep -qi 'Never select this entry in artifact mode' "$E"
  grep -qi 'Never select this entry when work mode is artifact' "$E"
  grep -qF 'Do not `git init` a notes folder' "$E"
  grep -qi 'Never select documentation drift when work mode is artifact' "$HUNT"
  grep -qi 'Skip documentation drift when work mode is artifact' "$QUALITY"
  grep -qi 'Skip documentation drift when work mode is artifact' "$MODES"
  grep -qi 'skips documentation drift in artifact mode' "$COMMANDS"
  grep -qi 'skips documentation drift in artifact mode' "$HOW"
  grep -qF 'Documentation drift is skipped in artifact mode' "$SHIFT_MODES"
}
