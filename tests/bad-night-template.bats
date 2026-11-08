README="$BATS_TEST_DIRNAME/../README.md"
INDEX="$BATS_TEST_DIRNAME/../examples/README.md"
T="$BATS_TEST_DIRNAME/../examples/bad-night-template.md"
SECURITY="$BATS_TEST_DIRNAME/../SECURITY.md"

@test "bad-night template links resolve" {
  [ -f "$BATS_TEST_DIRNAME/../examples/adapttable-overnight.md" ]
  [ -f "$BATS_TEST_DIRNAME/../examples/codex-hardening-shift.md" ]
  [ -f "$BATS_TEST_DIRNAME/../docs/troubleshooting.md" ]
  [ -f "$SECURITY" ]
}
