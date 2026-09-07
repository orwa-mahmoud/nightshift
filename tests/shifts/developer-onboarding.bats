E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/developer-onboarding.md"
HUNT="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/hunt/SKILL.md"

@test "developer onboarding follows public checkout through one verified change" {
  grep -qi 'Discovery' "$E"
  grep -qi 'public checkout/setup path' "$E"
  grep -qi 'representative verified change' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "developer onboarding applies a fresh-reader pass" {
  grep -qi 'fresh-reader pass' "$E"
  grep -qi 'ambiguous commands' "$E"
  grep -qi 'Never skip the fresh-reader pass' "$E"
}

@test "developer onboarding discovers hidden prerequisites and broken commands" {
  grep -qi 'prerequisite' "$E"
  grep -qi 'broken commands' "$E"
  grep -qi 'hidden prerequisites' "$E"
}

@test "developer onboarding never imposes a new setup stack" {
  grep -qi 'Never impose a container' "$E"
  grep -qi 'package manager' "$E"
  grep -qi 'setup stack' "$E"
}

@test "developer onboarding records environmental blockers honestly" {
  grep -qi 'unsupported platform' "$E"
  grep -qi 'environmental blockers' "$E"
  grep -qi 'Never claim onboarding works on an unsupported platform' "$E"
  grep -qi 'Refuse owner-only install' "$E"
}

@test "developer onboarding is finite repository mode with item gate" {
  head -n1 "$E" | grep -q '— finite —'
  grep -qi 'Never select this entry when work mode is artifact' "$E"
  grep -qi 'Ends when the documented journey' "$E"
  grep -qi 'item gate is green at every commit' "$E"
  grep -qi 'snag-log.md' "$E"
}

@test "developer onboarding declares supported stacks" {
  grep -qi 'Supported on repositories' "$E"
  grep -qi 'in-tree setup documentation' "$E"
}
