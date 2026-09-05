#!/usr/bin/env bats
# The three policy files: their schemas, the helper's verbs, and the lifecycle around them.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
SP="$ROOT/plugins/nightshift/runtime/shift-policy.sh"
LIB="$ROOT/plugins/nightshift/lib/lib.sh"
SCHEMAS="$ROOT/plugins/nightshift/skills/nightshift/references/schemas/v1"
VALIDATOR="$BATS_TEST_DIRNAME/helpers/validate-json-schema.py"

sp() {
  local p="$1"
  shift
  bash "$SP" --project "$p" "$@"
}

# A project with rules but no armed marker: composition writes before the clock starts.
unarmed() {
  local p
  p="$(new_project "${1:-policy}")"
  rm -f "$p/.nightshift/.shift-armed"
  printf '%s' "$p"
}

policy_json() { # [extra top-level JSON, without the leading comma]
  printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z",'
  printf '"source":"composition","deadlineEpoch":null,"verificationLevel":"final",'
  printf '"toolingPolicy":"existing-tools"%s}\n' "${1:+,$1}"
}

write_policy() { # <project> [extra JSON]
  policy_json "${2:-}" >"$1/.nightshift/shift-policy.json"
}

@test "both new schemas are draft-07 and closed to unknown fields" {
  for s in shift-policy shift-defaults; do
    jq -e '.["$schema"] == "http://json-schema.org/draft-07/schema#"' "$SCHEMAS/$s.json" >/dev/null
    jq -e '.type == "object" and .additionalProperties == false' "$SCHEMAS/$s.json" >/dev/null
    jq -e '.properties.schemaVersion.enum == [1]' "$SCHEMAS/$s.json" >/dev/null
  done
  jq -e '.required == ["schemaVersion","shiftId","createdAt","source","verificationLevel","toolingPolicy"]' \
    "$SCHEMAS/shift-policy.json" >/dev/null
  jq -e '.properties.allowances.items.properties.category.enum
         == ["sudo","containers","global-packages","daemons","external-services"]' \
    "$SCHEMAS/shift-policy.json" >/dev/null
  # The remembered choices never carry elevation: that is the whole point of the file.
  jq -e '.properties | has("allowances") | not' "$SCHEMAS/shift-defaults.json" >/dev/null
  jq -e '.properties | has("elevation") | not' "$SCHEMAS/shift-defaults.json" >/dev/null
}

@test "a written policy and the remembered defaults validate against their schemas" {
  p="$(unarmed sp-valid)"
  write_policy "$p" '"allowances":[{"category":"containers","scope":"category","provenance":"one-shift"}]'
  run sp "$p" set --from-json "$p/.nightshift/shift-policy.json"
  [ "$status" -eq 0 ]
  python3 "$VALIDATOR" "$SCHEMAS/shift-policy.json" "$p/.nightshift/shift-policy.json"
  sp "$p" defaults-set --verificationProfile strict --hours 8 >/dev/null
  python3 "$VALIDATOR" "$SCHEMAS/shift-defaults.json" "$p/.nightshift/shift-defaults.json"
}

@test "get prints an empty object and exits 3 when there is no policy yet" {
  p="$(unarmed sp-absent)"
  run sp "$p" get
  [ "$status" -eq 3 ]
  [ "$output" = '{}' ]
}

@test "set round-trips through get as compact canonical JSON" {
  p="$(unarmed sp-round)"
  policy_json >"$p/candidate.json"
  run sp "$p" set --from-json "$p/candidate.json"
  [ "$status" -eq 0 ]
  run sp "$p" get
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -caS . "$p/candidate.json")" ]
  # The file on disk stays readable for the owner who opens it.
  grep -q '"shiftId": "9f2c40ab77e51d63"' "$p/.nightshift/shift-policy.json"
}

@test "set reads the policy from stdin" {
  p="$(unarmed sp-stdin)"
  policy_json | sp "$p" set --from-json -
  run sp "$p" get
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.source == "composition"' >/dev/null
}

