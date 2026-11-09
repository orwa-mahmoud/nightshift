#!/usr/bin/env bash
# Plugin-prose CI: what a change to a skill, a reference or a catalog entry can break — catalog
# discovery and each entry's operational fields on both runtimes, references and commands that
# must resolve, frontmatter the hosts load, eval budgets, and the shift fixtures. Templates the
# runtime copies, and any code, run the full shard matrix instead.
set -euo pipefail
cd "$(dirname "$0")/.."

bats \
  tests/catalog-index.bats \
  tests/catalog.bats \
  tests/evidence-catalog.bats \
  tests/gates-catalog.bats \
  tests/plan-depth.bats \
  tests/skill-refs.bats \
  tests/skill-paths.bats \
  tests/one-sentence-start.bats \
  tests/doc-refs.bats \
  tests/evals.bats \
  tests/shifts/
