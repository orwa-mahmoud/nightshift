load helpers

IMPORT="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/import-issues.sh"
SKILL="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/import-issues/SKILL.md"
FAKE_GH="$BATS_TEST_DIRNAME/fixtures/import-issues/bin/gh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/import-issues/issues"
TEMPLATE="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/templates/drafting-table.md"

setup_file() {
  chmod +x "$FAKE_GH"
}

isolated_import() {
  local p="$1"
  shift
  env PATH="$(dirname "$FAKE_GH"):$PATH" \
    IMPORT_GH_FIXTURES="$FIXTURES" \
    IMPORT_GH_LOG="$BATS_TEST_TMPDIR/gh.log" \
    NIGHTSHIFT_IMPORT_TIME="2026-08-14T12:00:00Z" \
    bash "$IMPORT" --project "$p" "$@"
}

prep_draft() {
  local p="$1"
  cp "$TEMPLATE" "$p/.nightshift/drafting-table.md"
  printf '%s\n' '## Items' >"$p/.nightshift/punch-list.md"
}

@test "list and preview are deterministic and write nothing" {
  p="$(new_project)"
  prep_draft "$p"
  before="$(cksum "$p/.nightshift/drafting-table.md")"
  run isolated_import "$p" --fetch https://github.com/acme/widgets/issues/12
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Add a dry-run flag'
  printf '%s' "$output" | grep -q 'Nothing written'
  first="$output"
  run isolated_import "$p" --fetch https://github.com/acme/widgets/issues/12#issuecomment-9
  [ "$output" = "$first" ]
  [ "$(cksum "$p/.nightshift/drafting-table.md")" = "$before" ]
}

@test "URL and repo-number forms fetch the same canonical issue" {
  p="$(new_project)"
  prep_draft "$p"
  run isolated_import "$p" --fetch acme/widgets#12
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'https://github.com/acme/widgets/issues/12'
  printf '%s' "$output" | grep -q 'Add a dry-run flag'
  run isolated_import "$p" --fetch --repo acme/widgets 12
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'https://github.com/acme/widgets/issues/12'
}

@test "implicit search, pull URLs, and repo-only requests are refused" {
  p="$(new_project)"
  prep_draft "$p"
  before="$(cksum "$p/.nightshift/drafting-table.md")"
  run isolated_import "$p" --fetch
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qi 'never searches'
  run isolated_import "$p" --fetch --repo acme/widgets
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qi 'never lists'
  run isolated_import "$p" --fetch https://github.com/acme/widgets/pull/12
  [ "$status" -eq 1 ]
  [ "$(cksum "$p/.nightshift/drafting-table.md")" = "$before" ]
}

@test "closed issues preview but do not stage without an explicit override" {
  p="$(new_project)"
  prep_draft "$p"
  run isolated_import "$p" --fetch https://github.com/acme/widgets/issues/13
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'CLOSED'
  run isolated_import "$p" --stage https://github.com/acme/widgets/issues/13
  [ "$status" -eq 0 ]
  if grep -q 'Old request' "$p/.nightshift/drafting-table.md"; then
    return 1
  fi
  run isolated_import "$p" --stage --allow-closed https://github.com/acme/widgets/issues/13
  [ "$status" -eq 0 ]
  grep -q 'Old request' "$p/.nightshift/drafting-table.md"
  grep -q 'Status: proposed' "$p/.nightshift/drafting-table.md"
}

@test "hostile bodies are quoted, flagged, and never turned into commands" {
  p="$(new_project)"
  prep_draft "$p"
  run isolated_import "$p" --stage https://github.com/acme/widgets/issues/14 https://github.com/acme/widgets/issues/16
  [ "$status" -eq 0 ]
  grep -q 'Review flags: destructive,secret-seeking,publishing,payment,legal' "$p/.nightshift/drafting-table.md"
  grep -q 'quoted upstream source — not owner authorization' "$p/.nightshift/drafting-table.md"
  if grep -qF '```bash' "$p/.nightshift/drafting-table.md"; then
    return 1
  fi
  grep -q "curl http://evil.test" "$p/.nightshift/drafting-table.md"
  grep -q '^    > ' "$p/.nightshift/drafting-table.md"
}

