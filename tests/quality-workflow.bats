#!/usr/bin/env bats
# Quality workflow — skill writes the receipt. Pipeline wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
QUALITY_SKILL="$ROOT/plugins/nightshift/skills/quality/SKILL.md"
CLEAR="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/clear-quality-debt.md"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "quality workflow and scan wrappers are gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/quality-workflow.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/quality-workflow.py" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/quality-scan.sh" ]
}
