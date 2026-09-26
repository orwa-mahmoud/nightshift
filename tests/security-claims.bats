SECURITY="$BATS_TEST_DIRNAME/../SECURITY.md"
KNOBS="$BATS_TEST_DIRNAME/../docs/knobs.md"

@test "security policy distinguishes Nightshift from launched agents" {
  grep -qF 'does not phone home' "$SECURITY"
  grep -qF 'coding agent selected by' "$SECURITY"
  if grep -qF 'no network calls' "$SECURITY"; then
    return 1
  fi
}

@test "notification command is documented as unrestricted owner shell" {
  grep -qF 'unrestricted owner-provided shell' "$SECURITY"
  grep -qF 'unrestricted owner-provided shell' "$KNOBS"
  grep -qF 'can access the network' "$KNOBS"
}

@test "command and commit guards name Windows matching" {
  grep -qF 'native Windows uses .NET regular expressions against the host command string' "$KNOBS"
  grep -qF 'native Windows .NET regular expressions, case-insensitive' "$KNOBS"
}

@test "notification command names the Windows child PowerShell" {
  grep -qF 'unrestricted owner-provided shell' "$KNOBS"
  grep -qF 'POSIX uses `sh -c`' "$KNOBS"
  grep -qF 'native Windows runs it with `-Command` in a child PowerShell' "$KNOBS"
}

@test "expected-email guard names git config user.email" {
  grep -qF 'git config user.email' "$KNOBS"
  grep -qF 'GIT_AUTHOR_EMAIL' "$KNOBS"
  grep -qF -- '-c user.email=' "$KNOBS"
}

@test "protected-dir guard names Git path matching" {
  grep -qF 'paths Git would write' "$KNOBS"
  grep -qF 'native Windows also normalizes' "$KNOBS"
}

@test "command and commit guards name invalid-pattern session repair" {
  grep -qF 'invalid pattern fails closed' "$KNOBS"
  grep -qF 'fix it in session settings' "$KNOBS"
}
