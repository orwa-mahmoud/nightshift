#!/usr/bin/env bash
# Decide whether a coverage trace is needed, and whether a finished trace may
# be uploaded. Paths are read one per line. The tracer measures
# plugins/nightshift/{hooks,runtime,lib} under kcov, driven by tests/ and by
# the coverage configuration. A diff that stays outside that set cannot change
# the measured lines. Anything else is traced, because equivalence is unproved.
#   coverage-decide.sh           trace= and reason=
#   coverage-decide.sh --upload  upload= and reason= for commits after the run
set -euo pipefail

mode=trace
if [ "${1:-}" = --upload ]; then
  mode=upload
fi

covered=false
unknown=false
count=0

while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  count=$((count + 1))
  case "$path" in
    plugins/nightshift/hooks | plugins/nightshift/hooks/* | \
      plugins/nightshift/runtime | plugins/nightshift/runtime/* | \
      plugins/nightshift/lib | plugins/nightshift/lib/* | \
      plugins/nightshift/config | plugins/nightshift/config/* | \
      tests | tests/* | \
      codecov.yml | .github/workflows/coverage.yml)
      covered=true
      ;;
    CHANGELOG.md | .release-please-manifest.json | release-please-config.json | \
      LICENSE | .gitignore | README.md | CONTRIBUTING.md | SECURITY.md | \
      plugins/nightshift/.claude-plugin/* | plugins/nightshift/.codex-plugin/* | \
      plugins/nightshift/.cursor-plugin/* | plugins/nightshift/skills | \
      plugins/nightshift/skills/* | docs | docs/* | examples | examples/* | \
      evals | evals/* | .github/workflows/* | .github/ISSUE_TEMPLATE/* | \
      .github/PULL_REQUEST_TEMPLATE.md | .claude-plugin/* | .agents/* | .cursor-plugin/*)
      ;;
    *)
      unknown=true
      ;;
  esac
done

if [ "$mode" = upload ]; then
  if [ "$count" -eq 0 ]; then
    printf 'upload=true\nreason=current\n'
  elif [ "$covered" = true ]; then
    printf 'upload=false\nreason=stale\n'
  elif [ "$unknown" = true ]; then
    printf 'upload=false\nreason=unproved\n'
  else
    printf 'upload=true\nreason=same-coverage\n'
  fi
  exit 0
fi

if [ "$count" -eq 0 ] || [ "$unknown" = true ]; then
  printf 'trace=true\nreason=unproved\n'
elif [ "$covered" = true ]; then
  printf 'trace=true\nreason=covered-input\n'
else
  printf 'trace=false\nreason=equivalent-metadata\n'
fi
