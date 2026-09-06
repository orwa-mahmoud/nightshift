BUG="$BATS_TEST_DIRNAME/../.github/ISSUE_TEMPLATE/bug_report.yml"
FAILED="$BATS_TEST_DIRNAME/../.github/ISSUE_TEMPLATE/failed_shift.yml"
PR="$BATS_TEST_DIRNAME/../.github/PULL_REQUEST_TEMPLATE.md"
CONTRIBUTING="$BATS_TEST_DIRNAME/../CONTRIBUTING.md"
SECURITY="$BATS_TEST_DIRNAME/../SECURITY.md"

@test "bug reports offer Claude Code and Codex as first-class harnesses" {
  grep -qF 'Claude Code (hooks)' "$BUG"
  grep -qF 'OpenAI Codex (hooks and skills)' "$BUG"
}
@test "the pull request template asks about parity, not generic adapters" {
  grep -qF 'Harness parity (shared Claude Code / Codex / Cursor behaviour)' "$PR"
  if grep -qi 'Adapter (support for another harness)' "$PR"; then
    return 1
  fi
  grep -qi 'not a generic adapter' "$CONTRIBUTING"
  for one in 'Claude Code' 'Codex' 'Cursor'; do
    grep -qF "$one" "$CONTRIBUTING" || { echo "CONTRIBUTING does not name $one"; return 1; }
  done
}

@test "CONTRIBUTING names the Windows CI job" {
  grep -qF 'windows-native' "$CONTRIBUTING"
  grep -qF 'tests/windows/run.ps1' "$CONTRIBUTING"
}

@test "CONTRIBUTING names the remote environment CI jobs" {
  grep -qF 'remote-ssh' "$CONTRIBUTING"
  grep -qF 'devcontainer' "$CONTRIBUTING"
  grep -qF 'sanitized receipts' "$CONTRIBUTING"
}

@test "CONTRIBUTING requires PowerShell 5.1 and 7 portability" {
  grep -qF 'PowerShell must stay portable' "$CONTRIBUTING"
  grep -qF 'Avoid syntax and APIs that exist on' "$CONTRIBUTING"
  grep -qF 'only one of those runtimes' "$CONTRIBUTING"
}

parse_yaml() {
  ruby -ryaml -e 'YAML.load_file(ARGV[0]); puts "ok"' "$1"
}

@test "the failed-shift form is valid YAML with required diagnostic fields" {
  parse_yaml "$FAILED"
  grep -qF 'name: Failed shift' "$FAILED"
  grep -qF 'id: harness' "$FAILED"
  grep -qF 'id: plugin-version' "$FAILED"
  grep -qF 'id: host-version' "$FAILED"
  grep -qF 'pwsh 7 / Windows 11' "$FAILED"
  grep -qF 'id: expected' "$FAILED"
  grep -qF 'id: observed' "$FAILED"
  grep -qF 'id: markers' "$FAILED"
  grep -qF 'work-mode is artifact' "$FAILED"
  grep -qF 'receipts/ had completion files' "$FAILED"
  grep -qF 'id: recovery' "$FAILED"
  grep -qF 'id: logs' "$FAILED"
}

@test "the failed-shift form redacts secrets and keeps an optional private path" {
  grep -qF 'Do not paste' "$FAILED"
  grep -qF 'prompts, credentials' "$FAILED"
  grep -qF 'full session transcript' "$FAILED"
  grep -qF 'https://github.com/orwa-mahmoud/nightshift/security/advisories/new' "$FAILED"
  grep -qF 'https://github.com/orwa-mahmoud/nightshift/blob/main/SECURITY.md' "$FAILED"
  grep -qF 'I have removed prompts, credentials, repository content, and full transcripts' "$FAILED"
  grep -qF 'Local guard and gate reports are public issues' "$FAILED"
  if grep -qi 'paste the full transcript' "$FAILED"; then
    return 1
  fi
  if grep -qi 'include your prompt' "$FAILED"; then
    return 1
  fi
  if grep -qi 'those go to a private advisory' "$FAILED"; then
    return 1
  fi
}

@test "SECURITY.md points failed nights at the form and keeps an optional advisory" {
  grep -qF 'A public issue is the default' "$SECURITY"
  grep -qF 'A private advisory is optional' "$SECURITY"
  grep -qF 'issues/new?template=failed_shift.yml' "$SECURITY"
  grep -qF 'security/advisories/new' "$SECURITY"
  if grep -qi 'do not open a public issue' "$SECURITY"; then
    return 1
  fi
  [ -f "$FAILED" ]
}

CATALOG_FORM="$BATS_TEST_DIRNAME/../.github/ISSUE_TEMPLATE/catalog_shift.yml"
RECIPE="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/compose/catalog-recipe.md"

@test "the catalog proposal form is valid YAML and covers every contract field" {
  parse_yaml "$CATALOG_FORM"
  grep -qF 'name: Catalog shift proposal' "$CATALOG_FORM"
  grep -qF 'id: ending' "$CATALOG_FORM"
  grep -qF 'id: discovery' "$CATALOG_FORM"
  grep -qF 'id: done' "$CATALOG_FORM"
  grep -qF 'id: refusals' "$CATALOG_FORM"
  grep -qF 'id: verification' "$CATALOG_FORM"
  grep -qF 'id: stacks' "$CATALOG_FORM"
  grep -qF 'orwa-mahmoud/nightshift/issues/21' "$CATALOG_FORM"
  grep -qF 'catalog-recipe.md' "$CATALOG_FORM"
  grep -qF 'does **not** add the shift' "$CATALOG_FORM"
  grep -qi 'unattended' "$CATALOG_FORM"
  grep -qi "stranger's workspace" "$CATALOG_FORM"
  grep -qF 'must not require a git history' "$CATALOG_FORM"
  grep -qF 'commit or artifact receipt' "$CATALOG_FORM"
  grep -qF '.nightshift/receipts/' "$CATALOG_FORM"
  grep -qF 'commit or artifact receipt' "$RECIPE"
  grep -qF 'must not require a git history' "$RECIPE"
  grep -qF 'Never select this entry in artifact mode' "$RECIPE"
  grep -qF 'Never select this entry in artifact mode' "$CATALOG_FORM"
  grep -qF 'Do not `git init` a notes folder' "$RECIPE"
  grep -qF 'Do not `git init` a notes folder' "$CATALOG_FORM"
  [ -f "$RECIPE" ]
}
