#!/usr/bin/env bats
# Bash 3.2, the macOS system bash, does not fail a test on a `[[ ]]` or `(( ))` that is not its
# last command, and no bash fails one on a `!` statement. Every such statement in the suite ends in
# an enforcing `||` branch, and these tests hold that line under the system bash.

ROOT="$BATS_TEST_DIRNAME/.."
SCAN="$ROOT/tests/helpers/unenforced-assertions.awk"

# fixture <name> <body> — a one-test Bats file whose test records the bash version running it,
# then runs <body> followed by a passing command. Echoes the path.
fixture() {
  local f="$BATS_TEST_TMPDIR/$1.bats"
  {
    printf '@test "%s" {\n' "$1"
    printf '  printf "%%s\\n" "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" >"%s/%s.bash"\n' \
      "$BATS_TEST_TMPDIR" "$1"
    printf '  %s\n' "$2"
    printf '  true\n}\n'
  } >"$f"
  printf '%s' "$f"
}

# system_bats <file> — run a Bats file under the system bash, first on PATH as on the macOS leg.
system_bats() {
  PATH="/bin:/usr/bin:$PATH" run bats --tap "$1"
}

# bash_of <name> — the major.minor of the bash that ran fixture <name>, as 302 for 3.2.
bash_of() {
  local v
  v="$(cat "$BATS_TEST_TMPDIR/$1.bash")"
  printf '%d' "$((${v%%.*} * 100 + ${v#*.}))"
}

@test "an assertion ending in || false fails its test under the system bash" {
  for body in '[[ abc == *z* ]] || false' '(( 1 == 2 )) || false' '! true || false'; do
    f="$(fixture enforced "$body")"
    system_bats "$f"
    [ "$status" -eq 1 ] || { echo "passed a mismatch under bash $(bash_of enforced): $body"; return 1; }
    [[ "$output" == *'not ok 1 enforced'* ]] || false
  done
}

@test "a bare assertion lets a mismatch through, so the suite never uses one" {
  f="$(fixture bare-not '! true')"
  system_bats "$f"
  [ "$status" -eq 0 ] || { echo "a bare ! failed its test: $output"; return 1; }
  f="$(fixture bare-test '[[ abc == *z* ]]')"
  system_bats "$f"
  if [ "$(bash_of bare-test)" -lt 401 ]; then
    [ "$status" -eq 0 ] || { echo "bash 3.2 failed a bare [[ ]]: $output"; return 1; }
  else
    [ "$status" -eq 1 ] || { echo "bash $(bash_of bare-test) passed a bare [[ ]]: $output"; return 1; }
  fi
}

@test "every [[ ]], (( )) and ! statement in the suite ends in an enforcing branch" {
  run bash -c 'cd "$1" && find tests \( -name "*.bats" -o -name "*.bash" \) -print | sort | xargs awk -f "$2"' \
    _ "$ROOT" "$SCAN"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "end each with || false:"; echo "$output"; return 1; }
}

@test "the scanner flags each bare form and accepts each enforcing one" {
  f="$BATS_TEST_TMPDIR/forms.bats"
  # Bats 1.10 reads an `@test` line inside a heredoc as a test of this file, so the fixture's first
  # line is written on its own.
  printf '@test "forms" {\n' >"$f"
  cat >>"$f" <<'FORMS'
  [[ "$output" == *bare* ]]
  [[ "$output" == *enforced* ]] || false
  (( count == 2 ))
  (( count == 2 )) || return 1
  ! grep -q bare file
  ! grep -q enforced file || false
  ! grep -q echoed file || echo "not a failure"
  ! grep -q '|| false' file
  ! grep -q continued file \
    || { echo "continued"; return 1; }
  [[ "$output" == *'spans
lines'* ]]
  [[ "$output" == *'spans
lines'* ]] || false
  [[ "$output" == *grouped* ]] || {
    echo "grouped"
    return 1
  }
  run tool "$(printf "cat <<'EOF'\n! not a heredoc\nEOF")"
  cat >stub <<'STUB'
[[ -n "$1" ]]
! true
STUB
  ! grep -q after-heredoc file
}
FORMS
  run awk -f "$SCAN" "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$f:2: [[ \"\$output\" == *bare* ]]
$f:4: (( count == 2 ))
$f:6: ! grep -q bare file
$f:8: ! grep -q echoed file || echo \"not a failure\"
$f:9: ! grep -q '|| false' file
$f:12: [[ \"\$output\" == *'spans
$f:25: ! grep -q after-heredoc file" ]
}
