#!/usr/bin/env bats
# Planner/preview/learning — unused after Automatic. Wrappers removed.

ROOT="$BATS_TEST_DIRNAME/.."
FIX="$ROOT/tests/fixtures/planning/automatic-10h"
SCHEMA_PY="$ROOT/tests/helpers/validate-json-schema.py"
PLAN_SCHEMA="$ROOT/plugins/nightshift/skills/nightshift/references/schemas/v1/shift-plan.json"
DISC_SCHEMA="$ROOT/plugins/nightshift/skills/nightshift/references/schemas/v1/plan-discovery.json"
LEARN_SCHEMA="$ROOT/plugins/nightshift/skills/nightshift/references/schemas/v1/plan-learning.json"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "planner preview and learning wrappers are gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/shift-planner.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/shift-planner.py" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/shift-preview.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/shift-preview.py" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/plan-learning.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/plan-learning.py" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/windows/shift-planner.ps1" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/windows/shift-preview.ps1" ]
}

@test "discovery and plan fixtures validate against schemas" {
  python3 "$SCHEMA_PY" "$DISC_SCHEMA" "$FIX/discovery.json"
  python3 "$SCHEMA_PY" "$PLAN_SCHEMA" "$FIX/expected-plan.json"
  [ -f "$LEARN_SCHEMA" ]
}

@test "every receipt page forbids the planner helpers" {
  # The names a model might try to run are forbidden on each page, so splitting the receipts cannot
  # quietly drop the list from one of them. Matched with the line breaks flattened: a re-wrap is
  # not a change of rule.
  R="$ROOT/plugins/nightshift/skills/nightshift/references/receipts"
  for f in "$R"/*.md; do
    flat="$(tr '\n' ' ' <"$f" | tr -s ' ')"
    printf '%s' "$flat" | grep -qF 'these names are not Nightshift commands' \
      || { echo "$(basename "$f") does not say the names are not commands"; return 1; }
    for h in 'shift-planner.sh' 'shift-preview.sh' 'plan-learning.sh'; do
      printf '%s' "$flat" | grep -qF "$h" \
        || { echo "$(basename "$f") does not forbid $h"; return 1; }
    done
  done
}

@test "Hunt Automatic does not require the planner or preview helpers" {
  hunt="$ROOT/plugins/nightshift/skills/hunt/SKILL.md"
  if grep -qF 'runtime/shift-planner.sh' "$hunt"; then
    return 1
  fi
  if grep -qF 'runtime/shift-preview.sh' "$hunt"; then
    return 1
  fi
  if grep -qF 'runtime/plan-learning.sh' "$hunt"; then
    return 1
  fi
  for helper in shift-planner shift-preview plan-learning; do
    ! grep -qF "$helper" "$hunt" || { echo "hunt still names $helper"; return 1; }
  done
}

@test "Quality Automatic does not require the planner or preview helpers" {
  quality="$ROOT/plugins/nightshift/skills/quality/SKILL.md"
  if grep -qF 'runtime/shift-planner.sh' "$quality"; then
    return 1
  fi
  if grep -qF 'runtime/shift-preview.sh' "$quality"; then
    return 1
  fi
  if grep -qF 'runtime/plan-learning.sh' "$quality"; then
    return 1
  fi
  for helper in shift-planner shift-preview plan-learning; do
    ! grep -qF "$helper" "$quality" || { echo "quality still names $helper"; return 1; }
  done
}