@test "every schema violation is refused with exit 2 naming the field" {
  p="$(unarmed sp-bad)"
  check() { # <field-name-expected-in-message> <json>
    printf '%s\n' "$2" >"$p/bad.json"
    run sp "$p" set --from-json "$p/bad.json"
    [ "$status" -eq 2 ] || { echo "expected exit 2 for $1, got $status"; return 1; }
    printf '%s\n' "$output" | grep -qF "$1" || { echo "message did not name $1: $output"; return 1; }
    [ ! -e "$p/.nightshift/shift-policy.json" ] || { echo "wrote a refused policy"; return 1; }
  }
  check schemaVersion '{"schemaVersion":2,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","verificationLevel":"final","toolingPolicy":"auto-add"}'
  check shiftId '{"schemaVersion":1,"shiftId":"nope","createdAt":"x","source":"composition","verificationLevel":"final","toolingPolicy":"auto-add"}'
  check verificationLevel '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","verificationLevel":"loud","toolingPolicy":"auto-add"}'
  check toolingPolicy '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","verificationLevel":"final","toolingPolicy":"whatever"}'
  check source '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"somewhere","verificationLevel":"final","toolingPolicy":"auto-add"}'
  check deadlineEpoch '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","deadlineEpoch":"tonight","verificationLevel":"final","toolingPolicy":"auto-add"}'
  check createdAt '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"","source":"composition","verificationLevel":"final","toolingPolicy":"auto-add"}'
  check budgets '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","verificationLevel":"final","toolingPolicy":"auto-add","budgets":{"tokens":-4}}'
  check gatesDigest '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","verificationLevel":"final","toolingPolicy":"auto-add","gatesDigest":"short"}'
  check makeItSo '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","verificationLevel":"final","toolingPolicy":"auto-add","makeItSo":true}'
  check 'allowances[0].category' '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","verificationLevel":"final","toolingPolicy":"auto-add","allowances":[{"category":"network","scope":"category","provenance":"one-shift"}]}'
  check 'allowances[0].scope' '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","verificationLevel":"final","toolingPolicy":"auto-add","allowances":[{"category":"sudo","scope":"everything","provenance":"one-shift"}]}'
  check 'allowances[0].provenance' '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","verificationLevel":"final","toolingPolicy":"auto-add","allowances":[{"category":"sudo","scope":"category","provenance":"the-agent"}]}'
  check 'allowances[0].plan' '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","verificationLevel":"final","toolingPolicy":"auto-add","allowances":[{"category":"sudo","scope":"exact-plan","provenance":"one-shift"}]}'
  check 'allowances[0].plan.digest' '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","verificationLevel":"final","toolingPolicy":"auto-add","allowances":[{"category":"sudo","scope":"exact-plan","provenance":"one-shift","plan":{"commands":["sudo id"],"workTarget":"/w","digest":"nope"}}]}'
  check 'allowances[0].plan.commands' '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"x","source":"composition","verificationLevel":"final","toolingPolicy":"auto-add","allowances":[{"category":"sudo","scope":"exact-plan","provenance":"one-shift","plan":{"commands":[],"workTarget":"/w","digest":"3b1c9a5e77d0426f8a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071"}}]}'
}

@test "a policy that is not JSON, or not an object, is refused without touching the file" {
  p="$(unarmed sp-nonjson)"
  printf '{ truncated\n' >"$p/bad.json"
  run sp "$p" set --from-json "$p/bad.json"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'not JSON'
  printf '[1,2,3]\n' >"$p/bad.json"
  run sp "$p" set --from-json "$p/bad.json"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'not a JSON object'
}

@test "set and defaults-set are refused while the shift is armed" {
  p="$(new_project sp-armed)"
  [ -f "$p/.nightshift/.shift-armed" ]
  policy_json >"$p/candidate.json"
  run sp "$p" set --from-json "$p/candidate.json"
  [ "$status" -eq 4 ]
  printf '%s\n' "$output" | grep -qF 'while the shift is armed'
  [ ! -e "$p/.nightshift/shift-policy.json" ]
  run sp "$p" defaults-set --hours 3
  [ "$status" -eq 4 ]
  [ ! -e "$p/.nightshift/shift-defaults.json" ]
}

@test "defaults-get answers with built-ins when the file is absent or malformed" {
  p="$(unarmed sp-def)"
  run sp "$p" defaults-get
  [ "$status" -eq 0 ]
  [ "$output" = '{"execution":"review-first","hours":null,"schemaVersion":1,"toolingPolicy":"existing-tools","updatedAt":null,"verificationProfile":"fast"}' ]
  printf '{ truncated\n' >"$p/.nightshift/shift-defaults.json"
  run sp "$p" defaults-get
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.verificationProfile == "fast" and .toolingPolicy == "existing-tools"' >/dev/null
  printf '{"schemaVersion":1,"toolingPolicy":"nonsense"}\n' >"$p/.nightshift/shift-defaults.json"
  run sp "$p" defaults-get
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.toolingPolicy == "existing-tools"' >/dev/null
}

