E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/product-journey.md"

@test "product journey requires explicit persona goal and steps" {
  grep -qi 'persona' "$E"
  grep -qi 'goal' "$E"
  grep -qi 'starting state' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "product journey modes stay on one entry" {
  grep -qi 'Error experience' "$E"
  grep -qi 'Responsive / cross-browser' "$E"
  grep -qi 'Accessibility journey' "$E"
  grep -qi 'not separate catalog items' "$E"
}

@test "product journey refuses certification and unavailable browser claims" {
  grep -qi 'Never claim whole-product usability' "$E"
  grep -qi 'never claim a platform' "$E"
  grep -qi 'browser behavior that was not observed' "$E"
  grep -qi 'Never select this entry when work mode is artifact' "$E"
}

@test "product journey fixes reproducible gaps and retests" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'reproducible gap' "$E"
}

@test "product journey is finite and gates every commit" {
  grep -qi 'Ends when every reproducible gap' "$E"
  grep -qi 'item gate is green at every commit' "$E"
}
