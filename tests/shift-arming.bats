load helpers

ROOT="$BATS_TEST_DIRNAME/.."
SP="$ROOT/plugins/nightshift/runtime/shift-policy.sh"
SCHEMAS="$ROOT/plugins/nightshift/skills/nightshift/references/schemas/v1"
VALIDATOR="$BATS_TEST_DIRNAME/helpers/validate-json-schema.py"

sp() {
  local p="$1"
  shift
  bash "$SP" --project "$p" "$@"
}

# A shift exists because the owner started one. Before v0.7.2 the hooks themselves claimed the
# first session that tripped them while a box was open, so writing a punch list while planning put
# that session on shift — it then could not end its turn and had to either fight the gate or start
# working. `/nightshift:start` writes .shift-armed; nothing else does.

@test "an unarmed site releases the session even with open boxes" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  punch_open "$p"
  run gate "$p"
  is_release
}

@test "an unarmed site never claims a session" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  punch_open "$p"
  run gate "$p"
  [ ! -f "$p/.nightshift/.shift-session" ]
}

@test "an armed site still holds a session with open boxes" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p"
  is_block "$output"
}

@test "arming is what binds the session, so the record appears only once armed" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p"
  [ -f "$p/.nightshift/.shift-session" ]
}

# The guards are the shift's. Outside one, this is an ordinary session in an ordinary project.
@test "an unarmed site applies no hardhat guard" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  punch_open "$p"
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_allow
}

@test "an armed site applies the hardhat guard" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
}

# A finished shift stops being a shift, or the guards would follow the project into whatever
# ordinary session opens it next.
@test "ending the shift disarms the site" {
  p="$(new_project)"
  punch_done "$p"
  run gate "$p"
  is_release
  [ ! -f "$p/.nightshift/.shift-armed" ]
}

# Only the Items list is the shift. A checkbox in the contract prose above it is an example, and
# counting it would hold a session over work nobody queued.
@test "a checkbox above the Items heading is not the shift" {
  p="$(new_project)"
  printf '# Punch List\n\n- [ ] this is prose, not work\n\n## Items\n- [x] **1. done.**\n' \
    >"$p/.nightshift/punch-list.md"
  run gate "$p"
  is_release
}

@test "a checkbox below the Items heading is the shift" {
  p="$(new_project)"
  printf '# Punch List\n\n- [ ] this is prose, not work\n\n## Items\n- [ ] **1. real.**\n' \
    >"$p/.nightshift/punch-list.md"
  run gate "$p"
  is_block "$output"
}

# The contract references the Items list in prose. If those references were the literal heading,
# scoping the count would start at the first sentence and the whole contract would read as work.
@test "the shipped template carries the Items heading exactly once" {
  n="$(grep -c '^## Items[[:space:]]*$' "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/templates/punch-list.md")"
  [ "$n" -eq 1 ]
  m="$(grep -c '## Items' "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/templates/punch-list.md")"
  [ "$m" -eq 1 ]
}

@test "start is the command that arms the gate" {
  s="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/start/SKILL.md"
  grep -qF '$NS/.shift-armed' "$s"
  grep -qF 'Arm the gate' "$s"
}

@test "the preflight names knobs a plugin update brought" {
  p="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/start-preflight.sh"
  grep -qF 'knobs this file lacks' "$p"
  grep -qF 'Start never adds them' "$p"
}

@test "host detail names the native Windows JSON reader" {
  s="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/hosts/windows.md"
  grep -qF 'PSObject.Properties.Name' "$s"
  grep -qF 'ConvertFrom-Json' "$s"
}

@test "stand-down matches Windows watchman start before kill" {
  # This stopped being documentation when the preflight took it over: a page describing what the
  # helper does can drift from it, and the behaviour is what has to hold.
  m="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"
  grep -qF 'Test-NSRecordedProcess' "$m"
  grep -qF 'Stop-Process -Id' "$m"
  # A pid is only killed once it has been matched to the recorded start time: a reused pid is a
  # different process.
  grep -qF 'Test-NSRecordedProcess' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/start-preflight.ps1"
}

# hunt and quality both start shifts without the owner typing another command. A start path that
# skips the marker writes the items and holds nothing — the failure is silent and looks like work.
@test "every skill that starts a shift arms the gate" {
  for s in start hunt quality; do
    grep -qF '$NS/.shift-armed' "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/$s/SKILL.md" \
      || { echo "starts a shift without arming: $s"; return 1; }
  done
}

@test "a stop-work order disarms the site even with no punch list" {
  p="$(new_project)"
  : >"$p/.nightshift/STOP"
  run gate "$p"
  is_release
  [ ! -f "$p/.nightshift/.shift-armed" ]
}

@test "status reports whether a shift is running" {
  # Status no longer reads the marker: the helper prints an `armed` fact, and says plainly when an
  # unarmed workspace with open boxes is a to-do file rather than a shift.
  h="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
  grep -qF '.shift-armed' "$h"
  grep -qF 'fact "armed"' "$h"
  grep -qF 'to-do file, not a shift' "$h"
}

