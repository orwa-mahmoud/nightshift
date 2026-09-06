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

@test "Quality skill does not require the workflow helpers" {
  if grep -qF 'runtime/quality-workflow.sh' "$QUALITY_SKILL"; then
    return 1
  fi
  if grep -qF 'runtime/quality-scan.sh' "$QUALITY_SKILL"; then
    return 1
  fi
  if grep -qF 'quality-workflow' "$QUALITY_SKILL"; then
    return 1
  fi
  if grep -qF 'quality-scan' "$QUALITY_SKILL"; then
    return 1
  fi
  if grep -qF 'compose-discovery' "$QUALITY_SKILL"; then
    return 1
  fi
  if grep -qF 'python3' "$QUALITY_SKILL"; then
    return 1
  fi
  grep -qF "the project's own tools" "$QUALITY_SKILL"
  grep -qF 'unavailable' "$QUALITY_SKILL"
}

@test "receipt templates forbid the quality pipeline" {
  grep -qF 'quality-workflow.sh' "$TEMPLATES"
  grep -qF 'quality-scan.sh' "$TEMPLATES"
}

@test "clear-quality-debt ranks from what parsed and compares to a baseline" {
  grep -qi 'rank' "$CLEAR"
  grep -qi 'unavailable' "$CLEAR"
  grep -qi 'baseline' "$CLEAR"
  grep -qi 'dedupe' "$CLEAR"
}
