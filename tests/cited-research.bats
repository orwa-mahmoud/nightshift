load helpers

CHECK="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/check-report.sh"
CHECK_PS1="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/check-report.ps1"
CHECK_LOGIC="$BATS_TEST_DIRNAME/windows/check-report-logic.ps1"
CONTRACT="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/cited-research.md"
RECIPE="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/catalog-recipe.md"
SHIFTS="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/shifts"
NIGHTSHIFT="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/SKILL.md"
START="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/start/SKILL.md"
COMMANDS="$BATS_TEST_DIRNAME/../docs/commands.md"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"

valid_bundle() {
  local p="$1"
  mkdir -p "$p"
  {
    printf 'ok\t%s\tS1\t%s\n' '2026-08-28T08:00:00Z' 'https://example.com/page'
    printf 'unavailable\t%s\tS2\t%s\n' '2026-08-28T08:00:00Z' 'https://example.com/gone'
  } >"$p/sources.tsv"
  cat >"$p/report.md" <<'EOF'
# Brief

## Executive summary

S1 describes the published page. S2 could not be retrieved.

## Sources

- S1 ok https://example.com/page retrieved 2026-08-28T08:00:00Z
- S2 unavailable https://example.com/gone HTTP 404

## Observations

The page states a heading of "Hello" [S1].

## Inferences

Without S2, ranking claims are out of scope.
EOF
}

@test "the cited-research contract is shared, not a Hunt entry" {
  [ -f "$CONTRACT" ]
  [ ! -f "$SHIFTS/cited-research.md" ]
  grep -qF 'cited-research.md' "$RECIPE"
  grep -qi 'not itself a catalog entry' "$RECIPE" || grep -qi 'not a Hunt catalog entry' "$CONTRACT"
  grep -qF 'cited-research.md' "$NIGHTSHIFT"
  grep -qE 'ns"? check-report' "$NIGHTSHIFT"
  grep -qF 'cited-research.md' "$START"
  grep -qF 'runtime/check-report.sh' "$COMMANDS"
  grep -qF 'runtime\windows\check-report.ps1' "$COMMANDS"
  grep -qF 'runtime\windows\check-report.ps1' "$BATS_TEST_DIRNAME/../docs/windows.md"
  grep -qF 'runtime/check-report.sh' "$BATS_TEST_DIRNAME/../docs/how-it-works.md"
  grep -qE 'ns"? write-receipt' "$CONTRACT"
  grep -qF '$NS/receipts/' "$CONTRACT"
}

@test "the contract forbids fabrication and private material on the wire" {
  grep -qi 'Never fabricate' "$CONTRACT"
  grep -qi 'unavailable' "$CONTRACT"
  grep -qi 'Observations' "$CONTRACT"
  grep -qi 'Inferences' "$CONTRACT"
  grep -qi 'Executive summary' "$CONTRACT"
  grep -qi 'private source code' "$CONTRACT"
  grep -qi 'external search' "$CONTRACT"
  grep -qi 'owner supplies the URLs' "$CONTRACT" || grep -qi 'owner-approved' "$CONTRACT"
}

@test "the contract names three source policies and the resolve helper" {
  grep -qi 'Closed list' "$CONTRACT"
  grep -qi 'Bounded discovery' "$CONTRACT"
  grep -qi 'Connected corpus' "$CONTRACT"
  grep -qi 'receipt-templates.md' "$CONTRACT" || grep -qi 'Do not call' "$CONTRACT"
  grep -qF 'redact-untrusted' "$CONTRACT"
  grep -qi 'primary' "$CONTRACT"
  grep -qi 'secondary' "$CONTRACT"
  grep -qi 'community' "$CONTRACT"
  grep -qi 'untrusted' "$CONTRACT"
}

@test "check-report accepts a complete cited report" {
  p="$(new_project cited-ok)"
  valid_bundle "$p"
  run bash "$CHECK" --project "$p" --report "$p/report.md" --manifest "$p/sources.tsv" \
    --output "$p/report.md"
  [ "$status" -eq 0 ]
}

