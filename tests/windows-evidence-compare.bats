load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/evidence-compare-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
WIN="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows"

@test "Windows comparison logic suite is registered with run.ps1" {
  [ -f "$LOGIC" ]
  grep -qF 'evidence-compare-logic.ps1' "$RUN"
}

@test "the Windows comparison helper is native and thin" {
  [ -f "$WIN/evidence-compare.ps1" ]
  grep -qF 'Invoke-NSEvidenceCompareCommand' "$WIN/evidence-compare.ps1"
  if grep -RE 'brew |npm install|pip install|python3|jq is required' \
    "$WIN/evidence-compare.ps1"; then
    return 1
  fi
}

@test "the ledger is the only writer of a baseline or checkpoint record" {
  for helper in evidence-baseline.sh evidence-checkpoint.sh; do
    [ ! -e "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/$helper" ]
  done
  for helper in evidence-baseline.ps1 evidence-checkpoint.ps1; do
    [ ! -e "$WIN/$helper" ]
  done
  for fn in Write-NSEvidenceBaseline Write-NSEvidenceCheckpoint New-NSLifecycleRecord; do
    if windows_module_source | grep -qF "function $fn"; then
      echo "module still carries $fn"
      return 1
    fi
  done
}

@test "the comparison carries every frozen class and JSON key" {
  for class in new cleared unchanged regressed unavailable rejected-duplicate parked human-only; do
    windows_module_source | grep -qF "'$class'"
  done
  windows_module_source | grep -qF "\$document['baseline'] = \$Baseline"
  windows_module_source | grep -qF "\$document['mode'] = \$mode"
  windows_module_source | grep -qF "\$document['pass'] = \$pass"
  windows_module_source | grep -qF "\$document['rows'] = \$rows.ToArray()"
  windows_module_source | grep -qF "\$document['schemaVersion'] = 1"
  windows_module_source | grep -qF "\$document['summary'] = \$summary"
  windows_module_source | grep -qF "\$row['id']"
  windows_module_source | grep -qF "\$row['class']"
  windows_module_source | grep -qF "\$row['digest']"
  windows_module_source | grep -qF "\$row['sources']"
  windows_module_source | grep -qF "\$row['locator']"
  windows_module_source | grep -qF '| ID | Class | Digest | Sources | Locator |'
}

@test "the comparison reads the baseline details it was frozen against" {
  windows_module_source | grep -qF "Get-NSMapValue \$details 'seen'"
  windows_module_source | grep -qF "Get-NSRecordText \$details 'environmentDigest'"
  windows_module_source | grep -qF "@('baseline', 'checkpoint')"
  grep -qF "the comparison reads the environment digest off the record" "$LOGIC"
  grep -qF "the baseline record carries the baseline domain" "$LOGIC"
}

@test "the shift policy accepts completionMode and selectedDebt without resolving them" {
  windows_module_source | grep -qF "'completionMode', 'selectedDebt'"
  windows_module_source | grep -qF "\$script:NSPolicyCompletionModes = @('clear-all', 'no-regression-plus-selected-debt')"
  windows_module_source | grep -qF 'completionMode: must be one of '
  windows_module_source | grep -qF 'selectedDebt: must be an array of finding ids'
  grep -qF 'resolve does not report completionMode' "$LOGIC"
  grep -qF 'resolve does not report selectedDebt' "$LOGIC"
}

@test "Windows comparison logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh not installed'
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
