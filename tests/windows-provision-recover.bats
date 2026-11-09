load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/provision-recover-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
WIN="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows"
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
  windows_module_source | grep -qF "\$document['detail'] = 'no transaction'"
  windows_module_source | grep -qF "\$document['rolledBack'] = \$true"
  windows_module_source | grep -qF "\$document['proven'] = \$true"
  windows_module_source | grep -qF "\$document['finished'] = \$true"
  windows_module_source | grep -qF "\$document['malformed'] = \$true"
  windows_module_source | grep -qF "'malformed transaction: ' + \$field"
  windows_module_source | grep -qF 'ConvertTo-NSCanonicalJson $Document -Compact'
}

@test "the proof details and malformed field names are the frozen strings" {
  windows_module_source | grep -qF "'restored bytes do not match baseline digest: '"
  windows_module_source | grep -qF "'baseline file missing after restore: '"
  windows_module_source | grep -qF "'a directory blocks the baseline path: '"
  windows_module_source | grep -qF "'created path still present: '"
  windows_module_source | grep -qF "'baseline[\"' + [string]\$rel + '\"]'"
  windows_module_source | grep -qF "(\$label + '.existed')"
  windows_module_source | grep -qF "(\$label + '.digest')"
  windows_module_source | grep -qF "(\$label + '.blob')"
}

@test "the Windows seatbelt takes the four verbs and no plan or apply" {
  grep -qF "@('baseline', 'diff', 'rollback', 'recover')" "$WIN/provision.ps1"
  for fn in Invoke-NSProvisionPlan Invoke-NSProvisionApply Get-NSProvisionSkipReasons; do
    if windows_module_source | grep -qF -- "$fn"; then
      echo "module still carries $fn"
      return 1
    fi
  done
  # The seatbelt dispatch takes recover and rollback and nothing else.
  for verb in "'plan'" "'apply'"; do
    if windows_module_source | sed -n '/^function Invoke-NSProvisionCommand/,/^}/p' | grep -qF -- "$verb"; then
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
  windows_module_source | grep -qF "'provision transaction stage='"
  windows_module_source | grep -qF "'provision-transaction.json is malformed ('"
  grep -qF 'Doctor names the stage, the capability and a provable baseline' "$LOGIC"
  grep -qF 'Doctor names a baseline that would not prove' "$LOGIC"
  grep -qF 'Doctor names the malformed field' "$LOGIC"
  grep -qF 'diagnose prints the class and the sentence on one tab-separated line' "$LOGIC"
  grep -qF 'with no engine transaction the seatbelt recover answers' "$LOGIC"
  grep -qF 'diagnose classes an unprovable baseline' "$LOGIC"
  grep -qF 'diagnose classes a malformed transaction' "$LOGIC"
  grep -qF 'diagnose changes nothing' "$LOGIC"
}

@test "Windows provisioning logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh not installed'
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
