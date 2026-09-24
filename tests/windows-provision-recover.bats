load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/provision-recover-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
WIN="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows"
MODULE="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"
POSIX="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/provision.sh"

@test "Windows provisioning recovery suite is registered with run.ps1" {
  [ -f "$LOGIC" ]
  grep -qF 'provision-recover-logic.ps1' "$RUN"
}

@test "the Windows provisioning helpers are native and thin" {
  [ -f "$WIN/provision.ps1" ]
  grep -qF 'Invoke-NSProvisionCommand' "$WIN/provision.ps1"
  grep -qF 'Get-NSProvisionDiagnosisLine' "$WIN/doctor.ps1"
  if grep -RE 'brew |npm install|pip install|python3|jq is required' \
    "$WIN/provision.ps1" "$WIN/doctor.ps1"; then
    return 1
  fi
}

@test "the Windows provisioning verbs and flags match the POSIX helper" {
  grep -qF "@('baseline', 'diff', 'rollback', 'recover')" "$WIN/provision.ps1"
  grep -qF '[string[]]$Surface' "$WIN/provision.ps1"
  grep -qF '[switch]$Rollback' "$WIN/provision.ps1"
  grep -qF '[switch]$Diagnose' "$WIN/provision.ps1"
  for verb in baseline diff rollback recover; do
    grep -qF "provision.sh --project DIR $verb" "$POSIX" \
      || { echo "POSIX helper does not document $verb"; return 1; }
  done
}

@test "native recovery prints the frozen objects and exit codes" {
  grep -qF "\$document['detail'] = 'no transaction'" "$MODULE"
  grep -qF "\$document['rolledBack'] = \$true" "$MODULE"
  grep -qF "\$document['proven'] = \$true" "$MODULE"
  grep -qF "\$document['finished'] = \$true" "$MODULE"
  grep -qF "\$document['malformed'] = \$true" "$MODULE"
  grep -qF "'malformed transaction: ' + \$field" "$MODULE"
  grep -qF 'ConvertTo-NSCanonicalJson $Document -Compact' "$MODULE"
}

@test "the proof details and malformed field names are the frozen strings" {
  grep -qF "'restored bytes do not match baseline digest: '" "$MODULE"
  grep -qF "'baseline file missing after restore: '" "$MODULE"
  grep -qF "'a directory blocks the baseline path: '" "$MODULE"
  grep -qF "'created path still present: '" "$MODULE"
  grep -qF "'baseline[\"' + [string]\$rel + '\"]'" "$MODULE"
  grep -qF "(\$label + '.existed')" "$MODULE"
  grep -qF "(\$label + '.digest')" "$MODULE"
  grep -qF "(\$label + '.blob')" "$MODULE"
}

@test "Windows provisioning logic covers rollback, the proof and the late stages" {
  grep -qF 'recover with no transaction reports the frozen object' "$LOGIC"
  grep -qF 'rollback restores the owner bytes from the blob store' "$LOGIC"
  grep -qF 'rollback restores from the recorded base64 when no blob is named' "$LOGIC"
  grep -qF 'rollback falls back to the recorded base64 when the blob file is gone' "$LOGIC"
  grep -qF 'a created file is removed' "$LOGIC"
  grep -qF 'an emptied parent is pruned' "$LOGIC"
  grep -qF 'pruning stops at the work target' "$LOGIC"
  grep -qF 'nothing to restore from leaves the file alone' "$LOGIC"
  grep -qF 'an unproven restore leaves the transaction in place' "$LOGIC"
  grep -qF 'an unproven rollback never deletes owner work' "$LOGIC"
  grep -qF 'the proof reports a baseline file that never came back' "$LOGIC"
  grep -qF 'the proof reports a directory blocking the baseline path' "$LOGIC"
  grep -qF 'a blocking directory is never deleted' "$LOGIC"
  grep -qF 'the late stages commit the tooling under one subject' "$LOGIC"
  grep -qF 'the row records the setup commit' "$LOGIC"
  grep -qF 'finishing clears the blob store too' "$LOGIC"
  grep -qF 'nothing staged is not a failure and not a commit' "$LOGIC"
  grep -qF 'the rollback verb undoes a late stage instead of finishing it' "$LOGIC"
  grep -qF 'recover -Rollback forces the undo whatever the stage' "$LOGIC"
  grep -qF 'a failed transaction rolls back rather than finishes' "$LOGIC"
}

