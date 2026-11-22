#!/usr/bin/env bats
# Coverage reruns only when the traced sources, tests, or coverage configuration
# change. Metadata that cannot affect those lines does not start a new trace,
# and a finished trace does not upload once a newer covered revision exists.

DECIDE="$BATS_TEST_DIRNAME/coverage-decide.sh"
WF="$BATS_TEST_DIRNAME/../.github/workflows/coverage.yml"

decide() {
  printf '%s\n' "$1" | bash "$DECIDE"
}

upload() {
  printf '%s\n' "$1" | bash "$DECIDE" --upload
}

@test "a runtime change is traced and the following release metadata is not" {
  run decide $'plugins/nightshift/runtime/doctor.sh'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'trace=true'
  printf '%s\n' "$output" | grep -qx 'reason=covered-input'
  run decide $'CHANGELOG.md\n.release-please-manifest.json\nplugins/nightshift/.claude-plugin/plugin.json'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'trace=false'
  printf '%s\n' "$output" | grep -qx 'reason=equivalent-metadata'
}

@test "tests and fixtures are traced" {
  run decide $'tests/status.bats'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'reason=covered-input'
  run decide $'tests/fixtures/morning-receipt/sample.json'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'reason=covered-input'
}

@test "coverage configuration is traced and an unknown path is not called equivalent" {
  run decide $'codecov.yml'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'reason=covered-input'
  run decide $'.github/workflows/coverage.yml'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'reason=covered-input'
  run decide $'plugins/nightshift/config/nightshift-rules-template.json'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'reason=covered-input'
  run decide $'somewhere/new-tool.dat'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'trace=true'
  printf '%s\n' "$output" | grep -qx 'reason=unproved'
}

@test "a failed or empty comparison is not treated as equivalent" {
  run bash "$DECIDE" </dev/null
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'reason=unproved'
}

@test "a newer covered revision blocks upload and metadata does not" {
  run upload $'plugins/nightshift/lib/state.sh'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'upload=false'
  printf '%s\n' "$output" | grep -qx 'reason=stale'
  run upload $'CHANGELOG.md'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'upload=true'
  printf '%s\n' "$output" | grep -qx 'reason=same-coverage'
  run upload $'somewhere/new-tool.dat'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'upload=false'
  printf '%s\n' "$output" | grep -qx 'reason=unproved'
  run bash "$DECIDE" --upload </dev/null
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'upload=true'
  printf '%s\n' "$output" | grep -qx 'reason=current'
}

@test "the workflow does not cancel an in-flight trace and uploads only a fresh main push" {
  grep -q 'cancel-in-progress: false' "$WF"
  grep -q 'coverage-decide.sh' "$WF"
  grep -q 'workflow_dispatch' "$WF"
  grep -q "github.event_name == 'push'" "$WF"
  grep -q "github.ref == 'refs/heads/main'" "$WF"
  grep -q 'steps.fresh.outputs.upload' "$WF"
  grep -q 'covered-revision.txt' "$WF"
  grep -q 'coverage/cobertura.xml' "$WF"
}
