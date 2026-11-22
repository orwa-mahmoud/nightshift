#!/usr/bin/env bash
# Classify a pull request's changed paths. One path per line on standard input.
# Prints suite, lint, validate, docs and prose as true or false, for the workflow
# to read. No paths is an incomplete classification: exit 1 and print nothing.
set -euo pipefail

suite=false
lint=false
validate=false
docs=false
prose=false
count=0

while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  count=$((count + 1))
  case "$path" in
    *.sh) lint=true ;;
  esac
  case "$path" in
    CHANGELOG.md | .release-please-manifest.json | release-please-config.json | .claude-plugin/marketplace.json | .agents/plugins/marketplace.json | .cursor-plugin/marketplace.json)
      validate=true
      ;;
    plugins/nightshift/.claude-plugin/plugin.json | plugins/nightshift/.codex-plugin/plugin.json | plugins/nightshift/.cursor-plugin/plugin.json)
      validate=true
      ;;
    plugins/nightshift/skills/nightshift/references/templates/*)
      suite=true
      validate=true
      ;;
    plugins/*)
      case "$path" in
        *.md) prose=true ;;
        *) suite=true ;;
      esac
      validate=true
      ;;
    tests/* | evals/* | .claude-plugin/* | .agents/* | .cursor-plugin/*)
      suite=true
      validate=true
      ;;
    .github/workflows/ci.yaml)
      suite=true
      lint=true
      validate=true
      ;;
    .github/workflows/*)
      lint=true
      ;;
    README.md | CONTRIBUTING.md | SECURITY.md | docs/* | examples/* | .github/ISSUE_TEMPLATE/* | .github/PULL_REQUEST_TEMPLATE.md)
      docs=true
      ;;
    *)
      suite=true
      ;;
  esac
done

if [ "$count" -eq 0 ]; then
  echo "ci-paths: no changed paths were classified" >&2
  exit 1
fi

printf 'suite=%s\n' "$suite"
printf 'lint=%s\n' "$lint"
printf 'validate=%s\n' "$validate"
printf 'docs=%s\n' "$docs"
printf 'prose=%s\n' "$prose"
