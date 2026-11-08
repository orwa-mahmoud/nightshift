load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/preflight-needs-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
WIN="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows"

@test "Windows preflight-needs logic suite is registered with run.ps1" {
  [ -f "$LOGIC" ]
  grep -qF 'preflight-needs-logic.ps1' "$RUN"
}

@test "the Windows preflight helper is native and thin" {
  [ -f "$WIN/preflight-needs.ps1" ]
  grep -qF 'Invoke-NSPreflightNeedsCommand' "$WIN/preflight-needs.ps1"
  if grep -RE 'brew |npm install|pip install|python3|jq is required' "$WIN/preflight-needs.ps1"; then
    return 1
  fi
}

@test "preflight and the guard read the same elevation patterns" {
  windows_module_source | grep -qF 'Get-NSElevationPattern'
  windows_module_source | grep -qF "NSPolicyElevationPattern['sudo']"
  windows_module_source | grep -qF "NSPolicyElevationPattern['containers']"
  windows_module_source | grep -qF "NSPolicyElevationPattern['global-packages']"
  windows_module_source | grep -qF "NSPolicyElevationPattern['daemons']"
  windows_module_source | grep -qF "NSPolicyElevationPattern['external-services']"
  windows_module_source | grep -qF 'sudo|d[o]as'
  windows_module_source | grep -qF '(docker-compose)[[:space:]]+(up|run|exec|start|build|down|create)'
  windows_module_source | grep -qF '(docker|podman|nerdctl|colima)[[:space:]]+(run|exec|create|start|build'
  windows_module_source | grep -qF 'gh[[:space:]]+auth[[:space:]]+login'
  windows_module_source | grep -qF 'Convert-NSPolicyErePattern'
}

@test "Windows park-needs writes one idempotent entry per gap" {
  windows_module_source | grep -qF 'needs allowance: '
  windows_module_source | grep -qF 'worked last if the owner allows it before then'
  grep -qF 'a second run adds nothing' "$LOGIC"
  grep -qF 'a second run leaves the file byte-identical' "$LOGIC"
  grep -qF 'the file carries exactly one entry per gap' "$LOGIC"
  grep -qF 'every entry is a bullet Archive files once answered' "$LOGIC"
  grep -qF 'a bare-line entry is not parked a second time' "$LOGIC"
  grep -qF 'park-needs never touches a parking lot it has nothing to add to' "$LOGIC"
}

@test "Windows preflight logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh not installed'
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
