#!/usr/bin/env bash
# Docs-only CI: what a change to README, docs/, examples/ or the GitHub templates can break —
# links and paths that must resolve, commands the docs name that the parser must take, and issue
# forms GitHub must parse. Runtime changes run the full shard matrix, which includes these files.
set -euo pipefail
cd "$(dirname "$0")/.."

bats \
  tests/bad-night-template.bats \
  tests/contribution-map.bats \
  tests/doc-refs.bats \
  tests/github-templates.bats \
  tests/skill-refs.bats
