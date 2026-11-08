#!/usr/bin/env bats
# One sentence starts a shift: a plain request reaches Hunt, a new project is set up first, a
# missing time budget is one question, and "auto" resolves to a stated deadline.

ROOT="$BATS_TEST_DIRNAME/.."
SKILLS="$ROOT/plugins/nightshift/skills"
HUNT="$SKILLS/hunt/SKILL.md"
BRAIN="$SKILLS/nightshift/SKILL.md"
TEMPLATE="$SKILLS/nightshift/references/nightshift-rules-template.json"

@test "a plain request with a time budget reaches Hunt from every entry point" {
  # The description the host matches a sentence against names the plain form.
  sed -n '1,5p' "$HUNT" | grep -qF 'improve this project for 5 hours'
  # The brain skill, which hosts may load first, hands such a sentence to Hunt instead of Start.
  grep -qF 'is a Hunt request: follow Hunt' "$BRAIN"
  grep -qF 'improve this project for 5 hours' "$BRAIN"
}

@test "a new project is set up inside the same request, never sent away" {
  grep -qF "run Setup's flow" "$HUNT"
  grep -qF 'then continue with the same sentence' "$HUNT"
  grep -qF 'Never send the owner away to run Setup' "$HUNT"
  if grep -qF 'tell the owner to
run Setup, then return' "$HUNT"; then
    return 1
  fi
}

@test "an objective plus hours is complete, and runs under the shipped execution" {
  grep -qF 'enhance my project for 5 hours' "$HUNT"
  grep -qF 'resolved `shift.execution`' "$HUNT"
  # Nothing asks review-first on a complete prompt; the shipped value is run-direct.
  grep -qF 'A complete prompt never asks this' "$HUNT"
  jq -e '.shift.execution == "run-direct"' "$TEMPLATE" >/dev/null
  if grep -qF 'clear direct-execution intent' "$HUNT"; then
    return 1
  fi
}
