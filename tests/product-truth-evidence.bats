#!/usr/bin/env bats
# Product-truth — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "product-truth-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/product-truth-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/product-truth-evidence.py" ]
}

@test "all five product-truth contracts write receipts without the wrapper" {
  for f in api-contract-drift accessibility-repair localization-parity documentation-drift documentation-writing; do
    path="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/$f.md"
    grep -qF 'receipts/cycle-specialist-evidence.md' "$path" || { echo "missing template: $f"; return 1; }
    ! grep -qF 'runtime/product-truth-evidence.sh' "$path" || { echo "still calls helper: $f"; return 1; }
  done
  grep -qF '# engineering / product-truth / specialist' "$TEMPLATES"
}
