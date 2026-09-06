#!/usr/bin/env bats
# Operational evidence — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "operational-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/operational-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/operational-evidence.py" ]
}

@test "operational contracts write receipts without the wrapper" {
  for f in performance-regression incident-follow-up runbook-verification toil-reduction; do
    path="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/$f.md"
    grep -qF 'receipts/cycle-specialist-evidence.md' "$path" || { echo "missing template: $f"; return 1; }
    ! grep -qF 'runtime/operational-evidence.sh' "$path" || { echo "still calls helper: $f"; return 1; }
  done
  grep -qF '# engineering / product-truth / specialist / operational / migration / owner-work' "$TEMPLATES"
}
