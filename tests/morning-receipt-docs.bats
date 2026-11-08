README="$BATS_TEST_DIRNAME/../README.md"
DOC="$BATS_TEST_DIRNAME/../docs/morning-receipt.md"
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

@test "morning-receipt doc covers every section, view, and the zero-gate line" {
  for heading in '## What each section means' '## Which view is for whom' '## Determinism'; do
    grep -qF "$heading" "$DOC" || { echo "missing: $heading"; return 1; }
  done
  for section in 'How it ended** (`shift`)' 'Time and tokens** (`usage`)' 'Items** (`items`)' \
    'Review first** (`review`)' 'Interruptions** (`interruptions`)' \
    'Decisions for you** (`parked`)' 'Found but not fixed** (`snags`)' \
    'Baseline** (`baseline`)' 'What changed** (`changed`)' 'Architecture** (`architecture`)' \
    'Unsupported / unmeasured** (`unsupported`)' 'Next step** (`next`)'; do
    grep -qF "**$section" "$DOC" || { echo "missing section: $section"; return 1; }
  done
  grep -qF '`Verified:`' "$DOC"
  grep -qF '`Disabled by owner:`' "$DOC"
  grep -qF '`Unavailable:`' "$DOC"
  grep -qF 'Verified: none — verification level none (owner)' "$DOC"
  grep -qF '**owner**' "$DOC"
  grep -qF '**reviewer**' "$DOC"
  grep -qF '**release**' "$DOC"
  grep -qF '**artifact**' "$DOC"
  grep -qF 'no git terminology appears' "$DOC"
  grep -qF 'invents nothing' "$DOC"
  grep -qF 'never upgraded into proof' "$DOC"
  grep -qE 'ns"? morning-receipt' "$DOC"
  grep -qF 'ns.ps1 morning-receipt' "$DOC"
  grep -qF '.nightshift/receipts/morning-<YYYY-MM-DD>-<shiftId>.md' "$DOC"
  grep -qF '.nightshift/receipts/morning-<YYYY-MM-DD>.md' "$DOC"
}

@test "morning-receipt doc states what each verdict section guarantees" {
  grep -qF 'in UTC with the zone written out' "$DOC"
  grep -qF 'The reasons add up to the paused' "$DOC"
  grep -qF 'linked to its item receipt' "$DOC"
  grep -qF 'git log --stat <first>^..<last>' "$DOC"
  grep -qF 'wrapped lines are joined, never cut' "$DOC"
  grep -qF 'whose disposition is not `fixed`' "$DOC"
  grep -qF 'link every' "$DOC"
  for id in '`shift`' '`usage`' '`items`' '`review`' '`interruptions`' '`parked`' '`snags`' \
    '`baseline`' '`changed`' '`unsupported`' '`next`'; do
    grep -qF "$id" "$BATS_TEST_DIRNAME/../docs/knobs.md" || { echo "knobs.md misses $id"; return 1; }
  done
}

@test "the hand-written page carries every verdict section" {
  for heading in '## How it ended' '## Time and tokens' '## Items' '## Review first' \
    '## Interruptions' '## Decisions for you' '## Found but not fixed' '## Next step'; do
    grep -qxF "$heading" "$TEMPLATES" || { echo "missing: $heading"; return 1; }
  done
}
