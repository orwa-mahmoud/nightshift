load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
MIGRATE="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/migrate-state.sh"
DOCTOR="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"
CODEX_HOOKS="$HOOKS/codex"
SETUP="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/setup/SKILL.md"
START="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/start/SKILL.md"
STATUS="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/status/SKILL.md"
ARCHIVE="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/archive/SKILL.md"
DOCTOR_SKILL="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/doctor/SKILL.md"

fingerprint() {
  (cd "$1" && find . \( -type f -o -type l \) -exec cksum {} \; | sort)
}

kind() {
  bash -c '. "$1"; ns_state_kind "$2"' _ "$LIB" "$1"
}

codex_gate() {
  hook_payload "$(jq -nc '{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:""}')" \
    env CODEX_PROJECT_DIR="$1" bash "$CODEX_HOOKS/clock-out-gate.sh"
}

codex_ask() {
  hook_payload "$(jq -nc '{tool_name:"request_user_input",tool_input:{}}')" \
    env CODEX_PROJECT_DIR="$1" bash "$CODEX_HOOKS/hardhat.sh"
}

@test "helpers classify missing, older, current, legacy-zero, malformed, and future markers" {
  p="$(new_project)"
  run bash -c '. "$1"; ns_state_kind "$2"; echo; ns_state_version "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | awk 'NR==1{exit $0=="legacy"?0:1}'
  printf '%s\n' "$output" | awk 'NR==2{exit $0=="0"?0:1}'

  printf '1\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_state_kind "$2"; echo; ns_state_version "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | awk 'NR==1{exit $0=="legacy"?0:1}'
  printf '%s\n' "$output" | awk 'NR==2{exit $0=="1"?0:1}'

  printf '2\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_state_kind "$2"; echo; ns_state_version "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | awk 'NR==1{exit $0=="current"?0:1}'
  printf '%s\n' "$output" | awk 'NR==2{exit $0=="2"?0:1}'

  printf '0\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_state_kind "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ "$output" = "legacy" ]

  printf 'not-a-version\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_state_kind "$2"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  [ "$output" = "malformed" ]

  printf '3\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_state_kind "$2"; echo; ns_state_version "$2"' _ "$LIB" "$p"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | awk 'NR==1{exit $0=="future"?0:1}'
  printf '%s\n' "$output" | awk 'NR==2{exit $0=="3"?0:1}'
}

@test "symlink, extra lines, and leading zeros are malformed" {
  p="$(new_project)"
  ln -s /tmp/not-a-state "$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_state_kind "$2"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  [ "$output" = "malformed" ]

  rm -f "$p/.nightshift/state-version"
  printf '1\n2\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_state_kind "$2"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  [ "$output" = "malformed" ]

  printf '01\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_state_kind "$2"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  [ "$output" = "malformed" ]
}

@test "a new state directory is born at the current version and has nothing to migrate" {
  p="$BATS_TEST_TMPDIR/fresh"
  mkdir -p "$p"
  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/scaffold.sh" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$p/.nightshift/state-version")" = "2" ]
  before="$(fingerprint "$p")"
  run bash "$MIGRATE" --project "$p" --apply
  [ "$status" -eq 0 ]
  [ "$(fingerprint "$p")" = "$before" ]
}

@test "future and malformed markers are never rewritten or downgraded" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '9\n' >"$p/.nightshift/state-version"
  run bash "$MIGRATE" --project "$p" --apply
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -q 'newer than this plugin supports'
  [ "$(cat "$p/.nightshift/state-version")" = "9" ]

  printf 'nope\n' >"$p/.nightshift/state-version"
  run bash "$MIGRATE" --project "$p" --apply
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -q 'malformed'
  [ "$(cat "$p/.nightshift/state-version")" = "nope" ]
}

@test "legacy and current workspaces stay operable on both host gates" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p"
  is_block "$output"
  rm -f "$p/.nightshift/.shift-session" "$p/.nightshift/.shift-lease"
  run codex_gate "$p"
  is_block "$output"

  printf '1\n' >"$p/.nightshift/state-version"
  rm -f "$p/.nightshift/.shift-session" "$p/.nightshift/.shift-lease"
  run gate "$p"
  is_block "$output"
  rm -f "$p/.nightshift/.shift-session" "$p/.nightshift/.shift-lease"
  run codex_gate "$p"
  is_block "$output"

  # The current layout keeps the markers in run/, and both gates read them there.
  rm -f "$p/.nightshift/.shift-session" "$p/.nightshift/.shift-lease"
  mkdir -p "$p/.nightshift/run"
  mv "$p/.nightshift/.shift-armed" "$p/.nightshift/run/.shift-armed"
  printf '2\n' >"$p/.nightshift/state-version"
  run gate "$p"
  is_block "$output"
  rm -f "$p/.nightshift/run/.shift-session" "$p/.nightshift/run/.shift-lease"
  run codex_gate "$p"
  is_block "$output"
  [ ! -e "$p/.nightshift/.shift-session" ]
}

