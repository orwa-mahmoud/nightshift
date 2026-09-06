#!/usr/bin/env bats
# Pull-request readiness — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
PR="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/pull-request-readiness.md"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "pr-readiness-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/pr-readiness-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/pr-readiness-evidence.py" ]
}

@test "pull-request readiness writes a receipt from the template" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$PR"
  if grep -qF 'runtime/pr-readiness-evidence.sh' "$PR"; then
    return 1
  fi
  grep -qF '# build-onboarding / pr-readiness / release-readiness' "$TEMPLATES"
}
