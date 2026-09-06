E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/github-issue-hunt.md"
HUNT="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/hunt/SKILL.md"
QUALITY="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/quality/SKILL.md"
MODES="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md"
COMMANDS="$BATS_TEST_DIRNAME/../../docs/commands.md"
HOW="$BATS_TEST_DIRNAME/../../docs/how-it-works.md"

@test "the GitHub issue hunt consumes only imported proposed drafts" {
  grep -qF 'Status: proposed' "$E"
  grep -qF 'Import issues skill' "$E"
  grep -qi 'If none exist' "$E"
  grep -qi 'point at Import issues and stop' "$E"
  grep -qi 'Never search GitHub' "$E"
  grep -qi 'Never select this entry in artifact mode' "$E"
  grep -qF 'Do not `git init` a notes folder' "$E"
}

@test "guided preview and direct ranking stay inside the imported set" {
  grep -qi 'Guided mode' "$E"
  grep -qi 'requires an explicit selection' "$E"
  grep -qi 'Direct mode' "$E"
  grep -qi 'authorized work-target repo' "$E"
  grep -qi 'Do not expand the selected set' "$E"
  grep -qi 'cannot grow past the imported' "$MODES"
}

@test "the hunt cuts drafts into one punch list and keeps one commit per issue" {
  grep -qF '$NIGHTSHIFT_PLUGIN_ROOT/runtime/import-issues.sh' "$E"
  grep -qF -- '--project "$NIGHTSHIFT_WORKSPACE"' "$E"
  grep -qF -- '--promote' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'Cut, never copy' "$E"
  grep -qi 'Do not paste' "$E"
  grep -qi 'One conventional commit per issue' "$E"
  grep -qi 'shift-log.md' "$E"
  grep -qi 'deadline is reached' "$E"
}

@test "the hunt never mutates GitHub and reports ready for PR" {
  grep -qi 'Never comment on, edit, assign, label, or close' "$E"
  grep -qi 'never search GitHub' "$E"
  grep -qi 'never write back' "$E"
  grep -qi 'ready for PR' "$E"
  grep -qF 'Closes #N' "$E"
  grep -qi 'Refuse flagged' "$E"
}

@test "Hunt offers the entry without replacing defect or product shifts" {
  grep -qF 'GitHub issue-hunt' "$HUNT"
  grep -qF 'Status: proposed' "$HUNT"
  grep -qi 'does not replace defect hunt or product' "$HUNT"
  grep -qi 'Never select it when work mode is artifact' "$HUNT"
  grep -qi 'skips the GitHub issue hunt in artifact mode' "$COMMANDS"
  grep -qi 'skips the GitHub issue hunt in artifact mode' "$HOW"
  grep -qi 'Quality does not import, search, or work GitHub issues' "$QUALITY"
}
