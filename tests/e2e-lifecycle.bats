load helpers

ROOT="$BATS_TEST_DIRNAME/.."
RUNTIME="$ROOT/plugins/nightshift/runtime"
REF="$ROOT/plugins/nightshift/skills/nightshift/references"
CODEX_HOOKS="$HOOKS/codex"
CLAUDE_WM="$RUNTIME/claude/watchman.sh"
CODEX_WM="$RUNTIME/codex/watchman.sh"
DOCTOR="$RUNTIME/doctor.sh"
SCHED="$RUNTIME/schedule.sh"
LINK="$RUNTIME/link-workspace.sh"
SESSION_END="$HOOKS/session-end.sh"

# The exact POSIX toolset the zero-gate fast-shift test below runs on: jq present, no python3, so
# a clean run through apply-profile, shift-policy, and the clock-out gate proves the basic path
# never needs an interpreter beyond bash (per the Owner decisions' no-undocumented-runtime rule).
E2E_NO_PYTHON_TOOLSET="bash sh jq git sed grep find sort ls awk cat tr head tail wc cut mkdir cp \
mv rm ln env cmp date uname test dirname basename readlink stat printf true false xargs mktemp ps"

codex_gate() {
  local p="$1"
  jq -nc --arg p "$p" '{hook_event_name:"Stop",session_id:"fixture-session",transcript_path:"",cwd:$p}' |
    env CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/clock-out-gate.sh"
}
codex_ask() {
  local p="$1"
  jq -nc '{tool_name:"request_user_input",tool_input:{}}' |
    env CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh"
}

scaffold() { # <workspace> — the files setup copies, via the shipped templates
  local w="$1"
  mkdir -p "$w/.nightshift"
  for f in punch-list drafting-table parking-lot snag-log product-research opportunity-map work-orders; do
    cp "$REF/templates/$f.md" "$w/.nightshift/$f.md"
  done
  cp "$REF/nightshift-rules-template.json" "$w/.nightshift/rules.json"
  printf '# Shift Log\n' >"$w/.nightshift/shift-log.md"
  printf '1\n' >"$w/.nightshift/state-version"
}

@test "setup templates, arming, and both host gates share the open-item block" {
  p="$(new_project)"
  scaffold "$p"
  printf '## Items\n- [ ] **1. real work.**\n' >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  q="$(new_project q)"
  scaffold "$q"
  printf '## Items\n- [ ] **1. real work.**\n' >"$q/.nightshift/punch-list.md"
  : >"$q/.nightshift/.shift-armed"

  run gate "$p"
  is_block "$output"
  run codex_gate "$q"
  is_block "$output"

  run hardhat_ask "$p"
  is_deny "$output"
  run codex_ask "$q"
  is_deny "$output"
}

@test "STOP releases both hosts and leaves unfinished boxes open" {
  p="$(new_project)"
  scaffold "$p"
  printf '## Items\n- [ ] **1. real work.**\n' >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  : >"$p/.nightshift/STOP"

  run gate "$p"
  is_release
  run codex_gate "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.continue == true' >/dev/null
  grep -qE '^- \[ \]' "$p/.nightshift/punch-list.md"
}

@test "parent workspace, spaced paths, and an explicit link share one punch list" {
  ws="$BATS_TEST_TMPDIR/parent with spaces"
  scaffold "$ws"
  add_repo "$ws" repo
  printf '%s\n' "$(cd -P "$ws/repo" && pwd)" >"$ws/.nightshift/work-target"
  printf '## Items\n- [ ] **1. real work.**\n' >"$ws/.nightshift/punch-list.md"
  : >"$ws/.nightshift/.shift-armed"

  host="$BATS_TEST_TMPDIR/host with spaces"
  mkdir -p "$host"
  run bash "$LINK" --host-root "$host" --workspace "$ws"
  [ "$status" -eq 0 ]

  run bash "$DOCTOR" --project "$host"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Link:        valid'
  printf '%s' "$output" | grep -q 'open=1'

  run gate "$host"
  is_block "$output"

  host2="$BATS_TEST_TMPDIR/host2 with spaces"
  mkdir -p "$host2"
  bash "$LINK" --host-root "$host2" --workspace "$ws" >/dev/null
  # A second task root, same workspace, no session recorded yet — Codex must still hold the list.
  rm -f "$ws/.nightshift/.shift-session" "$ws/.nightshift/.shift-lease"
  : >"$ws/.nightshift/.shift-armed"
  run codex_gate "$host2"
  is_block "$output"
}

@test "Claude session-end is the clean-end marker; Codex live-but-errored is stood by" {
  p="$(new_project)"
  scaffold "$p"
  printf '## Items\n- [ ] **1. real work.**\n' >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  printf '{"reason":"exit","session_id":"fixture-session"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ -f "$p/.nightshift/.session-end" ]

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cat >"$BIN/tick.sh" <<'STUB'
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
STUB
  chmod +x "$BIN/tick.sh"
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid\n\n%s\n%s\ncodex\n' "$$" "$start" >"$p/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 "$CODEX_WM" --project "$p" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 1
  [ "$status" -eq 0 ]
  [ ! -f "$p/.nightshift/agent-calls" ]
}

@test "interrupted recovery: STOP stands both watchmen down with no leftover pid" {
  p="$(new_project)"
  scaffold "$p"
  printf '## Items\n- [ ] **1. real work.**\n' >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  : >"$p/.nightshift/STOP"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\necho called >>.nightshift/agent-calls\n' >"$BIN/tick.sh"
  chmod +x "$BIN/tick.sh"

  run env NIGHTSHIFT_WATCH_SLEEP=0 "$CLAUDE_WM" --project "$p" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 1
  [ "$status" -eq 0 ]
  [ ! -f "$p/.nightshift/.watchman" ]
  [ ! -f "$p/.nightshift/agent-calls" ]

  printf 'sid\n\n99999\nnever\ncodex\n' >"$p/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 "$CODEX_WM" --project "$p" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 1
  [ "$status" -eq 0 ]
  [ ! -f "$p/.nightshift/.watchman" ]
  [ ! -f "$p/.nightshift/agent-calls" ]
}

