#!/usr/bin/env bats
# The migration onto the one-file shape, run against the frozen cases in
# tests/fixtures/policy-contract. Those files state what must happen; this runs it and checks.

bats_require_minimum_version 1.5.0

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
SP="$ROOT/plugins/nightshift/runtime/shift-policy.sh"
VALIDATOR="$BATS_TEST_DIRNAME/helpers/validate-json-schema.py"
SCHEMA="$ROOT/plugins/nightshift/skills/nightshift/references/nightshift-rules.schema.json"
FIX="$BATS_TEST_DIRNAME/fixtures/policy-contract"

# case_site <case> — an unarmed workspace holding exactly what that case starts with.
case_site() {
  local p d="$FIX/$1"
  p="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$p/.nightshift"
  cp "$d/rules.json" "$p/.nightshift/rules.json"
  [ ! -f "$d/shift-defaults.json" ] || cp "$d/shift-defaults.json" "$p/.nightshift/"
  if [ "$(jq -r '.armed // false' "$d/expected.json")" = true ]; then
    : >"$p/.nightshift/.shift-armed"
  fi
  printf '%s' "$p"
}

migrate() {
  local p="$1"
  shift
  run bash "$SP" --project "$p" migrate "$@"
}

want() { jq -r "$2" "$FIX/$1/expected.json"; }

@test "every case exits the way the contract says it does" {
  for c in fresh legacy conflict identical repeat malformed armed new-settings-absent; do
    p="$(case_site "$c")"
    migrate "$p"
    [ "$status" -eq "$(want "$c" .exit)" ] \
      || { echo "$c: expected exit $(want "$c" .exit), got $status: $output"; return 1; }
  done
}

@test "a legacy value fills the field the owner file does not carry" {
  p="$(case_site legacy)"
  migrate "$p"
  [ "$status" -eq 0 ]
  # The explicit legacy choice survives; a newer default never replaces it.
  [ "$(jq -r '.shift.toolingPolicy' "$p/.nightshift/rules.json")" = review-missing ]
  [ "$(jq -r '.shift.verificationProfile' "$p/.nightshift/rules.json")" = fast ]
  [ "$(jq -r '.shift.hours' "$p/.nightshift/rules.json")" = null ]
  # A lossless backup of what it read, and the legacy file retired.
  [ -f "$p/.nightshift/shift-defaults.json.bak" ]
  [ ! -f "$p/.nightshift/shift-defaults.json" ]
  diff "$FIX/legacy/shift-defaults.json" "$p/.nightshift/shift-defaults.json.bak"
  python3 "$VALIDATOR" "$SCHEMA" "$p/.nightshift/rules.json"
}

@test "the same answer written twice is one answer" {
  p="$(case_site identical)"
  migrate "$p"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.shift.toolingPolicy' "$p/.nightshift/rules.json")" = review-missing ]
  [ ! -f "$p/.nightshift/shift-defaults.json" ]
}

@test "two explicit values that disagree are refused, and nothing is written" {
  p="$(case_site conflict)"
  before="$(cksum <"$p/.nightshift/rules.json")"
  migrate "$p"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'shift.verificationProfile'
  printf '%s\n' "$output" | grep -qF '"strict"'
  printf '%s\n' "$output" | grep -qF '"fast"'
  printf '%s\n' "$output" | grep -qF 'shift.hours'
  printf '%s\n' "$output" | grep -qF 'run migrate again'
  [ "$(cksum <"$p/.nightshift/rules.json")" = "$before" ]
  [ -f "$p/.nightshift/shift-defaults.json" ]
  [ ! -f "$p/.nightshift/shift-defaults.json.bak" ]
}

@test "a file that does not load is named before anything is written" {
  p="$(case_site malformed)"
  before="$(cksum <"$p/.nightshift/rules.json")"
  migrate "$p"
  [ "$status" -eq 2 ]
  [ "$(cksum <"$p/.nightshift/rules.json")" = "$before" ]
}

@test "an armed workspace is never migrated underneath" {
  p="$(case_site armed)"
  before="$(cksum <"$p/.nightshift/rules.json")"
  migrate "$p"
  [ "$status" -eq 4 ]
  printf '%s\n' "$output" | grep -qF 'stop the shift, migrate, then start again'
  [ "$(cksum <"$p/.nightshift/rules.json")" = "$before" ]
  [ -f "$p/.nightshift/shift-defaults.json" ]
}

@test "running it again does nothing at all" {
  p="$(case_site legacy)"
  migrate "$p"
  [ "$status" -eq 0 ]
  after="$(cksum <"$p/.nightshift/rules.json")"
  migrate "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'no-op'
  [ "$(cksum <"$p/.nightshift/rules.json")" = "$after" ]
  # And a workspace that was already on the shape is a no-op the first time.
  q="$(case_site repeat)"
  migrate "$q"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'no-op'
}

