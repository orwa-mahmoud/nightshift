#!/usr/bin/env bats

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  source .github/release-merge-gate.sh
}

@test "an ordinary plugin change can merge after CI" {
  run release_merge_requirement \
    '{"number":1,"head":{"ref":"feature"},"base":{"ref":"main"},"changed_files":1}' \
    '[{"filename":"plugins/nightshift/runtime/start-preflight.sh"}]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the Release Please branch requires the release owner" {
  run release_merge_requirement \
    '{"number":1,"head":{"ref":"release-please--branches--main"},"base":{"ref":"main"},"changed_files":1}' \
    '[{"filename":"README.md"}]'
  [ "$status" -eq 0 ]
  [ "$output" = 'Release Please PR requires the release owner to merge' ]
}

@test "release metadata and trusted workflows require the owner across branch names and renames" {
  for protected_file in CHANGELOG.md .release-please-manifest.json \
    plugins/nightshift/.codex-plugin/plugin.json .github/workflows/release-please.yaml \
    .github/release-merge-gate.sh; do
    run release_merge_requirement \
      '{"number":1,"head":{"ref":"feature"},"base":{"ref":"main"},"changed_files":1}' \
      "[{\"filename\":\"moved\",\"previous_filename\":\"$protected_file\"}]"
    [ "$status" -eq 0 ] || return 1
    [ "$output" = 'Release files or workflows require the release owner to merge' ] || return 1
  done
}

@test "incomplete pull request metadata cannot produce an authorization" {
  run release_merge_requirement \
    '{"number":1,"head":{"ref":"feature"},"base":{"ref":"main"},"changed_files":2}' \
    '[{"filename":"README.md"}]'
  [ "$status" -ne 0 ]
  [[ $output == *'Incomplete changed-file metadata for PR #1'* ]] || false
}
