#!/usr/bin/env bats
# Engineering-confidence — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "engineering-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/engineering-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/engineering-evidence.py" ]
}

@test "all six engineering-confidence contracts write receipts without the wrapper" {
  for f in flaky-test-repair ci-warning-cleanup dead-code-cleanup todo-fixme-debt vulnerability-sweep dependency-upgrade-sweep; do
    path="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/$f.md"
    grep -qF 'receipts/cycle-specialist-evidence.md' "$path" || { echo "missing template: $f"; return 1; }
    ! grep -qF 'runtime/engineering-evidence.sh' "$path" || { echo "still calls helper: $f"; return 1; }
  done
  grep -qF '# engineering / product-truth / specialist' "$TEMPLATES"
}
