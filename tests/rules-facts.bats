#!/usr/bin/env bats
# The policy fact stream: every rules setting the resolver reads, printed from the loaded rows exactly
# as recorded in the fixture. Escaped strings are decoded, control characters read as spaces, a string
# array is compact JSON, and a run's own file is laid over the shared one.

load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
FIX="$BATS_TEST_DIRNAME/fixtures/rules-facts"

facts() { bash -c '. "$1"; ns_rules_facts "$2"' _ "$LIB" "$1"; }

@test "the fact stream of a rules file is the recorded one" {
  run facts "$FIX/input.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$FIX/expected.txt")" ] || { diff <(printf '%s\n' "$output") "$FIX/expected.txt"; return 1; }
}

@test "a run's own file replaces a shared array whole and a shared value key by key" {
  local w="$BATS_TEST_TMPDIR/site" f="rules.json"
  mkdir -p "$w/.nightshift/runs/r" "$w/.nightshift/run"
  printf '3\n' >"$w/.nightshift/state-version"
  cp "$FIX/input.json" "$w/.nightshift/$f"
  cp "$FIX/run.json" "$w/.nightshift/runs/r/$f"
  printf '# Punch List\n\n## Items\n' >"$w/.nightshift/runs/r/punch-list.md"
  NIGHTSHIFT_RUN=r run facts "$w/.nightshift/$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$FIX/expected-run.txt")" ] || { diff <(printf '%s\n' "$output") "$FIX/expected-run.txt"; return 1; }
}

@test "a file the reader cannot read gives no facts" {
  printf '{\n  "watchMinutes": 0,\n' >"$BATS_TEST_TMPDIR/broken.json"
  run facts "$BATS_TEST_TMPDIR/broken.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