@test "defaults-set remembers one field at a time and refuses an unknown value" {
  p="$(unarmed sp-defset)"
  sp "$p" defaults-set --toolingPolicy auto-add >/dev/null
  sp "$p" defaults-set --execution run-direct >/dev/null
  run sp "$p" defaults-get
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.toolingPolicy == "auto-add" and .execution == "run-direct"' >/dev/null
  run sp "$p" defaults-set --verificationProfile thorough
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF verificationProfile
  run sp "$p" defaults-set --hours later
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF hours
}

@test "archive files the snapshot under its date and shift id, and get goes quiet" {
  p="$(unarmed sp-archive)"
  policy_json >"$p/candidate.json"
  sp "$p" set --from-json "$p/candidate.json" >/dev/null
  run sp "$p" archive
  [ "$status" -eq 0 ]
  dated="$(cd -P "$p" && pwd)/.nightshift/archive/$(date '+%Y-%m-%d')/shift-policy-9f2c40ab77e51d63.json"
  [ "$output" = "$dated" ]
  [ -f "$dated" ]
  [ ! -e "$p/.nightshift/shift-policy.json" ]
  jq -e '.shiftId == "9f2c40ab77e51d63"' "$dated" >/dev/null
  run sp "$p" archive
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | grep -qF 'no shift-policy.json to archive'
}

@test "resolve prints the frozen view in JSON and as a table" {
  p="$(unarmed sp-resolve)"
  write_policy "$p" '"allowances":[{"category":"containers","scope":"category","provenance":"one-shift"}]'
  run sp "$p" resolve --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .schemaVersion == 1
    and (.settings | keys | length) == 14
    and .settings["elevation.containers"] == {value: "allow", source: "one-shift", expiry: "shift"}
    and .settings.verificationLevel.source == "one-shift"
  ' >/dev/null
  [ "$output" = "$(printf '%s' "$output" | jq -caS .)" ]
  run sp "$p" resolve
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.schemaVersion == 1' >/dev/null
  run sp "$p" resolve --table
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 14 ]
  printf '%s\n' "$output" | grep -qxF 'elevation.containers=allow (one-shift, shift)'
  printf '%s\n' "$output" | grep -qxF 'elevation.sudo=deny (rules, permanent)'
  [ "$(printf '%s\n' "$output" | LC_ALL=C sort)" = "$output" ]
}

@test "the resolver survives with python3 and no jq, byte for byte" {
  bin="$(build_toolset_bin no-jq bash sh sed tr sort grep cut awk cat python3 mktemp uname date \
    rm mv cp ln printf head tail wc find test dirname)"
  p="$(unarmed sp-nojq)"
  write_policy "$p" '"allowances":[{"category":"daemons","scope":"category","provenance":"rules"}]'
  jq_out="$(sp "$p" resolve --json)"
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash "$SP" --project "$p" resolve --json
  [ "$status" -eq 0 ]
  [ "$output" = "$jq_out" ]
}

# The snapshot is where tonight's deadline, verification level and elevation allowances live.
# None of that may quietly stop applying because a host has no jq and no python3, so the same
# bounded reader that reads the rules file reads this one too.
@test "without jq and without python3 the answer is the same one" {
  bin="$(build_toolset_bin no-json bash sh sed tr sort grep cut awk cat mktemp uname date \
    rm mv cp ln printf head tail wc find test dirname)"
  [ ! -e "$bin/jq" ]
  [ ! -e "$bin/python3" ]
  p="$(unarmed sp-noparser)"
  write_policy "$p"
  for verb in get resolve defaults-get; do
    with="$(bash "$SP" --project "$p" "$verb")" || { echo "$verb failed with a parser"; return 1; }
    run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
      bash "$SP" --project "$p" "$verb"
    [ "$status" -eq 0 ] || { echo "$verb exited $status: $output"; return 1; }
    [ "$output" = "$with" ] || { echo "$verb drifted without a parser"; return 1; }
  done
}