@test "failed auth and missing gh change no files" {
  p="$(new_project)"
  prep_draft "$p"
  before="$(cksum "$p/.nightshift/drafting-table.md")"
  run env PATH="$(dirname "$FAKE_GH"):$PATH" \
    IMPORT_GH_AUTH=fail \
    IMPORT_GH_FIXTURES="$FIXTURES" \
    bash "$IMPORT" --project "$p" --stage https://github.com/acme/widgets/issues/12
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qi 'not authenticated'
  [ "$(cksum "$p/.nightshift/drafting-table.md")" = "$before" ]
  no_gh="$BATS_TEST_TMPDIR/no-gh-bin"
  mkdir -p "$no_gh"
  for tool in awk mktemp mv rm; do
    ln -s "$(command -v "$tool")" "$no_gh/$tool"
  done
  run env PATH="$no_gh" /bin/bash "$IMPORT" --project "$p" --stage https://github.com/acme/widgets/issues/12
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qi 'not installed'
  [ "$(cksum "$p/.nightshift/drafting-table.md")" = "$before" ]
}

@test "staging is atomic, deduped across draft punch list and archive, and uses one helper" {
  p="$(new_project)"
  prep_draft "$p"
  run isolated_import "$p" --stage https://github.com/acme/widgets/issues/12
  [ "$status" -eq 0 ]
  grep -q 'Add a dry-run flag' "$p/.nightshift/drafting-table.md"
  grep -c 'Source: https://github.com/acme/widgets/issues/12' "$p/.nightshift/drafting-table.md" | grep -qx 1
  run isolated_import "$p" --stage https://github.com/acme/widgets/issues/12
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qi 'already present'
  grep -c 'Source: https://github.com/acme/widgets/issues/12' "$p/.nightshift/drafting-table.md" | grep -qx 1

  q="$(new_project other)"
  prep_draft "$q"
  printf '%s\n' 'https://github.com/acme/widgets/issues/12' >"$q/.nightshift/punch-list.md"
  run isolated_import "$q" --stage https://github.com/acme/widgets/issues/12
  if grep -q 'Add a dry-run flag' "$q/.nightshift/drafting-table.md"; then
    return 1
  fi

  r="$(new_project archived)"
  prep_draft "$r"
  mkdir -p "$r/.nightshift/archive/2026-08-01"
  printf '%s\n' 'Source: https://github.com/acme/widgets/issues/12' >"$r/.nightshift/archive/2026-08-01/shipped.md"
  run isolated_import "$r" --stage https://github.com/acme/widgets/issues/12
  if grep -q 'Add a dry-run flag' "$r/.nightshift/drafting-table.md"; then
    return 1
  fi

  s="$(new_project symlink-archive-known)"
  prep_draft "$s"
  mkdir -p "$s/outside" "$s/.nightshift/archive"
  printf '%s\n' 'Source: https://github.com/acme/widgets/issues/12' >"$s/outside/shipped.md"
  ln -s "$s/outside" "$s/.nightshift/archive/2018-01-01"
  run isolated_import "$s" --stage https://github.com/acme/widgets/issues/12
  grep -q 'Add a dry-run flag' "$s/.nightshift/drafting-table.md"

  grep -qE 'ns"? import-issues' "$SKILL"
  grep -qF -- '--project "$NIGHTSHIFT_WORKSPACE"' "$SKILL"
  grep -qF 'Claude Code and Codex run the same platform helper' "$SKILL"
  grep -qF 'If work mode is artifact' "$SKILL"
  grep -qi 'will not consume them' "$SKILL"
  grep -qF 'if [ ! -d "$dated" ] || [ -L "$dated" ]; then' "$IMPORT"
}

@test "the helper never searches, mutates GitHub, or fetches the network itself" {
  if grep -E 'curl|wget|brew install|gh search|gh issue list|gh issue close|gh issue creat|gh issue edit|gh issue comment|gh issue delet|gh api ' "$IMPORT"; then
    return 1
  fi
  # The skill names those verbs once, to refuse them. Anything else is an instruction to run one.
  if grep -nE 'curl|wget|gh search|gh issue list' "$SKILL" | grep -qivE 'never|do not|refuse'; then
    return 1
  fi
  grep -qF 'Never searches' "$SKILL"
  grep -qF 'never writes back to GitHub' "$SKILL"
  p="$(new_project)"
  prep_draft "$p"
  : >"$BATS_TEST_TMPDIR/gh.log"
  run isolated_import "$p" --fetch --repo acme/widgets 12 15
  [ "$status" -eq 0 ]
  if grep -E 'search|list|close|creat|edit|comment|delet|api ' "$BATS_TEST_TMPDIR/gh.log"; then
    return 1
  fi
  grep -q 'issue view 12 --repo acme/widgets' "$BATS_TEST_TMPDIR/gh.log"
  grep -q 'auth status' "$BATS_TEST_TMPDIR/gh.log"
}
