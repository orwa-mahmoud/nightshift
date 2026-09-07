#!/usr/bin/env bats
# The fake untrusted-source scanner is gone. Nightshift does not ship a replacement.

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
TEMPLATES="$PLUGIN/skills/nightshift/references/receipts/source-policy.md"

@test "source-policy python wrapper is gone" {
  [ ! -e "$PLUGIN/runtime/source-policy-evidence.sh" ]
  [ ! -e "$PLUGIN/runtime/source-policy-evidence.py" ]
}

@test "redact-untrusted is not a shipped command" {
  ! grep -R --include='*.sh' --include='*.ps1' --include='*.py' -qF 'redact-untrusted' "$PLUGIN/runtime" \
    || { echo 'redact-untrusted still invoked from runtime'; return 1; }
  grep -qF 'are not Nightshift commands' "$TEMPLATES"
}