@test "check-report rejects an unavailable source omitted from Sources" {
  p="$(new_project cited-unav)"
  valid_bundle "$p"
  awk 'tolower($0) ~ /^##[ \t]*sources/ {p=1} p && /S2/ {next} {print}' "$p/report.md" >"$p/report2.md"
  mv "$p/report2.md" "$p/report.md"
  run bash "$CHECK" --project "$p" --report "$p/report.md" --manifest "$p/sources.tsv"
  [ "$status" -eq 2 ]
  printf '%s' "$output$stderr" | grep -qi 'unavailable'
}

@test "check-report rejects an uncited ok source" {
  p="$(new_project cited-uncited)"
  valid_bundle "$p"
  printf 'ok\t2026-08-28T08:00:00Z\tS3\thttps://example.com/other\n' >>"$p/sources.tsv"
  run bash "$CHECK" --project "$p" --report "$p/report.md" --manifest "$p/sources.tsv"
  [ "$status" -eq 2 ]
  printf '%s' "$output$stderr" | grep -qF 'uncited ok source: S3'
}

@test "check-report rejects a fabricated citation" {
  p="$(new_project cited-fake)"
  valid_bundle "$p"
  printf '\nInvented claim [S9].\n' >>"$p/report.md"
  run bash "$CHECK" --project "$p" --report "$p/report.md" --manifest "$p/sources.tsv"
  [ "$status" -eq 2 ]
  printf '%s' "$output$stderr" | grep -qF 'fabricated citation: [S9]'
}

@test "check-report rejects a missing heading" {
  p="$(new_project cited-heading)"
  valid_bundle "$p"
  grep -v 'Executive summary' "$p/report.md" >"$p/report2.md"
  mv "$p/report2.md" "$p/report.md"
  run bash "$CHECK" --project "$p" --report "$p/report.md" --manifest "$p/sources.tsv"
  [ "$status" -eq 2 ]
  printf '%s' "$output$stderr" | grep -qi 'Executive summary'
}

@test "check-report rejects a symlink output" {
  p="$(new_project cited-link)"
  valid_bundle "$p"
  ln -s "$p/report.md" "$p/alias.md"
  run bash "$CHECK" --project "$p" --report "$p/report.md" --manifest "$p/sources.tsv" \
    --output "$p/alias.md"
  [ "$status" -eq 2 ]
  printf '%s' "$output$stderr" | grep -qi 'missing output'
}

@test "check-report rejects a symlink report" {
  p="$(new_project cited-link-report)"
  valid_bundle "$p"
  ln -s "$p/report.md" "$p/alias.md"
  run bash "$CHECK" --project "$p" --report "$p/alias.md" --manifest "$p/sources.tsv"
  [ "$status" -eq 2 ]
  printf '%s' "$output$stderr" | grep -qi 'missing output'
}

@test "check-report rejects empty outputs" {
  p="$(new_project cited-empty)"
  valid_bundle "$p"
  : >"$p/blank.md"
  run bash "$CHECK" --project "$p" --report "$p/report.md" --manifest "$p/sources.tsv" \
    --output "$p/blank.md"
  [ "$status" -eq 2 ]
  printf '%s' "$output$stderr" | grep -qi 'empty output'
}

@test "check-report rejects secret lines" {
  p="$(new_project cited-secret)"
  valid_bundle "$p"
  printf '\npassword=supersecret\n' >>"$p/report.md"
  run bash "$CHECK" --project "$p" --report "$p/report.md" --manifest "$p/sources.tsv"
  [ "$status" -eq 2 ]
  printf '%s' "$output$stderr" | grep -qi 'secret'
}

@test "Windows check-report pairs POSIX and runs when pwsh is present" {
  grep -qE 'ns"? check-report' "$START"
  grep -qF 'missing heading' "$CHECK_PS1"
  grep -qF 'fabricated citation' "$CHECK_PS1"
  grep -qF 'Test-NSSecretLine' "$CHECK_PS1"
  grep -qF 'Test-NSReparsePoint' "$CHECK_PS1"
  grep -qF '[ -L "$abs" ]' "$CHECK"
  grep -qF 'symlink output is missing' "$CHECK_LOGIC"
  [ -f "$CHECK_LOGIC" ]
  grep -qF 'check-report-logic.ps1' "$RUN"
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$CHECK_LOGIC"
  [ "$status" -eq 0 ]
}