# Start never asks, on any host, interactive or scheduled. This is the one signal both paths read
# to decide whether a policy is already queued: get exits 3 with {} when there is none, so Start
# writes safe defaults instead of resurrecting anything or prompting. The written document is the
# exact shape Start's own text describes: source start-defaults, existing-tools, no allowances.
@test "an absent policy is the precondition start-defaults exists for, and the document it writes validates" {
  p="$(new_project sa-startdefaults)"
  rm -f "$p/.nightshift/.shift-armed"
  run sp "$p" get
  [ "$status" -eq 3 ]
  [ "$output" = '{}' ]

  candidate='{"schemaVersion":1,"shiftId":"1111111111111111","createdAt":"2026-09-02T03:00:00Z",'
  candidate="$candidate"'"source":"start-defaults","deadlineEpoch":null,"verificationLevel":"none",'
  candidate="$candidate"'"toolingPolicy":"existing-tools","allowances":[]}'
  printf '%s\n' "$candidate" >"$p/candidate.json"
  python3 "$VALIDATOR" "$SCHEMAS/shift-policy.json" "$p/candidate.json"

  run sp "$p" set --from-json "$p/candidate.json"
  [ "$status" -eq 0 ]
  run sp "$p" get
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .source == "start-defaults" and .toolingPolicy == "existing-tools" and .allowances == []
  ' >/dev/null
}

# A queued one-shift allowance expires with the shift it was granted for. The gate is what
# archives the policy at clock-out (hooks/shared/gate-core.sh, lane F); until that lands the
# allowance is never actually consumed and this fails with the exact message below rather than a
# false green.
@test "a queued one-shift allowance is consumed exactly once, when the gate archives the policy" {
  p="$(new_project sa-consumed)"
  rm -f "$p/.nightshift/.shift-armed"
  sid=2222222222222222
  policy="{\"schemaVersion\":1,\"shiftId\":\"$sid\",\"createdAt\":\"2026-09-02T03:00:00Z\","
  policy="$policy\"source\":\"composition\",\"deadlineEpoch\":null,\"verificationLevel\":\"final\","
  policy="$policy\"toolingPolicy\":\"existing-tools\",\"allowances\":["
  policy="$policy{\"category\":\"containers\",\"scope\":\"category\",\"provenance\":\"one-shift\"}]}"
  printf '%s\n' "$policy" >"$p/candidate.json"
  sp "$p" set --from-json "$p/candidate.json" >/dev/null

  run sp "$p" resolve --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .settings["elevation.containers"] == {value: "allow", source: "one-shift", expiry: "shift"}
  ' >/dev/null

  : >"$p/.nightshift/.shift-armed"
  punch_done "$p"
  run gate "$p"
  is_release

  day="$(date '+%Y-%m-%d')"
  archived="$p/.nightshift/archive/$day/shift-policy-$sid.json"
  if [ ! -f "$archived" ]; then
    echo "gate did not archive shift-policy.json (lane F)" >&2
    return 1
  fi
  [ ! -e "$p/.nightshift/shift-policy.json" ]

  run sp "$p" get
  [ "$status" -eq 3 ]
  [ "$output" = '{}' ]
  run sp "$p" resolve --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .settings["elevation.containers"] == {value: "deny", source: "rules", expiry: "permanent"}
  ' >/dev/null
}

# An existing future deadline file is what Start adopts a null policy deadline from, logging the
# adoption rather than deleting the file. The precondition is purely file-level — both files must
# already be readable before Start's own text can decide to adopt — and once the adoption is
# written the resolver reports it exactly like any other one-shift deadline.
@test "an existing future deadline file is readable before Start adopts it, and resolve reports it once written" {
  p="$(new_project sa-deadline)"
  rm -f "$p/.nightshift/.shift-armed"
  future_epoch=$(($(date +%s) + 3600))
  printf '%s\n' "$future_epoch" >"$p/.nightshift/deadline"

  policy='{"schemaVersion":1,"shiftId":"3333333333333333","createdAt":"2026-09-02T03:00:00Z",'
  policy="$policy"'"source":"start-defaults","deadlineEpoch":null,"verificationLevel":"none",'
  policy="$policy"'"toolingPolicy":"existing-tools","allowances":[]}'
  printf '%s\n' "$policy" >"$p/candidate.json"
  sp "$p" set --from-json "$p/candidate.json" >/dev/null

  # The helper-level precondition Start's own text reads before it decides to adopt: both files
  # already on disk and readable, the policy's own deadline still null.
  [ -r "$p/.nightshift/deadline" ]
  [ -r "$p/.nightshift/shift-policy.json" ]
  run sp "$p" resolve --table
  printf '%s\n' "$output" | grep -qxF 'deadlineEpoch=null (one-shift, shift)'

  # What the adoption writes: the policy now carries the deadline file's own value.
  adopted="{\"schemaVersion\":1,\"shiftId\":\"3333333333333333\",\"createdAt\":\"2026-09-02T03:00:00Z\","
  adopted="$adopted\"source\":\"start-defaults\",\"deadlineEpoch\":$future_epoch,\"verificationLevel\":\"none\","
  adopted="$adopted\"toolingPolicy\":\"existing-tools\",\"allowances\":[]}"
  printf '%s\n' "$adopted" >"$p/candidate2.json"
  run sp "$p" set --from-json "$p/candidate2.json"
  [ "$status" -eq 0 ]

  run sp "$p" resolve --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e --argjson e "$future_epoch" '
    .settings.deadlineEpoch == {value: $e, source: "one-shift", expiry: "shift"}
  ' >/dev/null
}
