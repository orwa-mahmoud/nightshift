E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/owner-walkthrough.md"
HUNT="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/hunt/SKILL.md"
START="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/start/SKILL.md"
COMMANDS="$BATS_TEST_DIRNAME/../../docs/commands.md"

@test "owner walkthrough requires a verbatim owner objective and guided selection" {
  grep -qF '**Selection:** Guided only.' "$E"
  grep -qF '**Owner instructions:** Required.' "$E"
  grep -qi 'must remain verbatim' "$E"
  grep -qi 'Never select this entry in Automatic mode' "$E"
  grep -qi 'work-target discovery' "$E"
  grep -qi 'work-target discovery' "$COMMANDS"
  grep -qi 'do not compose, cut, or arm' "$E"
}

@test "owner walkthrough is an hours-cycle with an owner stop" {
  head -n1 "$E" | grep -q '— open-ended —'
  grep -qi 'quitting time is the normal ending' "$E"
  grep -qi 'stop-work order remains available' "$E"
}

@test "owner walkthrough ends early on a verified objective, never on busywork" {
  grep -qi 'verified objective satisfaction may' "$E"
  grep -qi 'clock out early' "$E"
  grep -qi 'Never manufacture busywork' "$E"
}

@test "owner walkthrough keeps one durable continuation record" {
  grep -qF 'Status: building' "$E"
  grep -qF 'opportunity-map.md' "$E"
  grep -qF 'Next' "$E"
  grep -qF 'Verify remaining' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'Plan before cutting' "$E"
  grep -qi 'reversible defaults' "$E"
  grep -qi 'Never open a second building entry' "$E"
}

@test "owner walkthrough works in coherent verified units without publishing" {
  grep -qi 'strongest coherent unit' "$E"
  grep -qi 'item gate must be green at every commit' "$E"
  grep -qi 'inspect current work-target evidence' "$E"
  grep -qi 'work-target tests and tooling' "$E"
  grep -qi 'push, open a PR, deploy, publish' "$E"
  grep -qi 'morning handoff' "$E"
  grep -qF 'do not `git init` the folder' "$E"
  grep -qi 'artifact receipt' "$E"
  grep -qF '$NS/receipts/' "$E"
}

@test "hunt recognizes required objectives and declared entry compatibility" {
  grep -qi 'declares Owner instructions required' "$HUNT"
  grep -qi 'compatibility restriction' "$HUNT"
  grep -qi 'declared open-ended' "$HUNT"
  grep -qF 'Ending: open-ended' "$START"
}
