E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/runbook-verification.md"

@test "runbook verification uses operational evidence helpers" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "runbook verification names safe environment and observability mode" {
  grep -qi 'Observability/diagnostics mode' "$E"
  grep -qi 'safe/disposable environment' "$E"
}

@test "runbook verification refuses vendor imposition and destructive steps" {
  grep -qi 'Never impose a vendor' "$E"
  grep -qi 'destructive emergency steps' "$E"
  grep -qi 'assume telemetry reached production' "$E"
}

@test "runbook verification has a finite verified ending" {
  grep -qi 'Ends when every in-scope step is verified' "$E"
  grep -qi 'item gate is green at every commit' "$E"
}
