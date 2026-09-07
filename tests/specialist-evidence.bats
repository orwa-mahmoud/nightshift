#!/usr/bin/env bats
# Specialist and product journey — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"
JOURNEY="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/product-journey.md"
DOCS="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/documentation-drift.md"
RESEARCH="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/research-synthesis.md"
CLEAR="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/clear-quality-debt.md"
VULN="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/vulnerability-sweep.md"

@test "specialist-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/specialist-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/specialist-evidence.py" ]
}

@test "product journey writes a receipt and keeps evidence modes" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$JOURNEY"
  grep -qF 'Do not call' "$JOURNEY" || grep -qF 'receipts/cycle-specialist-evidence.md' "$JOURNEY"
  grep -qi 'Error experience' "$JOURNEY"
  grep -qi 'Responsive / cross-browser' "$JOURNEY"
  grep -qi 'Accessibility journey' "$JOURNEY"
  grep -qF '# engineering / product-truth / specialist' "$TEMPLATES"
}

@test "parent contracts write receipts without calling the removed wrapper" {
  if grep -qF 'runtime/specialist-evidence.sh' "$DOCS"; then
    return 1
  fi
  if grep -qF 'runtime/specialist-evidence.sh' "$RESEARCH"; then
    return 1
  fi
  if grep -qF 'runtime/specialist-evidence.sh' "$CLEAR"; then
    return 1
  fi
  if grep -qF 'runtime/specialist-evidence.sh' "$VULN"; then
    return 1
  fi
  grep -qF 'receipts/cycle-specialist-evidence.md' "$DOCS"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$RESEARCH"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$CLEAR"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$VULN"
}