@test "Windows provisioning logic covers every malformed field" {
  grep -qF 'a malformed transaction touches no file' "$LOGIC"
  grep -qF 'a transaction that is not JSON names the document' "$LOGIC"
  grep -qF 'an unknown stage is named' "$LOGIC"
  grep -qF 'an empty capabilityId is named' "$LOGIC"
  grep -qF 'a malformed workTarget is named' "$LOGIC"
  grep -qF 'a malformed failed flag is named' "$LOGIC"
  grep -qF 'a malformed touched list is named' "$LOGIC"
  grep -qF 'a malformed baseline is named' "$LOGIC"
  grep -qF 'a baseline entry with no existed flag is named down to the field' "$LOGIC"
  grep -qF 'a missing digest is named down to the field' "$LOGIC"
  grep -qF 'a malformed blob address is named down to the field' "$LOGIC"
  grep -qF 'a path outside the work target is named as the entry' "$LOGIC"
  grep -qF 'the digest is compared, never shape-checked' "$LOGIC"
  grep -qF 'undecodable baseline bytes never overwrite the tree' "$LOGIC"
}

@test "Windows provisioning logic covers the refused verbs" {
  grep -qF 'is not a seatbelt verb' "$LOGIC"
  grep -qF 'prints the seatbelt usage' "$LOGIC"
  grep -qF 'opens no transaction' "$LOGIC"
  grep -qF 'writes nothing into the work target' "$LOGIC"
  grep -qF 'baseline without a surface is a usage error' "$LOGIC"
}

@test "the Windows seatbelt takes the four verbs and no plan or apply" {
  grep -qF "@('baseline', 'diff', 'rollback', 'recover')" "$WIN/provision.ps1"
  for fn in Invoke-NSProvisionPlan Invoke-NSProvisionApply Get-NSProvisionSkipReasons; do
    if grep -qF -- "$fn" "$MODULE"; then
      echo "module still carries $fn"
      return 1
    fi
  done
  # The seatbelt dispatch takes recover and rollback and nothing else.
  for verb in "'plan'" "'apply'"; do
    if sed -n '/^function Invoke-NSProvisionCommand/,/^}/p' "$MODULE" | grep -qF -- "$verb"; then
      echo "the dispatch still branches on $verb"
      return 1
    fi
  done
}

@test "Windows Doctor and diagnose print the one diagnosis line" {
  grep -qF 'Get-NSProvisionDiagnosisClass' "$WIN/doctor.ps1"
  grep -qF 'Start will refuse to arm' "$WIN/doctor.ps1"
  grep -qF 'provision-transaction.json cannot be read; Start will refuse to arm' "$WIN/doctor.ps1"
  grep -qF "inspect \$(Get-NSLayoutName \$ns 'provision-transaction') and \$(Get-NSLayoutName \$ns 'provision-baseline')/" "$WIN/doctor.ps1"
  grep -qF 'Doctor never recovers' "$WIN/doctor.ps1"
  grep -qF "'provision transaction stage='" "$MODULE"
  grep -qF "'provision-transaction.json is malformed ('" "$MODULE"
  grep -qF 'Doctor names the stage, the capability and a provable baseline' "$LOGIC"
  grep -qF 'Doctor names a baseline that would not prove' "$LOGIC"
  grep -qF 'Doctor names the malformed field' "$LOGIC"
  grep -qF 'diagnose prints the class and the sentence on one tab-separated line' "$LOGIC"
  grep -qF 'with no engine transaction the seatbelt recover answers' "$LOGIC"
  grep -qF 'diagnose classes an unprovable baseline' "$LOGIC"
  grep -qF 'diagnose classes a malformed transaction' "$LOGIC"
  grep -qF 'diagnose changes nothing' "$LOGIC"
}

@test "Windows provisioning logic checks exact byte formatting" {
  grep -qF 'Test-NSNoCarriageReturn' "$LOGIC"
  grep -qF 'Test-NSSingleTrailingNewline' "$LOGIC"
  grep -qF 'Test-NSAsciiOnly' "$LOGIC"
  grep -qF 'Test-NSHasBom' "$LOGIC"
  grep -qF '{"detail":"no transaction","ok":true,"recovered":false}' "$LOGIC"
  grep -qF 'the inventory is pretty-printed with two spaces' "$LOGIC"
  grep -qF 'the inventory sorts its keys' "$LOGIC"
}

@test "Windows provisioning logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh not installed'
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