@test "a snapshot written without a parser is the one a parser reads back" {
  bin="$(build_toolset_bin no-json-write bash sh sed tr sort grep cut awk cat mktemp uname date \
    rm mv cp ln printf head tail wc find test dirname)"
  p="$(unarmed sp-noparser-write)"
  policy_json >"$BATS_TEST_TMPDIR/candidate.json"
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash "$SP" --project "$p" set --from-json "$BATS_TEST_TMPDIR/candidate.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$p/.nightshift/shift-policy.json" ]
  # A parser reads the file back and agrees about every field.
  run bash "$SP" --project "$p" get
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.schemaVersion == 1' >/dev/null
  # And the resolved view is the same whichever engine produced it.
  with="$(bash "$SP" --project "$p" resolve --table)"
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash "$SP" --project "$p" resolve --table
  [ "$output" = "$with" ]
}

@test "an owner choice recorded for the night still applies with no parser" {
  bin="$(build_toolset_bin no-json-choice bash sh sed tr sort grep cut awk cat mktemp uname date \
    rm mv cp ln printf head tail wc find test dirname)"
  p="$(unarmed sp-noparser-choice)"
  # A one-shift allowance and a non-default level, exactly as composition would record them.
  jq -n '{schemaVersion: 1, shiftId: "9f2c40ab77e51d63", createdAt: "2026-09-02T00:00:00Z",
          source: "composition", deadlineEpoch: 1788000000, verificationLevel: "per-item",
          toolingPolicy: "auto-add",
          allowances: [{category: "containers", scope: "category", provenance: "one-shift"}]}' \
    >"$p/.nightshift/shift-policy.json"
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash "$SP" --project "$p" resolve --table
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'verificationLevel=per-item (one-shift, shift)'
  printf '%s\n' "$output" | grep -qxF 'toolingPolicy=auto-add (one-shift, shift)'
  printf '%s\n' "$output" | grep -qxF 'deadlineEpoch=1788000000 (one-shift, shift)'
  printf '%s\n' "$output" | grep -qxF 'elevation.containers=allow (one-shift, shift)'
  # The allowance the owner granted is honoured, and the ones they did not are still denied.
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash -c '. "$1"; ns_policy_allowed "$2" containers "docker run alpine"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash -c '. "$1"; ns_policy_allowed "$2" daemons "systemctl start x"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
}

@test "a host with no reader at all says what is missing and stops" {
  bin="$(build_toolset_bin no-reader bash sh sed tr sort grep cut cat mktemp uname date \
    rm mv cp ln printf head tail wc find test dirname)"
  [ ! -e "$bin/awk" ]
  p="$(unarmed sp-noreader)"
  write_policy "$p"
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash "$SP" --project "$p" get
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'no JSON reader on this host'
}

