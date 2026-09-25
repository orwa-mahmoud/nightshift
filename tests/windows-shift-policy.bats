load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/shift-policy-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
WIN="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows"
MODULE="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"

@test "Windows shift-policy logic suite is registered with run.ps1" {
  [ -f "$LOGIC" ]
  grep -qF 'shift-policy-logic.ps1' "$RUN"
}

@test "the Windows shift-policy helpers are native and thin" {
  [ -f "$WIN/shift-policy.ps1" ]
  [ -f "$WIN/park-needs.ps1" ]
  [ ! -e "$WIN/capability-policy.ps1" ]
  grep -qF 'Invoke-NSShiftPolicyCommand' "$WIN/shift-policy.ps1"
  grep -qF 'Invoke-NSParkNeedsCommand' "$WIN/park-needs.ps1"
  if grep -RE 'brew |npm install|pip install|python3|jq is required' "$WIN/shift-policy.ps1" "$WIN/park-needs.ps1"; then
    return 1
  fi
}

@test "the resolver reports every frozen setting with source and expiry" {
  for name in verificationLevel toolingPolicy deadlineEpoch forbiddenCommands \
    protectedDirs neverCommitPatterns expectedEmail stallMax watchMinutes; do
    grep -qF "'$name'" "$MODULE"
  done
  grep -qF "'elevation.' + \$category" "$MODULE"
  grep -qF "\$document['schemaVersion'] = 1" "$MODULE"
  grep -qF "\$document['settings'] = \$resolution['settings']" "$MODULE"
  grep -qF "'{0}={1} ({2}, {3})'" "$MODULE"
}

@test "Windows shift-policy logic covers every precedence row" {
  grep -qF 'is denied by default' "$LOGIC"
  grep -qF 'a rules.elevation allow lifts the built-in deny permanently' "$LOGIC"
  grep -qF 'a one-shift allowance alone lifts the deny for tonight' "$LOGIC"
  grep -qF 'a category allowance beside an exact plan wins' "$LOGIC"
  grep -qF 'protected paths stay rules-only under a category allowance' "$LOGIC"
  grep -qF 'never becomes an effective verification level' "$LOGIC"
  grep -qF 'a malformed policy grants no allowance' "$LOGIC"
  grep -qF 'the resolver names the exact field' "$LOGIC"
}

@test "Windows shift-policy logic covers exact-plan binding and the armed refusal" {
  grep -qF 'whitespace collapses before the exact match' "$LOGIC"
  grep -qF 'a neighbouring command is an exact-plan mismatch, not a deny' "$LOGIC"
  grep -qF 'a plan approved for another work target is a mismatch' "$LOGIC"
  grep -qF 'a plan whose digest does not recompute is a mismatch' "$LOGIC"
  grep -qF 'a plan digested under another shift identity is a replay and denies' "$LOGIC"
  grep -qF 'an expired plan is a mismatch' "$LOGIC"
  grep -qF 'a plan whose expiry is still ahead binds' "$LOGIC"
  grep -qF 'a plan whose expiry has passed does not bind' "$LOGIC"
  grep -qF 'a null expiry defers to the shift deadline and binds' "$LOGIC"
  grep -qF 'plan.expiry is outside the digest preimage' "$LOGIC"
  grep -qF "'commands', 'workTarget', 'digest', 'expiry'" "$MODULE"
  grep -qF 'plan.expiry is checked before the digest, never inside it' "$MODULE"
  grep -qF 'set is refused while the shift is armed' "$LOGIC"
  grep -qF 'archive files the policy at its live path in the shift folder' "$LOGIC"
}

@test "Windows shift-policy logic checks exact byte formatting" {
  grep -qF 'Test-NSNoCarriageReturn' "$LOGIC"
  grep -qF 'Test-NSSingleTrailingNewline' "$LOGIC"
  grep -qF 'Test-NSAsciiOnly' "$LOGIC"
  grep -qF 'Test-NSKeysSorted' "$LOGIC"
  grep -qF 'Test-NSHasBom' "$LOGIC"
  grep -qF '{"schemaVersion":1,"settings":{' "$LOGIC"
}

@test "Windows Doctor and support render the resolved view, never the policy files" {
  grep -qF 'resolved policy' "$WIN/doctor.ps1"
  grep -qF 'Format-NSPolicyTable' "$WIN/doctor.ps1"
  grep -qF 'does not match shift-policy deadlineEpoch' "$WIN/doctor.ps1"
  grep -qF 'shift-policy.json is malformed' "$WIN/doctor.ps1"
  if grep -qF 'capability policy' "$WIN/doctor.ps1"; then
    return 1
  fi
  grep -qF '== resolved policy ==' "$WIN/export-support.ps1"
  grep -qF '<redacted ' "$WIN/export-support.ps1"
  if grep -qF 'capability-policy' "$WIN/export-support.ps1"; then
    return 1
  fi
}

@test "Windows migrate-state previews by default and moves only with -Apply" {
  grep -qF '[switch]$Apply' "$WIN/migrate-state.ps1"
  grep -qF 'Invoke-NSMigrationApply $workspace $records' "$WIN/migrate-state.ps1"
  if grep -qF 'capability-policy' "$WIN/migrate-state.ps1"; then
    return 1
  fi
}

@test "Windows shift-policy logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh not installed'
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