@test "completion clocks out, archive layout keeps the contract, scheduler is untouched" {
  p="$(new_project)"
  scaffold "$p"
  printf '## Items\n- [x] **1. shipped.**\n' >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  run gate "$p"
  is_release
  [ -f "$p/.nightshift/.ended" ]

  day="2026-08-14"
  mkdir -p "$p/.nightshift/archive/$day"
  printf '## Shipped %s\n- [x] **1. shipped.**\n' "$day" >"$p/.nightshift/archive/$day/shipped.md"
  grep -q 'The enforced to-do' "$p/.nightshift/punch-list.md" || \
    grep -q '## Items' "$p/.nightshift/punch-list.md"

  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home/Library/LaunchAgents"
  run env HOME="$home" "$SCHED" --project "$p" --preflight
  [ "$status" -eq 1 ] # no open items
  [ -z "$(find "$home/Library/LaunchAgents" -type f)" ]
}

@test "Doctor and preflight stay read-only across the lifecycle fixtures" {
  p="$(new_project)"
  scaffold "$p"
  printf '## Items\n- [ ] **1. real work.**\n' >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  before="$(find "$p" -type f -exec cksum {} \; | sort)"
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  after="$(find "$p" -type f -exec cksum {} \; | sort)"
  [ "$before" = "$after" ]
}

# The zero-gate fast shift: Setup's own scaffold (rules template, work mode, work target, a punch
# list with one item and an untouched Gates placeholder), the fast profile applied the way Hunt or
# Quality composition would, a start-defaults policy written the way Start writes one when none is
# queued, one tick, and the clock-out gate — the whole basic path, on a PATH that has jq and no
# python3 at all, proving the Owner decisions' "no undocumented runtime beyond main" holds for the
# layered shift policy exactly as it already does for the rest of main.
@test "a zero-gate fast shift runs Setup through clock-out on a PATH with jq and no python3" {
  bin="$(build_toolset_bin e2e-fast-bin $E2E_NO_PYTHON_TOOLSET)"

  p="$(new_project e2e-fast)"
  rm -f "$p/.nightshift/.shift-armed"
  # Setup's own writes: the mode and the resolved work target (this project is already the repo).
  printf 'repository\n' >"$p/.nightshift/work-mode"
  printf '%s\n' "$p" >"$p/.nightshift/work-target"
  printf '## Gates\n\n_None configured._\n\n## Items\n\n- [ ] **1. Ship the fast-path feature.**\n' \
    >"$p/.nightshift/punch-list.md"

  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash "$RUNTIME/apply-profile.sh" --project "$p" --profile fast --mode fill --apply
  [ "$status" -eq 0 ] || { echo "apply-profile failed on the no-python3 PATH: $output"; return 1; }
  printf '%s\n' "$output" | grep -qF 'Wrote'
  # The remembered choices land in the shift block of the owner file, where composition reads them.
  jq -e '
    .shift.verificationProfile == "fast" and .shift.toolingPolicy == "existing-tools"
    and .shift.execution == "run-direct"
  ' "$p/.nightshift/rules.json" >/dev/null
  grep -qF '_None configured._' "$p/.nightshift/punch-list.md"

  # Start writes safe defaults when no policy is queued: existing-tools, no allowances, and the
  # verification level the fast profile maps to (none).
  sid="e2e0000000000001"
  candidate="{\"schemaVersion\":1,\"shiftId\":\"$sid\",\"createdAt\":\"2026-09-02T02:00:00Z\","
  candidate="$candidate\"source\":\"start-defaults\",\"deadlineEpoch\":null,\"verificationLevel\":\"none\","
  candidate="$candidate\"toolingPolicy\":\"existing-tools\",\"allowances\":[]}"
  printf '%s\n' "$candidate" >"$p/candidate.json"
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash "$RUNTIME/shift-policy.sh" --project "$p" set --from-json "$p/candidate.json"
  [ "$status" -eq 0 ] || { echo "shift-policy set failed on the no-python3 PATH: $output"; return 1; }

  : >"$p/.nightshift/.shift-armed"

  # One tick.
  sed 's/^- \[ \] \*\*1\./- [x] **1./' "$p/.nightshift/punch-list.md" >"$p/.nightshift/punch-list.md.tmp"
  mv "$p/.nightshift/punch-list.md.tmp" "$p/.nightshift/punch-list.md"
  grep -qxF -- '- [x] **1. Ship the fast-path feature.**' "$p/.nightshift/punch-list.md"

  payload='{"hook_event_name":"Stop","session_id":"e2e-fast-session","transcript_path":""}'
  run bash -c 'printf "%s" "$1" | env -i PATH="$2" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" CLAUDE_PROJECT_DIR="$3" bash "$4"' \
    _ "$payload" "$bin" "$p" "$HOOKS/clock-out-gate.sh"
  is_release
  [ ! -f "$p/.nightshift/.shift-armed" ]
  [ -f "$p/.nightshift/.ended" ]

  day="$(date '+%Y-%m-%d')"
  archived="$p/.nightshift/archive/$day/shift-policy-$sid.json"
  if [ -f "$archived" ]; then
    [ ! -e "$p/.nightshift/shift-policy.json" ]
    jq -e --arg sid "$sid" '.shiftId == $sid' "$archived" >/dev/null
  else
    echo "gate did not archive shift-policy.json (lane F)" >&2
    return 1
  fi
}