@test "a dry run reports the same thing and writes nothing" {
  p="$(case_site legacy)"
  before="$(cksum <"$p/.nightshift/rules.json")"
  migrate "$p" --dry-run
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'review-missing'
  printf '%s\n' "$output" | grep -qF 'dry run: nothing was written'
  [ "$(cksum <"$p/.nightshift/rules.json")" = "$before" ]
  [ -f "$p/.nightshift/shift-defaults.json" ]
  [ ! -f "$p/.nightshift/shift-defaults.json.bak" ]
}

@test "a plugin update never erases an owner value" {
  p="$(case_site new-settings-absent)"
  migrate "$p"
  [ "$status" -eq 0 ]
  f="$p/.nightshift/rules.json"
  [ "$(jq -r '.watchMinutes' "$f")" = 25 ]
  [ "$(jq -r '.forbiddenCommands' "$f")" = 'git .*push' ]
  [ "$(jq -r '.toolDeny.AskUserQuestion' "$f")" = '' ]
  [ "$(jq -r '.toolDeny.request_user_input' "$f")" = park ]
  python3 "$VALIDATOR" "$SCHEMA" "$f"
}

@test "the migration works with neither jq nor python3" {
  bin="$(build_toolset_bin migrate-no-json bash sh sed tr sort grep cut awk cat mktemp uname date \
    rm mv cp ln printf head tail wc find test dirname basename cksum)"
  [ ! -e "$bin/jq" ]
  [ ! -e "$bin/python3" ]
  p="$(case_site legacy)"
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" bash "$SP" --project "$p" migrate
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.shift.toolingPolicy' "$p/.nightshift/rules.json")" = review-missing ]
  [ -f "$p/.nightshift/shift-defaults.json.bak" ]
}

# After the move, composition reads the choice where it now lives. A workspace that has not
# migrated yet still reports what it remembers, so nobody loses a setting by upgrading.
@test "the remembered choices are read from the owner file once they live there" {
  p="$BATS_TEST_TMPDIR/read-canonical"
  mkdir -p "$p/.nightshift"
  jq '.shift = {verificationProfile: "strict", hours: 6,
                execution: "run-direct", toolingPolicy: "auto-add"}' \
    "$ROOT/plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json" >"$p/.nightshift/rules.json"
  run bash -c '. "$1"; ns_policy_read_defaults "$2"' _ "$ROOT/plugins/nightshift/lib/lib.sh" "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.verificationProfile == "strict" and .hours == 6' >/dev/null
  printf '%s' "$output" | jq -e '.execution == "run-direct" and .toolingPolicy == "auto-add"' >/dev/null
}

@test "a workspace that has not migrated still reports what it remembers" {
  p="$BATS_TEST_TMPDIR/read-legacy"
  mkdir -p "$p/.nightshift"
  jq 'del(.shift)' "$ROOT/plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json" >"$p/.nightshift/rules.json"
  jq -n '{execution: "run-direct", hours: 3, schemaVersion: 1, toolingPolicy: "review-missing",
          updatedAt: "2026-09-05T10:42:17Z", verificationProfile: "balanced"}' \
    >"$p/.nightshift/shift-defaults.json"
  run bash -c '. "$1"; ns_policy_read_defaults "$2"' _ "$ROOT/plugins/nightshift/lib/lib.sh" "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.verificationProfile == "balanced" and .hours == 3' >/dev/null
  printf '%s' "$output" | jq -e '.toolingPolicy == "review-missing"' >/dev/null
}

@test "the owner file wins over a legacy file that disagrees" {
  p="$BATS_TEST_TMPDIR/read-both"
  mkdir -p "$p/.nightshift"
  jq '.shift = {verificationProfile: "strict", hours: 6,
                execution: "run-direct", toolingPolicy: "auto-add"}' \
    "$ROOT/plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json" >"$p/.nightshift/rules.json"
  jq -n '{execution: "review-first", hours: 3, schemaVersion: 1, toolingPolicy: "review-missing",
          updatedAt: "2026-09-05T10:42:17Z", verificationProfile: "balanced"}' \
    >"$p/.nightshift/shift-defaults.json"
  run bash -c '. "$1"; ns_policy_read_defaults "$2"' _ "$ROOT/plugins/nightshift/lib/lib.sh" "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.verificationProfile == "strict" and .hours == 6' >/dev/null
  printf '%s' "$output" | jq -e '.toolingPolicy == "auto-add"' >/dev/null
}
