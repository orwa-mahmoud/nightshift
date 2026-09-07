ROOT="$BATS_TEST_DIRNAME/.."
MAP="$ROOT/docs/contribution-map.md"
README="$ROOT/README.md"
CONTRIBUTING="$ROOT/CONTRIBUTING.md"
AGENTS="$ROOT/AGENTS.md"
PR_TEMPLATE="$ROOT/.github/PULL_REQUEST_TEMPLATE.md"
ISSUE_CONFIG="$ROOT/.github/ISSUE_TEMPLATE/config.yml"
CATALOG_FORM="$ROOT/.github/ISSUE_TEMPLATE/catalog_shift.yml"
RECEIPTS="$ROOT/examples/README.md"

@test "the contribution map is reachable from contributor entry points" {
  [ -f "$MAP" ]
  for entry in "$README" "$CONTRIBUTING" "$AGENTS" "$PR_TEMPLATE" \
    "$ISSUE_CONFIG" "$CATALOG_FORM" "$RECEIPTS"; do
    grep -qF 'docs/contribution-map.md' "$entry" || {
      echo "contribution map is not linked from: $entry"
      return 1
    }
  done
  grep -qF '../CONTRIBUTING.md' "$MAP"
}

@test "the contribution map covers each supported path" {
  for area in 'Shift catalog' 'Documentation' 'Testing' 'Runtime' \
    'Recovery' 'Hooks and guards' 'Platform support' 'Run receipts'; do
    grep -qF "| **$area** |" "$MAP" || {
      echo "missing contribution path: $area"
      return 1
    }
  done

  for column in 'A good first contribution' 'Know before starting' \
    'Likely files' 'Minimum verification' 'Current work'; do
    grep -qF "$column" "$MAP"
  done

  grep -qF 'runtime/windows/watchman.ps1' "$MAP"
  grep -qF 'runtime/windows/start-watchman.ps1' "$MAP"
  grep -qF 'lib/Nightshift.psm1' "$MAP"
  grep -qF 'hooks/windows/hardhat.ps1' "$MAP"
  grep -qF 'hooks/windows/clock-out-gate.ps1' "$MAP"
  grep -qF 'tests/windows-hardhat.bats' "$MAP"
  grep -qF 'tests/windows-watchman.bats' "$MAP"
}

@test "the contribution map preserves focused and repository checks" {
  for command in 'bats tests/' "git ls-files '*.sh' \| xargs shellcheck -x" \
    'tests/coverage.sh' 'claude plugin validate . --strict'; do
    grep -qF "$command" "$MAP" || {
      echo "missing repository check: $command"
      return 1
    }
  done
}

@test "every concrete contribution-map path exists" {
  for path in \
    CONTRIBUTING.md README.md docs examples \
    plugins/nightshift/skills/nightshift/references/compose/catalog-recipe.md \
    plugins/nightshift/runtime plugins/nightshift/lib/lib.sh \
    plugins/nightshift/runtime/claude/watchman.sh \
    plugins/nightshift/runtime/codex/watchman.sh \
    plugins/nightshift/runtime/cursor/watchman.sh \
    plugins/nightshift/runtime/windows/watchman.ps1 \
    plugins/nightshift/runtime/windows/start-watchman.ps1 \
    plugins/nightshift/lib/Nightshift.psm1 \
    plugins/nightshift/hooks examples/bad-night-template.md \
    plugins/nightshift/hooks/windows/hardhat.ps1 \
    plugins/nightshift/hooks/windows/clock-out-gate.ps1 \
    tests/windows-hardhat.bats \
    tests/windows-watchman.bats \
    tests/codex tests/fixtures tests/shifts \
    tests/catalog.bats tests/contribution-map.bats \
    tests/doc-refs.bats \
    tests/first-night-checklist.bats tests/shift-modes.bats tests/troubleshooting.bats \
    tests/bad-night-template.bats tests/github-templates.bats \
    tests/watchman.bats tests/codex/watchman.bats \
    tests/cursor/watchman.bats \
    tests/process-evidence.bats tests/degradation.bats tests/watch-reason.bats \
    tests/e2e-lifecycle.bats tests/clock-out-gate.bats tests/hardhat.bats \
    tests/codex/gate.bats tests/codex/hardhat.bats \
    tests/coverage.sh; do
    [ -e "$ROOT/$path" ] || {
      echo "missing contribution-map path: $path"
      return 1
    }
  done
}

@test "relative links in the contribution map resolve" {
  while IFS= read -r markdown_link; do
    target="${markdown_link#](}"
    target="${target%)}"
    target="${target%%#*}"
    case "$target" in
      "" | http://* | https://* | mailto:*) continue ;;
    esac
    [ -e "$ROOT/docs/$target" ] || {
      echo "broken contribution-map link: $target"
      return 1
    }
  done < <(grep -oE '\]\([^)]*\)' "$MAP")
}

@test "the contribution map keeps live work and proposal links" {
  grep -qF 'issues?q=is%3Aissue+is%3Aopen' "$MAP"
  grep -qF 'issues/new?template=catalog_shift.yml' "$MAP"
  grep -qF 'issues/21' "$MAP"
  grep -qF 'issues/22' "$MAP"
  grep -qF 'platform%3A+linux' "$MAP"
}
