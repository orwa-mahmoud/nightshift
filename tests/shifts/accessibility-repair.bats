E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/accessibility-repair.md"

@test "accessibility repair uses product-truth evidence report" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "accessibility repair requires existing configured checks" {
  grep -qi 'already configure' "$E"
  grep -qi 'must not start' "$E"
  grep -qi 'Do not add a scanner silently' "$E"
}

@test "accessibility repair limits work to objective violations" {
  grep -qi 'objective reported violations' "$E"
  grep -qi 'existing design system' "$E"
  grep -qi 'judgment-dependent' "$E"
}

@test "accessibility repair refuses redesign suppression and compliance claims" {
  grep -qi 'Never perform an unrelated visual redesign' "$E"
  grep -qi 'Never suppress a rule' "$E"
  grep -qi 'Never claim WCAG' "$E"
}

@test "accessibility repair reruns project checks to finish" {
  grep -qi 'Ends when the same configured checks' "$E"
  grep -qi 'item gate is green at every commit' "$E"
  grep -qi 'complete affected surface' "$E"
}
