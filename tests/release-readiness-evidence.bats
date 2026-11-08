#!/usr/bin/env bats
# Release readiness — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
RR="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/release-readiness.md"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "release-readiness-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/release-readiness-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/release-readiness-evidence.py" ]
}
