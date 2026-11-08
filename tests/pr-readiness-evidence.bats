#!/usr/bin/env bats
# Pull-request readiness — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
PR="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/pull-request-readiness.md"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "pr-readiness-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/pr-readiness-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/pr-readiness-evidence.py" ]
}
