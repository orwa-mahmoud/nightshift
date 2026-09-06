E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/incident-follow-up.md"

@test "incident follow-up uses operational evidence helpers" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "incident follow-up requires supplied evidence" {
  grep -qi 'postmortem, timeline, logs, issues' "$E"
  grep -qi 'invent an incident' "$E"
}

@test "incident follow-up preserves timeline and separates factors" {
  grep -qi 'impact and timeline' "$E"
  grep -qi 'root, contributing, detection, and recovery' "$E"
}

@test "incident follow-up has a finite verified ending" {
  grep -qi 'Ends when every verified repository action' "$E"
  grep -qi 'item gate is green at every commit' "$E"
}
