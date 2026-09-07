E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/migration-compatibility.md"

@test "migration compatibility requires named migration and authoritative guidance" {
  grep -qi 'Discovery' "$E"
  grep -qi 'named migration' "$E"
  grep -qi 'authoritative guidance' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "migration compatibility defaults to review-first for broad or irreversible risk" {
  grep -qi 'Review-first is the default' "$E"
  grep -qi 'run-direct may perform only bounded' "$E"
  grep -qi 'explicit non-goals' "$E"
  grep -qi 'rollback' "$E"
}

@test "configuration parity mode compares secret presence and shape only" {
  grep -qi 'Configuration parity mode' "$E"
  grep -qi 'presence and shape only' "$E"
  grep -qi 'never retrieve' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "data migration mode refuses production without owner approval" {
  grep -qi 'Data migration mode' "$E"
  grep -qi 'disposable or specifically owner-approved' "$E"
  grep -qi 'live production' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "migration compatibility never guesses legal or data authority" {
  grep -qi 'Never guess legal' "$E"
  grep -qi 'data-retention authority' "$E"
  grep -qi 'verdict' "$E"
  grep -qi 'legal or production authority was inferred' "$E"
}

@test "migration compatibility is finite repository mode with item gate" {
  head -n1 "$E" | grep -q '— finite —'
  grep -qi 'Never select this entry when work mode is artifact' "$E"
  grep -qi 'item gate is green at every commit' "$E"
  grep -qi 'snag-log.md' "$E"
  grep -qi 'finite status' "$E"
}
