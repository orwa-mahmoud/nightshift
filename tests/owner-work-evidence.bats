#!/usr/bin/env bats
# Owner-defined work — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "owner-work-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/owner-work-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/owner-work-evidence.py" ]
}

@test "owner-work contracts write receipts without the wrapper" {
  for f in github-issue-hunt owner-walkthrough standing-loop; do
    path="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/$f.md"
    [ -f "$path" ] || continue
    grep -qF 'receipts/cycle-specialist-evidence.md' "$path" || { echo "missing template: $f"; return 1; }
    ! grep -qF 'runtime/owner-work-evidence.sh' "$path" || { echo "still calls helper: $f"; return 1; }
  done
  grep -qF '# engineering / product-truth / specialist / operational / migration / owner-work' "$TEMPLATES"
}
