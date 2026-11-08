#!/usr/bin/env bats
# Defect hunt — skill writes the cycle receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
DEFECT="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/defect-hunt.md"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "defect-cycle python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/defect-cycle.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/defect-cycle.py" ]
}
