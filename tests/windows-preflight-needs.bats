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
  windows_module_source | grep -qF '(docker-compose)[[:space:]]+(up|run|start|build|down|create)'
  windows_module_source | grep -qF '(docker|podman|nerdctl|colima)[[:space:]]+(run|create|start|build'
  windows_module_source | grep -qF 'gh[[:space:]]+auth[[:space:]]+login'
  windows_module_source | grep -qF 'Convert-NSPolicyErePattern'
}

@test "Windows preflight logic covers every shipped signal" {
  grep -qF 'docker compose is a containers signal' "$LOGIC"
  grep -qF 'sudo is a sudo signal' "$LOGIC"
  grep -qF 'apt-get is a global-packages signal' "$LOGIC"
  grep -qF 'npm install -g is a global-packages signal' "$LOGIC"
  grep -qF 'npm login is an external-services signal' "$LOGIC"
  grep -qF 'systemctl is a daemons signal' "$LOGIC"
  grep -qF 'npm test needs no elevation' "$LOGIC"
  grep -qF 'a ticked item is finished work and is never reported' "$LOGIC"
  grep -qF 'a ticked item is never parked' "$LOGIC"
  grep -qF 'a fully ticked work order reports neither its box nor its heading' "$LOGIC"
  grep -qF 'only the Items section is read' "$LOGIC"
  grep -qF 'a work order is matched against the same patterns' "$LOGIC"
  grep -qF 'the open-item and gap summary leads' "$LOGIC"
  grep -qF 'shared fixture: no gaps' "$LOGIC"
  grep -qF 'shared fixture mixed needs: gap summary' "$LOGIC"
}

@test "Windows preflight logic checks gaps against the resolver and never refuses" {
  grep -qF 'a one-shift allowance turns a need into an allowance' "$LOGIC"
  grep -qF 'an allowed category is no longer a gap' "$LOGIC"
  grep -qF 'a broken pattern never makes the preflight refuse' "$LOGIC"
  grep -qF 'an empty workspace exits 0' "$LOGIC"
  grep -qF 'the JSON view is LF-only' "$LOGIC"
  grep -qF '"patternErrors":[]' "$LOGIC"
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
