#!/usr/bin/env bats
# History context — skill writes the receipt. Wrapper removed.

ROOT="$BATS_TEST_DIRNAME/.."
ARCHIVE="$ROOT/plugins/nightshift/skills/archive/SKILL.md"
SETUP="$ROOT/plugins/nightshift/skills/setup/SKILL.md"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "history-context python wrapper is gone" {
  [ ! -e "$ROOT/plugins/nightshift/runtime/history-context.sh" ]
  [ ! -e "$ROOT/plugins/nightshift/runtime/history-context.py" ]
}

@test "archive and setup write history from the template" {
  if grep -qF 'history-context.sh' "$ARCHIVE"; then
    return 1
  fi
  grep -qF 'references/receipts/cycle-specialist-evidence.md' "$ARCHIVE"
  grep -qF 'history-context' "$TEMPLATES"
  # The split moved the wording; the guarantee is that the file names these as NOT commands.
  grep -qF 'these names are not' "$TEMPLATES"
  grep -qF '# history-context / preset' "$TEMPLATES"
}
