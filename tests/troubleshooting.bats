README="$BATS_TEST_DIRNAME/../README.md"
DOC="$BATS_TEST_DIRNAME/../docs/troubleshooting.md"
COMMANDS="$BATS_TEST_DIRNAME/../docs/commands.md"
CHECKLIST="$BATS_TEST_DIRNAME/../docs/first-night-checklist.md"
HOW="$BATS_TEST_DIRNAME/../docs/how-it-works.md"
KNOBS="$BATS_TEST_DIRNAME/../docs/knobs.md"

@test "README and command docs link the troubleshooting tree" {
  grep -qF '[**Troubleshooting**](docs/troubleshooting.md)' "$README"
  grep -qF '[Troubleshooting](troubleshooting.md)' "$COMMANDS"
  grep -qF '[Troubleshooting](troubleshooting.md)' "$CHECKLIST"
}

@test "troubleshooting covers the decision branches against live paths" {
  for phrase in 'Where is the site?' 'Unsupported or malformed `state-version`' \
    'Invalid `.nightshift-link`' 'Wrong workspace' \
    'Unreadable rules' 'STOP vs stale arming' 'Missing session identity' \
    'Watchman stood down'; do
    grep -qF "$phrase" "$DOC" || { echo "missing branch: $phrase"; return 1; }
  done
  grep -qE 'ns"? migrate-state' "$DOC"
  grep -qE 'ns"? link-workspace' "$DOC"
  grep -qF '.nightshift-link' "$DOC"
  grep -qF 'work-target' "$DOC"
  grep -qF 'work-mode' "$DOC"
  grep -qF 'inspect the work target' "$DOC"
  grep -qF '.nightshift/receipts' "$DOC"
  grep -qF 'latest artifact receipt' "$DOC"
  grep -qF 'artifact receipts path is not a usable directory' "$DOC"
  grep -qF 'replace it rather than write-receipt' "$DOC"
  grep -qF 'cannot land receipts' "$DOC"
  grep -qF 'most recently written' "$DOC"
  grep -qE 'ns"? archive-receipts' "$DOC"
  grep -qF 'ns.ps1 archive-receipts' "$DOC"
  grep -qF 'Missing or empty receipts create no dated receipts folder' "$DOC"
  grep -qF 'Do not `git init` an artifact' "$DOC"
  grep -qF 'The GitHub issue hunt is skipped in artifact mode' "$DOC"
  grep -qF 'The defect hunt is skipped in artifact mode' "$DOC"
  grep -qF 'Documentation drift is skipped in artifact mode' "$DOC"
  grep -qF 'TODO and FIXME debt is skipped in artifact mode' "$DOC"
  grep -qF 'Coverage hunt is skipped in artifact mode' "$DOC"
  grep -qF 'Tooling quality-debt entries are skipped in artifact mode' "$DOC"
  grep -qF 'rules.json' "$DOC"
  grep -qF 'touch .nightshift/STOP' "$DOC"
  grep -qF 'A STOP next to the link file is not the order' "$DOC"
  grep -qF 'A STOP next to `.nightshift-link` is not' "$COMMANDS"
  grep -qF 'not beside `.nightshift-link`' "$CHECKLIST"
  grep -qF '.shift-armed' "$DOC"
  grep -qF '.shift-session' "$DOC"
  grep -qF 'watchMinutes' "$DOC"
  grep -qF 'leftover Shift contract' "$DOC"
  grep -qF 'leftover Shift contract' "$HOW"
  grep -qF 'Hunt or Quality when they start immediately' "$HOW"
  grep -qF 'Hunt or Quality when they start immediately' "$DOC"
  repair="$(awk '/^## 2\. Invalid/{p=1; next} /^## /{p=0} p' "$DOC")"
  # The repair names one verb, and says how to run it on native Windows.
  printf '%s\n' "$repair" | grep -qE 'ns"? link-workspace'
  printf '%s\n' "$repair" | grep -qF 'ns.ps1 link-workspace'
  grep -qF 'Get-Content -TotalCount 1 .nightshift\work-mode' "$DOC"
  grep -qF 'Get-Content -TotalCount 1 .nightshift\work-target' "$DOC"
  grep -qF 'Get-ChildItem .nightshift\receipts -ErrorAction SilentlyContinue' "$DOC"
  grep -qF 'ConvertFrom-Json | Out-Null' "$DOC"
  grep -qF 'Get-Content -TotalCount 5 .nightshift\STOP' "$DOC"
  grep -qF 'Get-Content -TotalCount 5 .nightshift\.shift-session' "$DOC"
  grep -qF 'Get-Content -Tail 40 .nightshift\shift-log.md' "$DOC"
}

@test "troubleshooting marks checks before repairs and splits the hosts" {
  grep -qF 'Read-only checks first' "$DOC"
  grep -qF '**Check.**' "$DOC"
  grep -qF '**Repair.**' "$DOC"
  grep -qF 'Claude Code' "$DOC"
  grep -qF 'Codex' "$DOC"
  grep -qF 'alive but errored is stood by' "$DOC"
  grep -qF 'owner pressed Esc — standing by' "$DOC"
  grep -qF 'shift is owned by' "$DOC"
}

@test "troubleshooting links resolve" {
  [ -f "$BATS_TEST_DIRNAME/../docs/knobs.md" ]
  [ -f "$BATS_TEST_DIRNAME/../docs/commands.md" ]
  [ -f "$BATS_TEST_DIRNAME/../docs/first-night-checklist.md" ]
  [ -f "$BATS_TEST_DIRNAME/../docs/shift-modes.md" ]
  grep -qF '[Shift modes](shift-modes.md)' "$DOC"
  [ -f "$BATS_TEST_DIRNAME/../SECURITY.md" ]
  [ -f "$BATS_TEST_DIRNAME/../.github/ISSUE_TEMPLATE/failed_shift.yml" ]
  grep -qF 'issues/new?template=failed_shift.yml' "$DOC"
  grep -qF '/workspace/scratch/' "$DOC"
}

@test "recovery docs separate unattended work from the manual UI refresh" {
  grep -qF 'owner does not need to watch it' "$README"
  grep -qF 'needs no owner monitoring' "$HOW"
  grep -qi 'looks stuck' "$HOW"
  grep -qF 'project-file activity' "$HOW"
  grep -qF 'owner does not need to watch the recovery' "$DOC"
  grep -qF 'without being watched' "$CHECKLIST"
  grep -qF 'does not require an owner to monitor it' "$KNOBS"

  for issue in 82655 28259 21743; do
    grep -q "/issues/$issue" "$README"
    grep -q "/issues/$issue" "$HOW"
    grep -q "/issues/$issue" "$DOC"
  done
  grep -qF 'not merely interface polish' "$HOW"
}
