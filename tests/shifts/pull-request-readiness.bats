E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/pull-request-readiness.md"
HUNT="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/hunt/SKILL.md"
MODES="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md"

@test "pull-request readiness anchors to branch, issue, and acceptance criteria" {
  grep -qi 'Discovery' "$E"
  grep -qi 'named branch' "$E"
  grep -qi 'issue URL' "$E"
  grep -qi 'acceptance criteria' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "pull-request readiness uses review-map with changed areas, risks, and commits" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'changed areas' "$E"
  grep -qi 'remaining risks' "$E"
  grep -qi 'unsupported surfaces' "$E"
  grep -qi 'rollback' "$E"
  grep -qi 'reviewer decisions' "$E"
  grep -qi 'shift-log' "$E"
}

@test "pull-request readiness refuses owner-only actions without authority" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'Never comment on, approve, push, merge' "$E"
  grep -qi 'explicit owner authorization' "$E"
  grep -qi 'does not approve' "$E"
}

@test "pull-request readiness is finite and repository-mode only" {
  grep -qi 'Ends when every scoped gap' "$E"
  grep -qi 'containing checks are green' "$E"
  grep -qi 'repository mode only' "$E"
  grep -qi 'Never select this entry in artifact mode' "$E"
  grep -qF 'Do not `git init` a notes folder' "$E"
}

@test "pull-request readiness gates every commit and disposition findings" {
  grep -qi 'item gate is green at every commit' "$E"
  grep -qi 'disposition every finding' "$E"
  grep -qi 'reads ready for human review' "$E"
  grep -qi 'review map reaches a finite' "$E"
  grep -qi 'snag-log.md' "$E"
}

@test "pull-request readiness routes generic code review elsewhere" {
  grep -qi 'Generic code review' "$E"
  grep -qi 'routes elsewhere' "$E"
}
