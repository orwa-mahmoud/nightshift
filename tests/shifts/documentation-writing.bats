E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/documentation-writing.md"
CHECK="$BATS_TEST_DIRNAME/../../plugins/nightshift/runtime/check-report.sh"
FIXTURE="$BATS_TEST_DIRNAME/../fixtures/documentation-writing"
WIN="$BATS_TEST_DIRNAME/../../plugins/nightshift/runtime/windows/check-report.ps1"

@test "documentation writing uses product-truth outline helper" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "documentation writing resolves source policy for artifact folders" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'git init' "$E"
}

@test "documentation writing discovers named sources and refuses invented behaviour" {
  grep -qi 'Discovery' "$E"
  grep -qi 'owner-approved outline' "$E"
  grep -qi 'do not invent flags' "$E"
  grep -qi 'Never silently change project policy' "$E"
}

@test "documentation writing verifies links, examples, and both work modes" {
  grep -qi 'relative links' "$E"
  grep -qi 'fenced examples' "$E"
  grep -qi 'Repository mode' "$E"
  grep -qi 'Artifact mode' "$E"
  grep -qi 'write-receipt' "$E"
  grep -qF '$NS/receipts/' "$E"
}

@test "documentation writing is finite and inherits cited research" {
  grep -qi 'Ends when every supplied source' "$E"
  grep -qF 'cited-research.md' "$E"
  grep -qF 'check-report.sh' "$E"
  grep -qF 'check-report.ps1' "$E"
  grep -qi 'item gate is green' "$E"
  [ -f "$WIN" ]
}

@test "documentation writing fixture cites local evidence and records missing help" {
  [ -f "$FIXTURE/evidence.md" ]
  [ -f "$FIXTURE/guide.md" ]
  grep -q 'does not start work' "$FIXTURE/evidence.md"
  grep -qF '[S1]' "$FIXTURE/guide.md"
  grep -q 'S2 unavailable' "$FIXTURE/guide.md"
  grep -qF '](evidence.md)' "$FIXTURE/guide.md"
  [ -f "$FIXTURE/evidence.md" ]
  run bash "$CHECK" --project "$FIXTURE" --report "$FIXTURE/guide.md" \
    --manifest "$FIXTURE/sources.tsv" --output "$FIXTURE/guide.md"
  [ "$status" -eq 0 ]
}
