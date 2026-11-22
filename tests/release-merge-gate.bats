#!/usr/bin/env bats

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  source .github/release-merge-gate.sh
  FILES="$BATS_TEST_TMPDIR/files.json"
}

# requirement <pull-json> <files-json> — the gate's verdict, with the file list written where the
# workflow writes it.
requirement() {
  printf '%s\n' "$2" >"$FILES"
  release_merge_requirement "$1" "$FILES"
}

@test "an ordinary plugin change can merge after CI" {
  run requirement \
    '{"number":1,"head":{"ref":"feature"},"base":{"ref":"main"},"changed_files":1}' \
    '[{"filename":"plugins/nightshift/runtime/start-preflight.sh"}]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the Release Please branch requires the release owner" {
  run requirement \
    '{"number":1,"head":{"ref":"release-please--branches--main"},"base":{"ref":"main"},"changed_files":1}' \
    '[{"filename":"README.md"}]'
  [ "$status" -eq 0 ]
  [ "$output" = 'Release Please PR requires the release owner to merge' ]
}

@test "release metadata and trusted workflows require the owner across branch names and renames" {
  for protected_file in CHANGELOG.md .release-please-manifest.json \
    plugins/nightshift/.codex-plugin/plugin.json .github/workflows/release-please.yaml \
    .github/release-merge-gate.sh; do
    run requirement \
      '{"number":1,"head":{"ref":"feature"},"base":{"ref":"main"},"changed_files":1}' \
      "[{\"filename\":\"moved\",\"previous_filename\":\"$protected_file\"}]"
    [ "$status" -eq 0 ] || return 1
    [ "$output" = 'Release files or workflows require the release owner to merge' ] || return 1
  done
}

@test "incomplete pull request metadata cannot produce an authorization" {
  run requirement \
    '{"number":1,"head":{"ref":"feature"},"base":{"ref":"main"},"changed_files":2}' \
    '[{"filename":"README.md"}]'
  [ "$status" -ne 0 ]
  [[ $output == *'Incomplete changed-file metadata for PR #1'* ]] || false
}

@test "a pull request whose file list passes the argument limit still gets a verdict" {
  python3 -c 'import json; print(json.dumps([{"filename": "plugins/nightshift/lib/f%d.sh" % i, "patch": "x" * 4000} for i in range(100)]))' >"$FILES"
  [ "$(wc -c <"$FILES")" -gt 131072 ] || false
  run release_merge_requirement \
    '{"number":1,"head":{"ref":"feature"},"base":{"ref":"main"},"changed_files":100}' "$FILES"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a missing release gate app setting is named and reports nothing" {
  run env -u RELEASE_GATE_APP_ID RELEASE_GATE_INSTALLATION_ID=1 RELEASE_GATE_PRIVATE_KEY= \
    bash -c 'source .github/release-merge-gate.sh && require_gate_app'
  [ "$status" -eq 1 ]
  [[ $output == *'missing: RELEASE_GATE_APP_ID RELEASE_GATE_PRIVATE_KEY.'* ]] || false
}
