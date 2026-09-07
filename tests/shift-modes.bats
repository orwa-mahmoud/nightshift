README="$BATS_TEST_DIRNAME/../README.md"
DOC="$BATS_TEST_DIRNAME/../docs/shift-modes.md"
COMMANDS="$BATS_TEST_DIRNAME/../docs/commands.md"
MODES="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md"

@test "README and commands link the shift-modes walkthroughs" {
  grep -qF '[Shift modes](docs/shift-modes.md)' "$README"
  grep -qF '[Shift modes](shift-modes.md)' "$COMMANDS"
}

@test "shift-modes covers each Guided/Automatic launch combination" {
  for heading in 'Guided + Review first' 'Guided + Run directly' \
    'Automatic + Review first' 'Automatic + Run directly'; do
    grep -qF "## $heading" "$DOC" || { echo "missing: $heading"; return 1; }
  done
  grep -qF 'read-only' "$DOC"
  grep -qF 'until you approve' "$DOC"
  grep -qF 'clock starts immediately' "$DOC"
  grep -qF 'hours are required' "$DOC" || grep -qF 'Hours are required' "$DOC"
  grep -qF 'Owner-selected catalog entries' "$DOC"
  grep -qF '.nightshift/receipts/' "$DOC"
  grep -qE 'ns"? archive-receipts' "$DOC"
  grep -qF 'ns.ps1 archive-receipts' "$DOC"
  grep -qF 'Missing or empty receipts create no dated receipts folder' "$DOC"
  grep -qF 'artifact receipts path is not a usable directory' "$DOC"
  grep -qF 'cannot land receipts' "$DOC"
  grep -qF 'do not prove the work' "$DOC"
  grep -qF '/nightshift:hunt' "$DOC"
  grep -qF 'Hunt Automatic for four hours' "$DOC"
  grep -qF 'Quality-debt entries are skipped' "$DOC"
  grep -qF 'GitHub issue hunt is skipped' "$DOC"
  grep -qF 'The defect hunt is skipped in artifact mode' "$DOC"
  grep -qF 'Documentation drift is skipped in artifact mode' "$DOC"
  grep -qF 'TODO and FIXME debt is skipped in artifact mode' "$DOC"
  grep -qF 'Coverage hunt is skipped in artifact mode' "$DOC"
  grep -qF 'Tooling quality-debt entries are skipped in artifact mode' "$DOC"
  grep -qF 'most recently written' "$DOC"
}

@test "how-it-works links the shift-modes walkthroughs" {
  grep -qF '[Shift modes](shift-modes.md)' "$BATS_TEST_DIRNAME/../docs/how-it-works.md"
}

@test "shift-modes relative links resolve" {
  [ -f "$MODES" ]
  [ -f "$BATS_TEST_DIRNAME/../docs/commands.md" ]
  [ -f "$BATS_TEST_DIRNAME/../docs/first-night-checklist.md" ]
  grep -qF 'execution-modes.md' "$DOC"
  grep -qF 'first-night-checklist.md' "$DOC"
  grep -qF 'commands.md' "$DOC"
}
