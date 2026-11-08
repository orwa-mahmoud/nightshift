CHECK="$BATS_TEST_DIRNAME/../../plugins/nightshift/runtime/check-report.sh"
FIXTURE="$BATS_TEST_DIRNAME/../fixtures/documentation-writing"

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
