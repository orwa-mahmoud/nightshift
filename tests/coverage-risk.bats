#!/usr/bin/env bats
# Coverage hunt — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
COVERAGE="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/coverage-hunt.md"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "coverage-risk python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/coverage-risk.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/coverage-risk.py" ]
}
