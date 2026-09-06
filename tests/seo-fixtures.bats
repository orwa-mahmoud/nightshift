#!/usr/bin/env bats
# SEO evidence fixtures — Wave 1 schema and contract checks (no runtime helper yet).

ROOT="$BATS_TEST_DIRNAME/.."
FIX="$ROOT/tests/fixtures/seo"
SCHEMAS="$ROOT/plugins/nightshift/skills/nightshift/references/schemas/v1"
SCHEMA_PY="$ROOT/tests/helpers/validate-json-schema.py"
CONTRACT="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/seo-audit.md"

@test "local inventory fixture validates against local-inventory schema" {
  python3 "$SCHEMA_PY" "$SCHEMAS/local-inventory.json" "$FIX/local/static-site-inventory.json"
  jq -e '.evidenceMode == "local" and (.notMeasured | length) >= 5' "$FIX/local/static-site-inventory.json" >/dev/null
  jq -e '.orphanCandidates[0].inboundInternalLinks == 0' "$FIX/local/static-site-inventory.json" >/dev/null
}

@test "live crawl fixture validates against live-crawl schema" {
  python3 "$SCHEMA_PY" "$SCHEMAS/live-crawl.json" "$FIX/live/bounded-crawl-snapshot.json"
  jq -e '.approvedOrigins | length >= 1' "$FIX/live/bounded-crawl-snapshot.json" >/dev/null
  jq -e '[.pages[] | select(.maliciousPageInstructions.detected == true)] | length >= 1' \
    "$FIX/live/bounded-crawl-snapshot.json" >/dev/null
  jq -e '[.pages[] | select(.blockedReason != null)] | length >= 1' \
    "$FIX/live/bounded-crawl-snapshot.json" >/dev/null
}

@test "connected export fixture validates against connected-export schema" {
  python3 "$SCHEMA_PY" "$SCHEMAS/connected-export.json" "$FIX/connected/connected-export-sample.json"
  jq -e '.metricsDisclaimer.clicksNotSessions == true' "$FIX/connected/connected-export-sample.json" >/dev/null
  jq -e '.periodComparison.deltas | length >= 1' "$FIX/connected/connected-export-sample.json" >/dev/null
  jq -e '.segmentation.dimensions | index("query")' "$FIX/connected/connected-export-sample.json" >/dev/null
}

@test "connected raw CSV export samples exist" {
  [ -f "$FIX/connected/search-console-export.csv" ]
  [ -f "$FIX/connected/analytics-export.csv" ]
  grep -q 'seo audit checklist' "$FIX/connected/search-console-export.csv"
  grep -q 'Sessions' "$FIX/connected/analytics-export.csv"
}

@test "seo evidence schemas are draft-07 with stable ids" {
  for s in local-inventory live-crawl connected-export; do
    jq -e '.["$schema"] == "http://json-schema.org/draft-07/schema#"' "$SCHEMAS/$s.json" >/dev/null
    jq -e '.title | test("SEO")' "$SCHEMAS/$s.json" >/dev/null
    jq -e '.["$id"] | test("schemas/v1/'"$s"'")' "$SCHEMAS/$s.json" >/dev/null
  done
}

@test "seo audit contract documents Local Live and Connected evidence modes" {
  grep -qi 'Local' "$CONTRACT"
  grep -qi 'Live' "$CONTRACT"
  grep -qi 'Connected' "$CONTRACT"
  grep -qi 'not measured' "$CONTRACT" || grep -qi 'not-measured' "$CONTRACT" || grep -qi 'notMeasured' "$CONTRACT"
  grep -qi 'receipt' "$CONTRACT"
  grep -qi 'evidence mode' "$CONTRACT"
}

@test "seo audit contract writes a receipt without the removed helper" {
  if grep -qF 'runtime/seo-evidence.sh' "$CONTRACT"; then
    return 1
  fi
  grep -qF 'receipts/cycle-specialist-evidence.md' "$CONTRACT"
  grep -qF 'local-inventory' "$CONTRACT"
  grep -qF 'live-crawl' "$CONTRACT"
  grep -qF 'connected-export' "$CONTRACT"
}

@test "seo audit discovery documents mode selection" {
  grep -qi 'Discovery' "$CONTRACT"
  grep -qi 'owner-approved' "$CONTRACT"
  grep -qi 'mode' "$CONTRACT"
}

@test "fixtures README documents all three scenarios" {
  [ -f "$FIX/README.md" ]
  grep -qi 'Local' "$FIX/README.md"
  grep -qi 'Live' "$FIX/README.md"
  grep -qi 'Connected' "$FIX/README.md"
  grep -qi 'malicious' "$FIX/README.md"
  grep -qi 'clicks' "$FIX/README.md"
}
