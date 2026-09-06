#!/usr/bin/env bats
# Source policy — untrusted text is instructional. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"
CITED="$ROOT/plugins/nightshift/skills/nightshift/references/shift/cited-research.md"

@test "source-policy-evidence python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/source-policy-evidence.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/source-policy-evidence.py" ]
}

@test "skills write the receipt and forbid the removed scanner" {
  grep -qF 'Do not call' "$TEMPLATES"
  grep -qF 'source-policy-evidence.sh' "$TEMPLATES"
  grep -qF 'redact-untrusted' "$TEMPLATES"
  grep -qF 'are not Nightshift commands' "$TEMPLATES"
  grep -qF 'model is the boundary' "$CITED"
}
