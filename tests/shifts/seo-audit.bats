E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/seo-audit.md"
CHECK="$BATS_TEST_DIRNAME/../../plugins/nightshift/runtime/check-report.sh"
FIXTURE="$BATS_TEST_DIRNAME/../fixtures/seo-audit"
WIN="$BATS_TEST_DIRNAME/../../plugins/nightshift/runtime/windows/check-report.ps1"

@test "SEO audit uses receipt templates and refuses live-crawl without budgets" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'Refuse live-crawl' "$E"
  grep -qF 'neverLeaveApprovedOrigins' "$E"
}

@test "SEO audit discovers only owner-approved sources" {
  grep -qi 'Discovery' "$E"
  grep -qi 'owner-approved' "$E"
  grep -qi 'Do not add URLs from memory' "$E"
}

@test "SEO audit evaluates on-page evidence and refuses invented access" {
  grep -qi 'canonicals' "$E"
  grep -qi 'structured data' "$E"
  grep -qi 'internal links' "$E"
  grep -qi 'Never' "$E" || grep -qi 'do not invent Search Console' "$E"
  grep -qi 'Search Console' "$E"
  grep -qi 'analytics' "$E"
  grep -qi 'backlink' "$E"
  grep -qi 'ranking' "$E"
}

@test "SEO audit is finite and splits review-first from direct mode" {
  grep -qi 'Ends when every supplied source' "$E"
  grep -qi 'Review first writes the report' "$E"
  grep -qi 'Direct mode may edit authorized local' "$E"
  grep -qi 'never publishes' "$E"
}

@test "SEO audit inherits cited research and gates every receipt" {
  grep -qF 'cited-research.md' "$E"
  grep -qF 'check-report.sh' "$E"
  grep -qF 'check-report.ps1' "$E"
  grep -qi 'item gate is green' "$E"
  grep -qF '$NS/receipts/' "$E"
  [ -f "$WIN" ]
  grep -qF 'fabricated citation' "$WIN"
}

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