@test "the helper writes nothing outside .nightshift/" {
  w="$(new_workspace sp-scope)"
  rm -f "$w/.nightshift/.shift-armed"
  printf 'sentinel\n' >"$w/repo/keep-me.txt"
  before="$(find "$w" \( -path "$w/.nightshift" -o -path "$w/.nightshift/*" \) -prune -o -print | LC_ALL=C sort)"
  policy_json >"$BATS_TEST_TMPDIR/candidate.json"
  sp "$w" set --from-json "$BATS_TEST_TMPDIR/candidate.json" >/dev/null
  sp "$w" defaults-set --hours 6 >/dev/null
  sp "$w" resolve >/dev/null
  sp "$w" archive >/dev/null
  after="$(find "$w" \( -path "$w/.nightshift" -o -path "$w/.nightshift/*" \) -prune -o -print | LC_ALL=C sort)"
  [ "$before" = "$after" ]
  [ ! -e "$w/.nightshift/shift-policy.json.tmp" ]
}

@test "the library functions answer directly, without the helper" {
  p="$(unarmed sp-lib)"
  write_policy "$p" '"deadlineEpoch":1800000000,"allowances":[{"category":"sudo","scope":"category","provenance":"rules"}]'
  run bash -c '. "$1"; ns_policy_deadline_epoch "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ "$output" = 1800000000 ]
  run bash -c '. "$1"; ns_policy_shift_id "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ "$output" = 9f2c40ab77e51d63 ]
  run bash -c '. "$1"; ns_policy_allowed "$2" sudo "sudo id"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  run bash -c '. "$1"; ns_policy_allowed "$2" daemons "systemctl start x"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  run bash -c '. "$1"; ns_policy_elevation_pattern "$2" containers' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'docker-compose'
}

@test "an owner pattern in rules.json replaces the shipped one for that category only" {
  p="$(unarmed sp-pattern)"
  jq '.elevation.containers.pattern = "(^|[[:space:]])lima([[:space:]]|$)"' \
    "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run bash -c '. "$1"; ns_policy_elevation_pattern "$2" containers' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ "$output" = '(^|[[:space:]])lima([[:space:]]|$)' ]
  run bash -c '. "$1"; ns_policy_elevation_pattern "$2" sudo' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'd[o]as'
}

@test "the batch pattern accessor answers exactly as five single calls do" {
  p="$(unarmed sp-batch)"
  rules="$p/.nightshift/rules.json"
  batch="$BATS_TEST_TMPDIR/batch"
  singles="$BATS_TEST_TMPDIR/singles"

  every_single() { # one line per category, built the slow way
    bash -c '
      . "$1"
      for c in sudo containers global-packages daemons external-services; do
        printf "%s\t%s\n" "$c" "$(ns_policy_elevation_pattern "$2" "$c")"
      done
    ' _ "$LIB" "$1"
  }
  agree() { # <label> [PATH override]
    if [ -n "${2:-}" ]; then
      env -i PATH="$2" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        bash -c '. "$1"; ns_policy_elevation_patterns "$2"' _ "$LIB" "$p" >"$batch"
      env -i PATH="$2" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        bash -c '
          . "$1"
          for c in sudo containers global-packages daemons external-services; do
            printf "%s\t%s\n" "$c" "$(ns_policy_elevation_pattern "$2" "$c")"
          done
        ' _ "$LIB" "$p" >"$singles"
    else
      bash -c '. "$1"; ns_policy_elevation_patterns "$2"' _ "$LIB" "$p" >"$batch"
      every_single "$p" >"$singles"
    fi
    cmp "$batch" "$singles" || { echo "batch and single calls differ: $1"; return 1; }
    [ "$(wc -l <"$batch" | tr -d ' ')" -eq 5 ] || { echo "expected five lines: $1"; return 1; }
  }

  # The shipped template.
  agree template
  cut -f1 <"$batch" >"$BATS_TEST_TMPDIR/order"
  printf 'sudo\ncontainers\nglobal-packages\ndaemons\nexternal-services\n' \
    >"$BATS_TEST_TMPDIR/want-order"
  cmp "$BATS_TEST_TMPDIR/order" "$BATS_TEST_TMPDIR/want-order"
  grep -qxF "sudo$(printf '\t')$(jq -r '.elevation.sudo.pattern' "$rules")" "$batch"

  # An owner pattern for one category, the shipped pattern for the rest.
  jq '.elevation.containers.pattern = "(^|[[:space:]])lima([[:space:]]|$)"' "$rules" >"$p/next"
  mv "$p/next" "$rules"
  agree "owner override"
  grep -qxF "containers$(printf '\t')(^|[[:space:]])lima([[:space:]]|\$)" "$batch"

  # A pattern grep -E will not accept comes back verbatim from both, for the caller to judge.
  jq '.elevation.daemons.pattern = "systemctl("' "$rules" >"$p/next"
  mv "$p/next" "$rules"
  agree "invalid pattern"
  grep -qxF "daemons$(printf '\t')systemctl(" "$batch"

  # No elevation object, an unreadable file, and no file at all all fall back the same way.
  jq 'del(.elevation)' "$rules" >"$p/next"
  mv "$p/next" "$rules"
  agree "no elevation object"
  shipped="$(cat "$batch")"
  printf '{ truncated\n' >"$rules"
  agree "malformed rules"
  [ "$(cat "$batch")" = "$shipped" ]
  rm -f "$rules"
  agree "no rules file"
  [ "$(cat "$batch")" = "$shipped" ]

  # And the same on a PATH with python3 but no jq.
  cp "$RULES_TEMPLATE" "$rules"
  bin="$(build_toolset_bin batch-nojq bash sh sed tr sort grep cut awk cat python3 mktemp uname \
    date rm mv cp ln printf head tail wc find test dirname cmp)"
  agree "python3 backend" "$bin"
}
