#!/usr/bin/env bash

release_merge_requirement() {
  jq -nr --argjson pull "$1" --argjson files "$2" --slurpfile config release-please-config.json '
    def release_file:
      . == ".release-please-manifest.json" or
      . == "release-please-config.json" or
      . == ".github/release-merge-gate.sh" or
      . == ($config[0]["changelog-path"] // "CHANGELOG.md") or
      startswith(".github/workflows/") or startswith(".github/actions/") or
      (. as $path | any($config[0].packages[];
        .["changelog-path"] == $path or
        any(.["extra-files"][]?; (if type == "string" then . else .path end) == $path)));

    if $pull.head.ref == ("release-please--branches--" + $pull.base.ref) then
      "Release Please PR requires the release owner to merge"
    elif ($files | length) != $pull.changed_files then
      error("Incomplete changed-file metadata for PR #\($pull.number)")
    elif any($files[]; any(.filename, .previous_filename; strings | release_file)) then
      "Release files or workflows require the release owner to merge"
    else
      ""
    end'
}

base64url() {
  openssl base64 -A | tr '/+' '_-' | tr -d '='
}

status_token() {
  local now header claims unsigned signature
  now=$(date +%s)
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url)
  claims=$(jq -nc --arg iss "$RELEASE_GATE_APP_ID" --argjson now "$now" \
    '{iss:$iss, iat:($now-60), exp:($now+480)}' | base64url)
  unsigned="$header.$claims"
  signature=$(printf '%s' "$unsigned" | openssl dgst -sha256 \
    -sign <(printf '%s\n' "$RELEASE_GATE_PRIVATE_KEY") -binary | base64url)
  gate_token=$unsigned.$signature
  jq -nc --arg name "${GITHUB_REPOSITORY#*/}" \
    '{repositories:[$name],permissions:{statuses:"write"}}' |
    GH_TOKEN="${gate_token}" gh api --method POST \
      "app/installations/$RELEASE_GATE_INSTALLATION_ID/access_tokens" --input - --jq .token
}

matching_pulls() {
  gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/commits/$1/pulls?per_page=100" |
    jq -r --arg sha "$1" --arg ref "$GITHUB_REF_NAME" --arg repo "$GITHUB_REPOSITORY" '
      .[][] | select(.state == "open" and .head.sha == $sha
        and .base.ref == $ref and .base.repo.full_name == $repo) | .number'
}

pull_snapshot() {
  jq -c '[.state, .head.sha, .head.ref, .base.sha, .base.ref, .base.repo.full_name]'
}

report_release_merge_status() {
  set -euo pipefail
  local head numbers number repo pull files requirement current token
  local state=success description='Standard pull request'
  head=$(jq -er '.workflow_run.head_sha' "$GITHUB_EVENT_PATH")
  numbers=$(matching_pulls "$head")
  [ -n "$numbers" ] || return 0
  repo="repos/$GITHUB_REPOSITORY"
  while IFS= read -r number; do
    pull=$(gh api "$repo/pulls/$number")
    if ! jq -e --arg sha "$head" --arg ref "$GITHUB_REF_NAME" --arg repo "$GITHUB_REPOSITORY" \
      '.state == "open" and .head.sha == $sha and .base.ref == $ref and .base.repo.full_name == $repo' \
      >/dev/null <<< "$pull"; then
      return 0
    fi
    files=$(gh api --paginate --slurp "$repo/pulls/$number/files?per_page=100" | jq -c 'add // []')
    requirement=$(release_merge_requirement "$pull" "$files")
    current=$(gh api "$repo/pulls/$number" | pull_snapshot)
    [ "$(pull_snapshot <<< "$pull")" = "$current" ] || return 0
    if [ -n "$requirement" ]; then
      state=failure
      description="$requirement"
    fi
  done <<< "$numbers"

  token=$(status_token)
  GH_TOKEN="$token" gh api --method POST "$repo/statuses/$head" \
    -f context='Release merge authorization' -f state="$state" -f description="$description" \
    -f target_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" >/dev/null
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  report_release_merge_status
fi
