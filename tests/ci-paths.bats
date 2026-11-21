#!/usr/bin/env bats
# Path classification decides which required checks do work. An empty or failed
# classification is not a skip.

load helpers

CLASS="$BATS_TEST_DIRNAME/ci-paths.sh"
WF="$BATS_TEST_DIRNAME/../.github/workflows/ci.yaml"

flags() {
  printf '%s\n' "$1" | bash "$CLASS"
}

@test "a release-gate test file selects the full suite" {
  run flags 'tests/release-gate.bats'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'suite=true'
}

@test "release metadata does not select the suite" {
  run flags $'CHANGELOG.md\n.release-please-manifest.json\nrelease-please-config.json'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'suite=false'
  printf '%s\n' "$output" | grep -qx 'validate=true'
}

@test "docs and skill prose select those lanes and not the suite" {
  run flags $'docs/readme-extra.md\nplugins/nightshift/skills/nightshift/SKILL.md'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'docs=true'
  printf '%s\n' "$output" | grep -qx 'prose=true'
  printf '%s\n' "$output" | grep -qx 'suite=false'
}

@test "runtime code selects the suite" {
  run flags 'plugins/nightshift/lib/state.sh'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'suite=true'
  printf '%s\n' "$output" | grep -qx 'lint=true'
}

@test "an unknown path selects the suite" {
  run flags 'somewhere/new-tool.py'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'suite=true'
}

@test "a workflow-only change is lint and not the suite" {
  run flags '.github/workflows/ci.yaml'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'lint=true'
  printf '%s\n' "$output" | grep -qx 'suite=false'
}

@test "no paths is an incomplete classification" {
  run flags ''
  [ "$status" -eq 1 ]
}

@test "the workflow can read a fork pull request and a failed classification fails the required jobs" {
  grep -q 'pull-requests: read' "$WF"
  for job in shellcheck bats bats-macos windows-native validate; do
    awk -v job="$job" '
      $0 ~ "^  " job ":" { on = 1 }
      on && /^  [a-z]/ && $0 !~ "^  " job ":" { exit }
      on && /Require a successful change classification/ { found = 1 }
      on && /always\(\) && !cancelled\(\)/ { armed = 1 }
      END { exit !(found && armed) }
    ' "$WF" || { echo "$job does not fail closed"; return 1; }
  done
}

@test "docs and skills contracts share the two overlapping files" {
  grep -q 'doc-refs.bats' "$BATS_TEST_DIRNAME/run-docs-contract.sh"
  grep -q 'skill-refs.bats' "$BATS_TEST_DIRNAME/run-docs-contract.sh"
  grep -q -- '--skip-shared' "$BATS_TEST_DIRNAME/run-skills-contract.sh"
  grep -q 'doc-refs.bats' "$BATS_TEST_DIRNAME/run-skills-contract.sh"
  grep -q -- '--skip-shared' "$WF"
}
