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
  jq -nc '{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:""}' |
    env CODEX_PROJECT_DIR="$1" bash "$CODEX_HOOKS/clock-out-gate.sh"
}

codex_ask() {
  jq -nc '{tool_name:"request_user_input",tool_input:{}}' |
    env CODEX_PROJECT_DIR="$1" bash "$CODEX_HOOKS/hardhat.sh"
}

@test "helpers classify missing, current, legacy-zero, malformed, and future markers" {
  p="$(new_project)"
  run bash -c '. "$1"; ns_state_kind "$2"; echo; ns_state_version "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | awk 'NR==1{exit $0=="legacy"?0:1}'
  printf '%s\n' "$output" | awk 'NR==2{exit $0=="0"?0:1}'

  printf '1\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_state_kind "$2"; echo; ns_state_version "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | awk 'NR==1{exit $0=="current"?0:1}'
  printf '%s\n' "$output" | awk 'NR==2{exit $0=="1"?0:1}'

  printf '0\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_state_kind "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ "$output" = "legacy" ]

  printf 'not-a-version\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_state_kind "$2"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  [ "$output" = "malformed" ]

  printf '2\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_state_kind "$2"; echo; ns_state_version "$2"' _ "$LIB" "$p"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | awk 'NR==1{exit $0=="future"?0:1}'
  printf '%s\n' "$output" | awk 'NR==2{exit $0=="2"?0:1}'
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

@test "new setup writes version 1 and migration is idempotent" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  bash -c '. "$1"; ns_write_state_version "$2" 1' _ "$LIB" "$p"
  [ "$(cat "$p/.nightshift/state-version")" = "1" ]
  run bash -c '. "$1"; ns_migrate_state "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$p/.nightshift/state-version")" = "1" ]
}

@test "legacy migration writes only the marker and preserves owner files" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  printf 'owner-secret: keep\n' >"$p/.nightshift/notes-from-owner.md"
  printf '{"custom":true}\n' >"$p/.nightshift/rules.json"
  before="$(fingerprint "$p")"
  run bash -c '. "$1"; ns_migrate_state "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$p/.nightshift/state-version")" = "1" ]
  grep -q 'owner-secret: keep' "$p/.nightshift/notes-from-owner.md"
  grep -q '"custom":true' "$p/.nightshift/rules.json"
  after="$(fingerprint "$p")"
  [ "$before" != "$after" ]
  # Only the new marker should appear.
  printf '%s\n' "$after" | grep -q './.nightshift/state-version'
  before_wo="$(printf '%s\n' "$before" | grep -v './.nightshift/state-version')"
  after_wo="$(printf '%s\n' "$after" | grep -v './.nightshift/state-version')"
  [ "$before_wo" = "$after_wo" ]
}

@test "migration refuses an armed workspace and leaves the tree unchanged" {
  p="$(new_project)"
  : >"$p/.nightshift/.shift-armed"
  before="$(fingerprint "$p")"
  run bash -c '. "$1"; ns_migrate_state "$2"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  [ ! -e "$p/.nightshift/state-version" ]
  after="$(fingerprint "$p")"
  [ "$before" = "$after" ]
}

@test "future and malformed markers are never rewritten or downgraded" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '9\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_migrate_state "$2"' _ "$LIB" "$p"
  [ "$status" -eq 2 ]
  [ "$(cat "$p/.nightshift/state-version")" = "9" ]

  printf 'nope\n' >"$p/.nightshift/state-version"
  run bash -c '. "$1"; ns_migrate_state "$2"' _ "$LIB" "$p"
  [ "$status" -eq 2 ]
  [ "$(cat "$p/.nightshift/state-version")" = "nope" ]
}

@test "migrate-state.sh writes version 1 when unarmed and refuses when armed" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  run bash "$MIGRATE" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$p/.nightshift/state-version")" = "1" ]

  q="$(new_project q)"
  : >"$q/.nightshift/.shift-armed"
  run bash "$MIGRATE" --project "$q"
  [ "$status" -eq 1 ]
  [ ! -e "$q/.nightshift/state-version" ]
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
}

@test "both host gates and hardhats fail closed on future and malformed markers" {
  p="$(new_project)"
  punch_open "$p"
  printf '2\n' >"$p/.nightshift/state-version"

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
  printf '%s' "$output" | grep -q '\[confirm\].*migrate-state.sh'
  after="$(fingerprint "$p")"
  [ "$before" = "$after" ]
  [ ! -e "$p/.nightshift/state-version" ]

  : >"$p/.nightshift/.shift-armed"
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q '\[blocked\].*unarmed'
  [ ! -e "$p/.nightshift/state-version" ]

  rm -f "$p/.nightshift/.shift-armed"
  printf '1\n' >"$p/.nightshift/state-version"
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'State:       1 (current)'
  printf '%s' "$output" | grep -q 'state version 1 (current)'
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
  if grep -RIn 'ns_migrate_state' \
    "$root/hooks" \
    "$root/runtime/claude" \
    "$root/runtime/codex" \
    "$root/runtime/doctor.sh" \
    "$root/runtime/schedule.sh" \
    "$root/runtime/link-workspace.sh"; then
    return 1
  fi
  grep -qF 'runtime/migrate-state.sh' "$SETUP"
  grep -qF 'state-version' "$SETUP"
  grep -qF 'state-version' "$START"
  grep -qiF 'start never writes' "$START"
  # Status modifies nothing at all, which covers migration and everything else.
  grep -qF 'Modify no file, begin no work' "$STATUS"
  grep -qF 'never migrate' "$ARCHIVE"
  grep -qF 'migrate-state.sh' "$DOCTOR_SKILL"
  grep -qF 'separate owner actions, never Doctor' "$DOCTOR_SKILL"
}

LOGIC="$BATS_TEST_DIRNAME/windows/migrate-state-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"

@test "Windows CI runs the portable migrate-state armed-refuse suite" {
  [ -f "$LOGIC" ]
  grep -qF 'migrate-state-logic.ps1' "$RUN"
  grep -qF 'refuse to migrate while the shift is armed' "$LOGIC"
  grep -qF 'state-version is now 1' "$LOGIC"
  grep -qF 'Invoke-NSMigrateState' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"
}

@test "Windows migrate-state writes version 1 when unarmed and refuses when armed" {
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
