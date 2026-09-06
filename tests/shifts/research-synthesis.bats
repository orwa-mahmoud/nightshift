E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/research-synthesis.md"
CHECK="$BATS_TEST_DIRNAME/../../plugins/nightshift/runtime/check-report.sh"
FIXTURE="$BATS_TEST_DIRNAME/../fixtures/research-synthesis"

@test "research synthesis competitive and analytics modes use specialist gates" {
  grep -qi 'Competitive-landscape mode' "$E"
  grep -qi 'Product-analytics investigation mode' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'generic dashboard' "$E"
  grep -qi 'causal claim from correlation' "$E"
}

@test "research synthesis compares sources and refuses filled-in gaps" {
  grep -qi 'Discovery' "$E"
  grep -qi 'agreement and contradiction' "$E"
  grep -qi 'never filled in' "$E"
  grep -qi 'confidence and limits' "$E"
}

@test "research synthesis resolves source policy and redacts untrusted material" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'primary' "$E"
  grep -qi 'secondary' "$E"
  grep -qi 'community' "$E"
  grep -qF 'git init' "$E"
}

@test "research synthesis keeps resumable notes and artifact receipts" {
  grep -qi 'notes file' "$E"
  grep -qi 'resume' "$E"
  grep -qi 'write-receipt' "$E"
  grep -qF '$NS/receipts/' "$E"
  grep -qi 'Artifact mode' "$E"
}

@test "research synthesis is finite and inherits cited research" {
  grep -qi 'Ends when every supplied source' "$E"
  grep -qF 'cited-research.md' "$E"
  grep -qF 'check-report.sh' "$E"
  grep -qF 'check-report.ps1' "$E"
  grep -qi 'item gate' "$E"
  grep -qi 'green at every commit' "$E"
}

@test "research synthesis fixture exposes a conflict and incomplete access" {
  grep -q 'Friday' "$FIXTURE/source-a.md"
  grep -q 'Monday' "$FIXTURE/source-b.md"
  grep -qF '[S1]' "$FIXTURE/notes.md"
  grep -qF '[S2]' "$FIXTURE/notes.md"
  grep -qi 'contradict' "$FIXTURE/synthesis.md"
  grep -q 'S3 unavailable' "$FIXTURE/synthesis.md"
  run bash "$CHECK" --project "$FIXTURE" --report "$FIXTURE/synthesis.md" \
    --manifest "$FIXTURE/sources.tsv" \
    --output "$FIXTURE/synthesis.md" --output "$FIXTURE/notes.md"
  [ "$status" -eq 0 ]
}
