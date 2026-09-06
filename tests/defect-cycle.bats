#!/usr/bin/env bats
# Defect hunt — skill writes the cycle receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
DEFECT="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/defect-hunt.md"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "defect-cycle python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/defect-cycle.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/defect-cycle.py" ]
}

@test "defect hunt writes a cycle receipt and keeps the lenses" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$DEFECT"
  if grep -qF 'runtime/defect-cycle.sh' "$DEFECT"; then
    return 1
  fi
  grep -qi 'reproduction or strong code-path evidence' "$DEFECT"
  grep -qi 'rejected and duplicate' "$DEFECT"
  grep -qi 'containing regression surface' "$DEFECT"
  grep -qF '# defect-cycle' "$TEMPLATES"
  grep -qF 'correctness|state|error-handling' "$TEMPLATES"
}
