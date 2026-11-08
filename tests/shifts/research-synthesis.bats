CHECK="$BATS_TEST_DIRNAME/../../plugins/nightshift/runtime/check-report.sh"
FIXTURE="$BATS_TEST_DIRNAME/../fixtures/research-synthesis"

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
