#!/usr/bin/env bats
# Coverage hunt — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
COVERAGE="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/coverage-hunt.md"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "coverage-risk python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/coverage-risk.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/coverage-risk.py" ]
}

@test "coverage hunt writes a risk receipt without the wrapper" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$COVERAGE"
  if grep -qF 'runtime/coverage-risk.sh' "$COVERAGE"; then
    return 1
  fi
  grep -qi 'behavior-protecting' "$COVERAGE"
  grep -qi 'misleading high coverage' "$COVERAGE"
  grep -qi 'mutation/property/fuzz' "$COVERAGE"
  grep -qi 'receipt line' "$COVERAGE"
  grep -qF '# coverage-risk' "$TEMPLATES"
}
