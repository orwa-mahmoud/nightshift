CHECK="$BATS_TEST_DIRNAME/../../plugins/nightshift/runtime/check-report.sh"
FIXTURE="$BATS_TEST_DIRNAME/../fixtures/seo-audit"

@test "SEO audit fixture is a cited local page plus unavailable remote evidence" {
  [ -f "$FIXTURE/index.html" ]
  grep -q '<title></title>' "$FIXTURE/index.html"
  grep -q 'rel="canonical"' "$FIXTURE/index.html"
  grep -q $'\tunavailable\t' "$FIXTURE/sources.tsv" || grep -q 'unavailable' "$FIXTURE/sources.tsv"
  grep -q 'example.invalid/robots.txt' "$FIXTURE/sources.tsv"
  run bash "$CHECK" --project "$FIXTURE" --report "$FIXTURE/audit.md" \
    --manifest "$FIXTURE/sources.tsv" --output "$FIXTURE/audit.md"
  [ "$status" -eq 0 ]
}
