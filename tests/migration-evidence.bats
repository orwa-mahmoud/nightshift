#!/usr/bin/env bats
# Migration evidence — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "migration-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/migration-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/migration-evidence.py" ]
}

@test "migration contracts write receipts without the wrapper" {
  for f in migration-compatibility; do
    path="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/$f.md"
    [ -f "$path" ] || continue
    grep -qF 'receipts/cycle-specialist-evidence.md' "$path" || { echo "missing template: $f"; return 1; }
    ! grep -qF 'runtime/migration-evidence.sh' "$path" || { echo "still calls helper: $f"; return 1; }
  done
  grep -qF '# engineering / product-truth / specialist / operational / migration / owner-work' "$TEMPLATES"
}
