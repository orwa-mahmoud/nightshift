ROOT="$BATS_TEST_DIRNAME/.."
MAP="$ROOT/docs/contribution-map.md"

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
