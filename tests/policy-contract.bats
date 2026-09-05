#!/usr/bin/env bats
# The owner settings contract: one editable file, one resolved view, and the migration that moves
# a legacy workspace onto it. These fixtures are the frozen expectations — the reader, the
# migration and the resolved view are written against them, not the other way round.

bats_require_minimum_version 1.5.0

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
REFS="$ROOT/plugins/nightshift/skills/nightshift/references"
SCHEMA="$REFS/nightshift-rules.schema.json"
TEMPLATE="$REFS/nightshift-rules-template.json"
VALIDATOR="$BATS_TEST_DIRNAME/helpers/validate-json-schema.py"
FIX="$BATS_TEST_DIRNAME/fixtures/policy-contract"

# Every case the contract names, and nothing invented beside them.
CASES="fresh legacy conflict identical repeat malformed armed new-settings-absent"

owner_file() { printf '%s' "$FIX/$1/rules.json"; }
expected() { printf '%s' "$FIX/$1/expected.json"; }

@test "the contract carries a case for every situation a migration meets" {
  for c in $CASES; do
    [ -d "$FIX/$c" ] || { echo "missing fixture: $c"; return 1; }
    [ -f "$(expected "$c")" ] || { echo "missing expectation: $c"; return 1; }
    jq -e '
      has("case") and has("outcome") and has("exit")
      and has("reason") and has("destination")
      and (.outcome | IN("migrated", "no-op", "refused"))
    ' "$(expected "$c")" >/dev/null || { echo "$c: not a complete expectation"; return 1; }
  done
  # No fixture without a name in the contract above.
  for d in "$FIX"/*/; do
    name="$(basename "$d")"
    printf '%s\n' $CASES | grep -qx "$name" || { echo "unnamed fixture: $name"; return 1; }
  done
}

@test "every destination a migration may write validates against the schema" {
  for c in $CASES; do
    [ "$(jq -r .outcome "$(expected "$c")")" != refused ] || continue
    jq '.destination' "$(expected "$c")" >"$BATS_TEST_TMPDIR/$c.json"
    python3 "$VALIDATOR" "$SCHEMA" "$BATS_TEST_TMPDIR/$c.json" \
      || { echo "$c: destination does not validate"; return 1; }
  done
}

@test "a refusal names its reason and writes nothing" {
  for c in conflict malformed armed; do
    e="$(expected "$c")"
    [ "$(jq -r .outcome "$e")" = refused ]
    [ "$(jq -r '.backup' "$e")" = false ]
    [ -n "$(jq -r .reason "$e")" ]
    # The destination of a refusal is the input, unchanged.
    jq -S '.destination' "$e" >"$BATS_TEST_TMPDIR/$c.dest"
    jq -S . "$(owner_file "$c")" >"$BATS_TEST_TMPDIR/$c.in"
    diff "$BATS_TEST_TMPDIR/$c.in" "$BATS_TEST_TMPDIR/$c.dest" \
      || { echo "$c: a refusal changed the file"; return 1; }
  done
  # An armed workspace refuses on its own exit code, distinct from a contract failure.
  [ "$(jq -r .exit "$(expected armed)")" -eq 4 ]
  [ "$(jq -r .exit "$(expected conflict)")" -eq 2 ]
  [ "$(jq -r .exit "$(expected malformed)")" -eq 2 ]
}

@test "explicit values that disagree name both sides and the next step" {
  e="$(expected conflict)"
  [ "$(jq '.conflicts | length' "$e")" -eq 2 ]
  jq -e '.conflicts | all(has("key") and has("canonical") and has("legacy"))' "$e" >/dev/null
  jq -e '.conflicts[] | select(.key == "shift.verificationProfile")
         | .canonical == "strict" and .legacy == "fast"' "$e" >/dev/null
  [ -n "$(jq -r .nextStep "$e")" ]
}

@test "a legacy value fills an absent field and an identical one coalesces" {
  # The explicit legacy toolingPolicy survives the move; a newer default never replaces it.
  jq -e '.destination.shift.toolingPolicy == "review-missing"' "$(expected legacy)" >/dev/null
  [ "$(jq -r .outcome "$(expected legacy)")" = migrated ]
  [ "$(jq -r .backup "$(expected legacy)")" = true ]
  # Written twice, the same answer is one answer, not a conflict.
  [ "$(jq -r .outcome "$(expected identical)")" = migrated ]
  [ "$(jq '.conflicts | length' "$(expected identical)")" -eq 0 ]
  # And running it again does nothing at all.
  [ "$(jq -r .outcome "$(expected repeat)")" = no-op ]
  [ "$(jq -r .backup "$(expected repeat)")" = false ]
}

@test "a plugin update adds settings and erases no owner value" {
  e="$(expected new-settings-absent)"
  jq -e '.destination.watchMinutes == 25' "$e" >/dev/null
  jq -e '.destination.forbiddenCommands == "git .*push"' "$e" >/dev/null
  jq -e '.destination.toolDeny.AskUserQuestion == ""' "$e" >/dev/null
  # The three newcomers arrive at exactly the shipped defaults.
  for block in shift handoff archive; do
    jq -S --arg b "$block" '.destination[$b]' "$e" >"$BATS_TEST_TMPDIR/$block.got"
    jq -S --arg b "$block" '.[$b]' "$TEMPLATE" >"$BATS_TEST_TMPDIR/$block.want"
    diff "$BATS_TEST_TMPDIR/$block.want" "$BATS_TEST_TMPDIR/$block.got" \
      || { echo "$block did not arrive at its documented default"; return 1; }
  done
}

@test "the schema carries the three settings blocks, closed and documented" {
  for block in shift handoff archive; do
    jq -e --arg b "$block" '.properties[$b].type == "object"' "$SCHEMA" >/dev/null
    jq -e --arg b "$block" '.properties[$b].additionalProperties == false' "$SCHEMA" >/dev/null
    jq -e --arg b "$block" '.properties[$b].description | length > 0' "$SCHEMA" >/dev/null
    jq -e --arg b "$block" '.properties[$b].properties | all(.description | length > 0)' \
      "$SCHEMA" >/dev/null || { echo "$block has an undocumented field"; return 1; }
  done
  jq -e '.properties.shift.properties.verificationProfile.enum
         == ["fast", "balanced", "strict", "custom"]' "$SCHEMA" >/dev/null
  jq -e '.properties.shift.properties.toolingPolicy.enum
         == ["existing-tools", "review-missing", "auto-add"]' "$SCHEMA" >/dev/null
  jq -e '.properties.handoff.properties.view.enum
         == ["owner", "reviewer", "release", "artifact"]' "$SCHEMA" >/dev/null
  jq -e '.properties.handoff.properties.detail.enum == ["concise", "detailed"]' "$SCHEMA" >/dev/null
  jq -e '.properties.handoff.properties.sections.items.enum
         == ["shift", "baseline", "changed", "parked", "unsupported", "next"]' "$SCHEMA" >/dev/null
  jq -e '.properties.archive.properties.layout.enum == ["date", "shift"]' "$SCHEMA" >/dev/null
}

@test "the shipped defaults are the ones the contract documents" {
  jq -e '.shift.verificationProfile == "fast"' "$TEMPLATE" >/dev/null
  jq -e '.shift.hours == null' "$TEMPLATE" >/dev/null
  jq -e '.handoff.enabled == true and .handoff.view == "owner"' "$TEMPLATE" >/dev/null
  jq -e '.handoff.language == "auto" and .handoff.detail == "concise"' "$TEMPLATE" >/dev/null
  jq -e '.handoff.sections == [] and .handoff.templatePath == ""' "$TEMPLATE" >/dev/null
  jq -e '.archive.automatic == false and .archive.root == "archive"' "$TEMPLATE" >/dev/null
  jq -e '.archive.layout == "date" and .archive.templatePath == ""' "$TEMPLATE" >/dev/null
  # Retention keeps forever, and filing an archive never implies pruning one.
  jq -e '.retention.runtimeLogDays == 0 and .retention.archiveDays == 0' "$TEMPLATE" >/dev/null
}

# One statement of what a profile means, so prose, profiles and the main loop cannot drift apart.
@test "a verification profile maps to a cadence in exactly one place" {
  d="$(jq -r '.properties.shift.properties.verificationProfile.description' "$SCHEMA")"
  printf '%s' "$d" | grep -qF 'fast means never'
  printf '%s' "$d" | grep -qF 'balanced once before clock-out'
  printf '%s' "$d" | grep -qF 'strict before every tick and once at the end'
  printf '%s' "$d" | grep -qF 'custom is the cadence the owner names'
  # A fresh workspace verifies nothing until the owner writes gates worth running.
  jq -e '.shift.verificationProfile == "fast"' "$TEMPLATE" >/dev/null
}

# An elevation allowance lifts its own category. It is not a way to reach a command the owner
# forbade by name, and the two rules stay separate on purpose.
@test "an owner denylist stays independent of the elevation categories" {
  jq -e '.forbiddenCommands == ""' "$TEMPLATE" >/dev/null
  for c in $(jq -r '.elevation | keys[]' "$TEMPLATE"); do
    jq -e --arg c "$c" '.elevation[$c].policy == "deny"' "$TEMPLATE" >/dev/null
    # No category pattern is copied into the owner's own list, so lifting a category
    # can never lift a command the owner named there.
    pat="$(jq -r --arg c "$c" '.elevation[$c].pattern' "$TEMPLATE")"
    [ "$(jq -r '.forbiddenCommands' "$TEMPLATE")" != "$pat" ]
  done
  [ "$(jq -r '.elevation | keys | length' "$TEMPLATE")" -eq 5 ]
}
