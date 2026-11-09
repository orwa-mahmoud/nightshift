#!/usr/bin/env bats
# SEO evidence — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
SEO="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/seo-audit.md"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/seo-live-crawl.md"

@test "seo-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/seo-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/seo-evidence.py" ]
}
