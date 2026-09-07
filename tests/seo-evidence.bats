#!/usr/bin/env bats
# SEO evidence — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
SEO="$ROOT/plugins/nightshift/skills/nightshift/references/compose/shifts/seo-audit.md"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/seo-live-crawl.md"

@test "seo-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/seo-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/seo-evidence.py" ]
}

@test "seo audit writes a receipt and refuses invented live-crawl" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$SEO"
  if grep -qF 'runtime/seo-evidence.sh' "$SEO"; then
    return 1
  fi
  # The split put each kind in its own file: the block that shapes an SEO receipt, and the rules
  # for a live crawl.
  grep -qF '# seo' "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"
  grep -qF 'Refuse live-crawl' "$TEMPLATES"
  grep -qF 'neverLeaveApprovedOrigins' "$TEMPLATES"
}
