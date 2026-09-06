#!/usr/bin/env bats
# Build / onboarding — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "build-onboarding-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/build-onboarding-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/build-onboarding-evidence.py" ]
}

@test "onboarding and repro contracts write receipts without the wrapper" {
  for f in developer-onboarding build-reproducibility; do
    path="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/$f.md"
    grep -qF 'receipts/cycle-specialist-evidence.md' "$path" || { echo "missing template: $f"; return 1; }
    ! grep -qF 'runtime/build-onboarding-evidence.sh' "$path" || { echo "still calls helper: $f"; return 1; }
  done
  grep -qF '# build-onboarding / pr-readiness / release-readiness' "$TEMPLATES"
}
