ROOT="$BATS_TEST_DIRNAME/.."
DOC="$ROOT/docs/remote-environments.md"
CI="$ROOT/.github/workflows/ci.yaml"
ENVIRONMENTS="$BATS_TEST_DIRNAME/environments"

@test "remote environment docs define co-location and refused split runtimes" {
  contents="$(cat "$DOC")"
  printf '%s' "$contents" | grep -qF 'must all see the'
  printf '%s' "$contents" | grep -qF 'same operating-system process table and filesystem namespace'
  printf '%s' "$contents" | grep -qF 'Native Windows | Runtime fixture verified (x86_64)'
  printf '%s' "$contents" | grep -qF 'Remote SSH to Linux | Runtime fixture verified (x86_64)'
  printf '%s' "$contents" | grep -qF 'Linux devcontainer | Runtime fixture verified (x86_64)'
  printf '%s' "$contents" | grep -qF 'Host outside, tools or files inside a container | Unsupported'
  printf '%s' "$contents" | grep -qF 'Remote SSH to native Windows | Not verified'
}

@test "sanitized receipts cover every promised runtime observation" {
  for environment in remote-ssh devcontainer; do
    receipt="$ENVIRONMENTS/receipts/$environment-linux.json"
    jq -e --arg environment "$environment" '
      .schema == 1
      and .environment == $environment
      and .platform == "linux"
      and .architecture == "x86_64"
      and .result == "pass"
      and ([.checks[]] | all(. == "pass"))
      and (.checks | has("boundary"))
      and (.checks | has("filesystem"))
      and (.checks | has("hookExecution"))
      and (.checks | has("processIdentity"))
      and (.checks | has("watchmanPlacement"))
      and (.checks | has("workspaceResolution"))
      and (.checks.transportDisconnect == "pass")
    ' "$receipt" >/dev/null
  done
}

@test "CI crosses SSH and starts the checked-in devcontainer" {
  grep -qF 'run-remote-ssh.sh' "$CI"
  grep -qF '@devcontainers/cli@0.88.0' "$CI"
  grep -qF 'devcontainer up' "$CI"
  grep -qF 'devcontainer exec' "$CI"
  grep -qF 'disconnect-watchman.sh verify' "$CI"
  grep -qF 'cmp tests/environments/receipts/remote-ssh-linux.json' "$CI"
  grep -qF 'cmp tests/environments/receipts/devcontainer-linux.json' "$CI"
}

@test "CI keeps required job names reporting when only docs or manifests change" {
  grep -qF 'dorny/paths-filter' "$CI"
  grep -qF 'run-docs-contract.sh' "$CI"
  grep -qF '!plugins/nightshift/.claude-plugin/plugin.json' "$CI"
}

@test "devcontainer fixture is native Linux with the required local tools" {
  jq -e '
    .workspaceFolder == "/workspaces/nightshift"
    and .remoteUser == "vscode"
    and .build.dockerfile == "Dockerfile"
  ' "$ENVIRONMENTS/devcontainer/devcontainer.json" >/dev/null
  grep -qF 'git jq procps' "$ENVIRONMENTS/devcontainer/Dockerfile"
}

@test "disconnect cleanup refuses lookalike paths outside its owned temp boundary" {
  unsafe="$BATS_TEST_TMPDIR/nightshift-environment.lookalike"
  mkdir -p "$unsafe"
  printf 'keep\n' >"$unsafe/sentinel"

  run bash "$ENVIRONMENTS/disconnect-watchman.sh" cleanup "$ROOT" "$unsafe"
  [ "$status" -ne 0 ]
  [ -f "$unsafe/sentinel" ]
}

@test "disconnect cleanup refuses to signal a live pid outside its fixture" {
  fixture="$(mktemp -d /tmp/nightshift-environment.XXXXXX)"
  mkdir -p "$fixture/.nightshift"
  printf '%s\n' "$$" >"$fixture/.nightshift/.watchman"
  printf 'keep\n' >"$fixture/sentinel"

  run bash "$ENVIRONMENTS/disconnect-watchman.sh" cleanup "$ROOT" "$fixture"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'refusing to signal a pid outside the fixture'
  [ -f "$fixture/sentinel" ]
  rm -rf -- "$fixture"
}

@test "disconnect cleanup rejects a non-process pid marker" {
  fixture="$(mktemp -d /tmp/nightshift-environment.XXXXXX)"
  mkdir -p "$fixture/.nightshift"
  printf '%s\n' '-1' >"$fixture/.nightshift/.watchman"
  printf 'keep\n' >"$fixture/sentinel"

  run bash "$ENVIRONMENTS/disconnect-watchman.sh" cleanup "$ROOT" "$fixture"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'watchman marker has an invalid pid'
  [ -f "$fixture/sentinel" ]
  rm -rf -- "$fixture"
}

@test "environment receipts are emitted only after strict cleanup" {
  probe_cleanup="$(grep -n '^cleanup$' "$ENVIRONMENTS/probe.sh" | cut -d: -f1)"
  probe_receipt="$(grep -n "^printf '%s\\\\n'" "$ENVIRONMENTS/probe.sh" | tail -n 1 | cut -d: -f1)"
  remote_cleanup="$(grep -n '^remote_helper cleanup$' "$ENVIRONMENTS/run-remote-ssh.sh" | cut -d: -f1)"
  remote_receipt="$(grep -n "^printf '%s' .*transportDisconnect" "$ENVIRONMENTS/run-remote-ssh.sh" | cut -d: -f1)"

  [ "$probe_cleanup" -lt "$probe_receipt" ]
  [ "$remote_cleanup" -lt "$remote_receipt" ]
  grep -qF 'watchman_pid=$!' "$ENVIRONMENTS/disconnect-watchman.sh"
  grep -qF 'cleanup_best_effort()' "$CI"
  ! grep -A2 'cleanup() {' "$CI" | grep -qF '|| true'
}