@test "both host gates and hardhats fail closed on future and malformed markers" {
  p="$(new_project)"
  punch_open "$p"
  # A newer marker reads as the newest layout this plugin knows, a malformed one as version 1: the
  # shift is armed where each reads it, and each refuses rather than guess.
  mkdir -p "$p/.nightshift/run"
  : >"$p/.nightshift/run/.shift-armed"
  printf '3\n' >"$p/.nightshift/state-version"

  run gate "$p"
  is_block "$output"
  printf '%s' "$output" | grep -q 'newer than this plugin supports'
  printf '%s' "$output" | jq -e . >/dev/null
  run codex_gate "$p"
  is_block "$output"
  printf '%s' "$output" | grep -q 'newer than this plugin supports'

  run hardhat_ask "$p"
  is_deny "$output"
  printf '%s' "$output" | grep -q 'newer than this plugin supports'
  run codex_ask "$p"
  is_deny "$output"
  printf '%s' "$output" | grep -q 'newer than this plugin supports'

  printf 'bad\n' >"$p/.nightshift/state-version"
  run gate "$p"
  is_block "$output"
  printf '%s' "$output" | grep -q 'malformed'
  run hardhat_ask "$p"
  is_deny "$output"
  printf '%s' "$output" | grep -q 'malformed'
  run codex_gate "$p"
  is_block "$output"
  run codex_ask "$p"
  is_deny "$output"
}

@test "Doctor reports every kind and never migrates" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  before="$(fingerprint "$p")"
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'State:       0 (legacy)'
  printf '%s' "$output" | grep -q '\[confirm\] move the state files into layout 2.*state-version 0 -> 2.*migrate-state.sh'
  after="$(fingerprint "$p")"
  [ "$before" = "$after" ]
  [ ! -e "$p/.nightshift/state-version" ]

  : >"$p/.nightshift/.shift-armed"
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'the move into layout 2 waits: the shift is armed'
  printf '%s' "$output" | grep -q '\[blocked\] move the state files into layout 2'
  [ ! -e "$p/.nightshift/state-version" ]

  rm -f "$p/.nightshift/.shift-armed"
  printf '1\n' >"$p/.nightshift/state-version"
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'State:       1 (legacy)'
  printf '%s' "$output" | grep -q 'state version 1 (every state file sits at the top of .nightshift/)'
  printf '%s' "$output" | grep -q '\[confirm\] move the state files into layout 2.*state-version 1 -> 2'

  printf '2\n' >"$p/.nightshift/state-version"
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'State:       2 (current)'
  printf '%s' "$output" | grep -q 'state version 2 (current)'
  if printf '%s' "$output" | grep -q '\[confirm\].*migrate-state.sh'; then
    return 1
  fi

  printf '4\n' >"$p/.nightshift/state-version"
  before="$(fingerprint "$p")"
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'State:       4 (future)'
  printf '%s' "$output" | grep -q '\[blocked\].*never rewrite or downgrade'
  after="$(fingerprint "$p")"
  [ "$before" = "$after" ]
  [ "$(cat "$p/.nightshift/state-version")" = "4" ]

  printf '??\n' >"$p/.nightshift/state-version"
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'State:       - (malformed)'
  printf '%s' "$output" | grep -q '\[confirm\].*never guess'
  [ "$(cat "$p/.nightshift/state-version")" = "??" ]
}

@test "hooks start status archive and recovery never call the migrator" {
  root="$BATS_TEST_DIRNAME/../plugins/nightshift"
  # Only migrate-state moves anything; Doctor and Setup read the plan to describe it.
  if grep -RInE 'ns_migrate_(plan|apply)|Get-NSMigrationPlan|Invoke-NSMigrationApply' \
    "$root/hooks" \
    "$root/runtime/claude" \
    "$root/runtime/codex" \
    "$root/runtime/cursor" \
    "$root/runtime/start-preflight.sh" \
    "$root/runtime/windows/start-preflight.ps1" \
    "$root/runtime/status.sh" \
    "$root/runtime/archive-receipts.sh" \
    "$root/runtime/schedule.sh" \
    "$root/runtime/link-workspace.sh"; then
    return 1
  fi
  [ "$(grep -RlE 'ns_migrate_apply|Invoke-NSMigrationApply' "$root/runtime" | sort | tr '\n' ' ')" = \
    "$root/runtime/migrate-state.sh $root/runtime/windows/migrate-state.ps1 " ]
  grep -qE 'ns"? migrate-state' "$SETUP"
  grep -qF 'state-version' "$SETUP"
  # The verdict carries its own rule: Start reports the marker and never writes one, and migration
  # belongs to Setup or Doctor.
  EXPLAIN="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  grep -qF 'Start never writes the state marker' "$EXPLAIN"
  grep -qF 'Migration is a Setup or Doctor repair' "$EXPLAIN"
  grep -qF 'state-version' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/start-preflight.sh"
  # Status modifies nothing at all, which covers migration and everything else.
  grep -qF 'Modify no file, begin no work' "$STATUS"
  grep -qF 'never migrate' "$ARCHIVE"
  grep -qE 'ns"? migrate-state' "$DOCTOR_SKILL"
  grep -qF 'separate owner actions, never Doctor' "$DOCTOR_SKILL"
}

LOGIC="$BATS_TEST_DIRNAME/windows/migrate-state-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"

@test "Windows CI runs the portable migrate-state suite" {
  [ -f "$LOGIC" ]
  grep -qF 'migrate-state-logic.ps1' "$RUN"
  grep -qF 'refuse    the shift is armed (.shift-armed)' "$LOGIC"
  grep -qF 'marker    state-version 1 -> 2' "$LOGIC"
  grep -qF 'function Get-NSMigrationPlan' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"
}

@test "Windows migrate-state logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}

@test "schedule generate and preflight fail closed on a future marker" {
  p="$(new_project)"
  printf '3\n' >"$p/.nightshift/state-version"
  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/schedule.sh" --project "$p" --at 04:00
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -q 'newer than this plugin supports'
  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/schedule.sh" --project "$p" --preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -q 'newer than this plugin supports'
}
