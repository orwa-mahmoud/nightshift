load helpers

IMPORT="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/import-issues.sh"
FAKE_GH="$BATS_TEST_DIRNAME/fixtures/import-issues/bin/gh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/import-issues/issues"
TEMPLATE="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/templates/drafting-table.md"
PUNCH="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/templates/punch-list.md"

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

prep() {
  local p="$1"
  cp "$TEMPLATE" "$p/.nightshift/drafting-table.md"
  cp "$PUNCH" "$p/.nightshift/punch-list.md"
}

@test "list-proposed and promote move imported drafts without calling gh" {
  p="$(new_project)"
  prep "$p"
  run isolated_import "$p" --stage https://github.com/acme/widgets/issues/12 https://github.com/acme/widgets/issues/15
  [ "$status" -eq 0 ]
  : >"$BATS_TEST_TMPDIR/gh.log"
  run env PATH="$PATH" bash "$IMPORT" --project "$p" --list-proposed
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'acme/widgets/issues/12'
  printf '%s' "$output" | grep -q 'acme/widgets/issues/15'
  [ ! -s "$BATS_TEST_TMPDIR/gh.log" ]

  printf '%s\n' '- [ ] **Keep this ordinary draft.**' >>"$p/.nightshift/drafting-table.md"
  run env PATH="$PATH" bash "$IMPORT" --project "$p" --promote https://github.com/acme/widgets/issues/12
  [ "$status" -eq 0 ]
  grep -q 'Add a dry-run flag' "$p/.nightshift/punch-list.md"
  grep -q 'Source: https://github.com/acme/widgets/issues/12' "$p/.nightshift/punch-list.md"
  if grep -q 'Source: https://github.com/acme/widgets/issues/12' "$p/.nightshift/drafting-table.md"; then
    return 1
  fi
  grep -q 'Vague idea' "$p/.nightshift/drafting-table.md"
  grep -q 'Keep this ordinary draft' "$p/.nightshift/drafting-table.md"
  if grep -q 'Keep this ordinary draft' "$p/.nightshift/punch-list.md"; then
    return 1
  fi
}

@test "promote refuses flagged, duplicate, and out-of-repo issues without writing" {
  p="$(new_project)"
  prep "$p"
  run isolated_import "$p" --stage https://github.com/acme/widgets/issues/12 https://github.com/acme/widgets/issues/14
  [ "$status" -eq 0 ]
  before_d="$(cksum "$p/.nightshift/drafting-table.md")"
  before_p="$(cksum "$p/.nightshift/punch-list.md")"

  run env PATH="$PATH" bash "$IMPORT" --project "$p" --promote https://github.com/acme/widgets/issues/14
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qi 'flagged'
  [ "$(cksum "$p/.nightshift/drafting-table.md")" = "$before_d" ]
  [ "$(cksum "$p/.nightshift/punch-list.md")" = "$before_p" ]

  run env PATH="$PATH" bash "$IMPORT" --project "$p" --promote --authorized-repo other/repo \
    https://github.com/acme/widgets/issues/12
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qi 'authorized'
  [ "$(cksum "$p/.nightshift/drafting-table.md")" = "$before_d" ]

  run env PATH="$PATH" bash "$IMPORT" --project "$p" --promote https://github.com/acme/widgets/issues/12
  [ "$status" -eq 0 ]
  run env PATH="$PATH" bash "$IMPORT" --project "$p" --promote https://github.com/acme/widgets/issues/12
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qi 'already on the punch list\|not a proposed'
  grep -c 'Source: https://github.com/acme/widgets/issues/12' "$p/.nightshift/punch-list.md" | grep -qx 1
}

@test "promote never invokes gh" {
  p="$(new_project)"
  prep "$p"
  run isolated_import "$p" --stage https://github.com/acme/widgets/issues/12
  : >"$BATS_TEST_TMPDIR/gh.log"
  run env PATH="$(dirname "$FAKE_GH"):$PATH" IMPORT_GH_LOG="$BATS_TEST_TMPDIR/gh.log" \
    bash "$IMPORT" --project "$p" --promote https://github.com/acme/widgets/issues/12
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/gh.log" ]
}

@test "a partial queue replacement rolls both live files back" {
  p="$(new_project)"
  prep "$p"
  run isolated_import "$p" --stage https://github.com/acme/widgets/issues/12
  [ "$status" -eq 0 ]
  before_d="$(cksum "$p/.nightshift/drafting-table.md")"
  before_p="$(cksum "$p/.nightshift/punch-list.md")"

  mkdir -p "$BATS_TEST_TMPDIR/fail-mv"
  cat >"$BATS_TEST_TMPDIR/fail-mv/mv" <<'SH'
#!/bin/sh
case "$1" in
  *drafting-table.md.next) exit 1 ;;
esac
exec /bin/mv "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/fail-mv/mv"

  run env PATH="$BATS_TEST_TMPDIR/fail-mv:$PATH" bash "$IMPORT" --project "$p" \
    --promote https://github.com/acme/widgets/issues/12
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -q 'Both live queues were restored'
  [ "$(cksum "$p/.nightshift/drafting-table.md")" = "$before_d" ]
  [ "$(cksum "$p/.nightshift/punch-list.md")" = "$before_p" ]
  if find "$p/.nightshift" -name '*.rollback.*' -o -name '*.next' | grep -q .; then
    return 1
  fi
}
