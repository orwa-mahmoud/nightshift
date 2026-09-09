README="$BATS_TEST_DIRNAME/../README.md"
INDEX="$BATS_TEST_DIRNAME/../examples/README.md"
T="$BATS_TEST_DIRNAME/../examples/bad-night-template.md"
SECURITY="$BATS_TEST_DIRNAME/../SECURITY.md"

@test "README points at the receipt index" {
  grep -qF '](examples/README.md#real-runs)' "$README"
}

@test "receipt index organizes real runs and the bad-night template" {
  grep -qF '(adapttable-continuity.md)' "$INDEX"
  grep -qF '(adapttable-overnight.md)' "$INDEX"
  grep -qF '(self-build.md)' "$INDEX"
  grep -qF '(codex-hardening-shift.md)' "$INDEX"
  grep -qF '(bad-night-template.md)' "$INDEX"
  grep -qF 'orwa-mahmoud/nightshift/issues/22' "$INDEX"
}

@test "the template separates facts from interpretation and refuses tick-as-proof" {
  grep -qF '[receipt library](README.md)' "$T"
  grep -qF '## Facts (observed)' "$T"
  grep -qF '## Interpretation (yours, not the agent' "$T"
  grep -qi 'not independent proof' "$T"
  grep -qF '## Redaction checklist' "$T"
  grep -qF 'No prompts' "$T"
  grep -qF 'No credentials' "$T"
  grep -qF 'No full session transcript' "$T"
  grep -qF 'orwa-mahmoud/nightshift/issues/22' "$T"
  grep -qF 'security/advisories/new' "$T"
}

@test "the template asks for public links only when the run is public" {
  grep -qF 'only if the run is public' "$T"
  grep -qF 'This file is a template, not a recorded night' "$T"
  if grep -qiE '2026-0[0-9]-[0-9]{2} .*watchman' "$T"; then
    return 1
  fi
}

@test "bad-night template links resolve" {
  [ -f "$BATS_TEST_DIRNAME/../examples/adapttable-overnight.md" ]
  [ -f "$BATS_TEST_DIRNAME/../examples/codex-hardening-shift.md" ]
  [ -f "$BATS_TEST_DIRNAME/../docs/troubleshooting.md" ]
  [ -f "$SECURITY" ]
}
