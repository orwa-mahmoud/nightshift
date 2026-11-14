PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
START="$PLUGIN/skills/start/SKILL.md"
TEMPLATES="$PLUGIN/skills/nightshift/references/receipts/morning.md"

@test "the receipt templates carry the morning receipt block" {
  grep -qF '# Morning receipt' "$TEMPLATES"
  grep -qF 'The clock-out gate renders this page' "$TEMPLATES"
  grep -qF 'Receipts:' "$TEMPLATES"
  grep -qF -- '- [index] (./README.md)' "$TEMPLATES"
  grep -qF -- '- Policy record:' "$TEMPLATES"
  for field in '- Shift:' '- Ending:' '- Gates:' '- Verified:' '- Disabled by owner:' \
    '- Unavailable:'; do
    grep -qF -- "$field" "$TEMPLATES" || { echo "missing field: $field"; return 1; }
  done
}

@test "the hand-written page carries every verdict section" {
  for heading in '## How it ended' '## Time and tokens' '## Items' '## Review first' \
    '## Interruptions' '## Decisions for you' '## Found but not fixed' '## Next step'; do
    grep -qxF "$heading" "$TEMPLATES" || { echo "missing: $heading"; return 1; }
  done
}
