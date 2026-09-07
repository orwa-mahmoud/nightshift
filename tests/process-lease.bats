load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
CODEX_HOOKS="$HOOKS/codex"
START_SKILL="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/start/SKILL.md"

claude_bind() {
  local p="$1" sid="$2"
  jq -nc --arg sid "$sid" \
    '{tool_name:"Bash",session_id:$sid,transcript_path:"",tool_input:{command:": nightshift-binding-probe"}}' |
    CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
}

claude_read() {
  local p="$1" sid="$2"
  shift 2
  jq -nc --arg sid "$sid" \
    '{tool_name:"Read",session_id:$sid,transcript_path:"",tool_input:{file_path:"README.md"}}' |
    env "$@" CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
}

claude_bash() {
  local p="$1" sid="$2" command="$3"
  shift 3
  jq -nc --arg sid "$sid" --arg command "$command" \
    '{tool_name:"Bash",session_id:$sid,tool_input:{command:$command}}' |
    env "$@" CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
}

codex_bind() {
  local p="$1" sid="$2"
  jq -nc --arg sid "$sid" \
    '{tool_name:"Bash",session_id:$sid,transcript_path:"",tool_input:{command:": nightshift-binding-probe"}}' |
    CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh"
}

codex_read() {
  local p="$1" sid="$2"
  shift 2
  jq -nc --arg sid "$sid" \
    '{tool_name:"mcp__filesystem__read_file",session_id:$sid,transcript_path:"",tool_input:{path:"README.md"}}' |
    env "$@" CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh"
}

take_lease() {
  local p="$1" sid="$2" host="$3"
  bash -c '. "$1"; ns_lease_takeover "$2/.nightshift" "$3" "$4"' \
    nightshift "$LIB" "$p" "$sid" "$host"
}

lease_mode() {
  case "$(uname -s)" in
    Darwin) stat -f %Lp "$1" ;;
    *) stat -c %a "$1" ;;
  esac
}

@test "the binding probe creates a six-line interactive process lease" {
  p="$(new_project)"
  punch_open "$p"

  run claude_bind "$p" shift-session
  is_allow
  lease="$p/.nightshift/.shift-lease"
  [ "$(wc -l <"$lease")" -eq 6 ]
  [ "$(sed -n 1p "$lease")" = "shift-session" ]
  [ "$(sed -n 2p "$lease")" = "claude" ]
  [ "$(sed -n 3p "$lease")" = "1" ]
  [ -z "$(sed -n 4p "$lease")" ]
  [ "$(lease_mode "$lease")" = "600" ]
  [ "$(lease_mode "$p/.nightshift/.shift-session")" = "600" ]
}

@test "Start's stale reset clears lease artifacts through the shared library" {
  p="$(new_project)"
  mkdir -p "$p/.nightshift/.lease-lock.d"
  printf 'not-a-pid' >"$p/.nightshift/.lease-lock.d/pid"
  printf 'malformed\n' >"$p/.nightshift/.shift-lease"
  : >"$p/.nightshift/.shift-lease.tmp.leftover"

  # Both rules travel with the verdict that raises them: the blocked session does not reset the
  # lease itself, and the clock-out case does not get a reset at all.
  EXPLAIN="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  grep -qF 'do not run the stale-lease reset' "$EXPLAIN"
  grep -qF 'terminal clock-out failed without releasing the shift' "$EXPLAIN"

  run bash -c '. "$1"; ns_lease_reset_stale "$2/.nightshift"' nightshift "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/.shift-lease" ]
  [ ! -e "$p/.nightshift/.shift-lease.tmp.leftover" ]
  [ ! -e "$p/.nightshift/.lease-lock.d" ]
  grep -qF 'ns_lease_reset_stale' "$START_SKILL"
}

@test "a losing second Start is rejected while its conversation remains an ordinary helper" {
  grep -qF ': nightshift-binding-probe' "$START_SKILL"
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" first-session

  run claude_bind "$p" second-session
  is_deny "$output"
  printf '%s' "$output" | grep -q "another session already owns this shift"

  run claude_read "$p" second-session
  is_allow

  q="$(new_project codex)"
  punch_open "$q"
  codex_bind "$q" first-session

  run codex_bind "$q" second-session
  is_deny "$output"
  printf '%s' "$output" | grep -q "another session already owns this shift"

  run codex_read "$q" second-session
  is_allow
}

@test "racing Start probes publish one complete session and reject the loser" {
  p="$(new_project)"
  punch_open "$p"
  first="$BATS_TEST_TMPDIR/first-probe"
  second="$BATS_TEST_TMPDIR/second-probe"

  (claude_bind "$p" first-session >"$first") &
  one=$!
  (claude_bind "$p" second-session >"$second") &
  two=$!
  wait "$one"
  wait "$two"

  owner="$(sed -n 1p "$p/.nightshift/.shift-session")"
  case "$owner" in
    first-session) winner="$first"; loser="$second" ;;
    second-session) winner="$second"; loser="$first" ;;
    *) false ;;
  esac
  [ ! -s "$winner" ]
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$loser" >/dev/null
  grep -q "another session already owns this shift" "$loser"
  [ "$(wc -l <"$p/.nightshift/.shift-session" | tr -d ' ')" -eq 5 ]
  [ "$(wc -l <"$p/.nightshift/.shift-lease" | tr -d ' ')" -eq 6 ]

  q="$(new_project codex-race)"
  punch_open "$q"
  cfirst="$BATS_TEST_TMPDIR/codex-first-probe"
  csecond="$BATS_TEST_TMPDIR/codex-second-probe"
  (codex_bind "$q" first-session >"$cfirst") &
  one=$!
  (codex_bind "$q" second-session >"$csecond") &
  two=$!
  wait "$one"
  wait "$two"
  owner="$(sed -n 1p "$q/.nightshift/.shift-session")"
  case "$owner" in
    first-session) winner="$cfirst"; loser="$csecond" ;;
    second-session) winner="$csecond"; loser="$cfirst" ;;
    *) false ;;
  esac
  [ ! -s "$winner" ]
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$loser" >/dev/null
  grep -q "another session already owns this shift" "$loser"
  [ "$(wc -l <"$q/.nightshift/.shift-session" | tr -d ' ')" -eq 5 ]
  [ "$(wc -l <"$q/.nightshift/.shift-lease" | tr -d ' ')" -eq 6 ]
}

@test "a Claude watchman generation fences the stale process and admits only its capability" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" shift-session
  claim="$(take_lease "$p" shift-session claude)"
  generation="${claim%% *}"
  nonce="${claim#* }"

  run claude_read "$p" shift-session
  is_deny "$output"
  printf '%s' "$output" | grep -q "continued in a recovered process"

  run claude_read "$p" shift-session \
    NIGHTSHIFT_REVIVAL=1 NIGHTSHIFT_LEASE_GENERATION="$generation" NIGHTSHIFT_LEASE_NONCE="$nonce"
  is_allow
}

@test "a live recovery worker keeps the recorded conversation fenced" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" shift-session
  claim="$(take_lease "$p" shift-session claude)"
  generation="${claim%% *}"
  nonce="${claim#* }"
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  bash -c '. "$1"; ns_lease_attach_process "$2/.nightshift" claude "$3" "$4" "$5" "$6"' \
    nightshift "$LIB" "$p" "$nonce" "$generation" "$$" "$start"
  run claude_read "$p" shift-session
  is_deny "$output"
  printf '%s' "$output" | grep -q "being recovered in another process"
  printf '%s' "$output" | grep -q "stays blocked"
  run claude_read "$p" helper-session
  is_allow
}

@test "a dead clock-out child restores an interactive lease the recorded session can use" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" shift-session
  claim="$(take_lease "$p" shift-session claude)"
  generation="${claim%% *}"
  nonce="${claim#* }"
  (exit 0) &
  dead=$!
  wait "$dead"
  bash -c '. "$1"; ns_lease_attach_process "$2/.nightshift" claude "$3" "$4" "$5" "$6"' \
    nightshift "$LIB" "$p" "$nonce" "$generation" "$dead" "never"
  bash -c '. "$1"; ns_lease_restore_interactive "$2/.nightshift"' \
    nightshift "$LIB" "$p"
  [ -z "$(sed -n 4p "$p/.nightshift/.shift-lease")" ]
  [ "$(sed -n 1p "$p/.nightshift/.shift-lease")" = "shift-session" ]
  run claude_read "$p" shift-session
  is_allow
  run claude_read "$p" helper-session
  is_allow
}

@test "an unrelated Claude conversation remains outside the shift lease" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" shift-session
  take_lease "$p" shift-session claude >/dev/null

  run claude_read "$p" helper-session
  is_allow
}

@test "closing the stale Claude panel cannot stand the recovered watchman down" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" shift-session
  take_lease "$p" shift-session claude >/dev/null

  printf '{"reason":"exit","session_id":"shift-session"}' |
    CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/session-end.sh"
  [ ! -e "$p/.nightshift/.session-end" ]
}

@test "the current interactive lease owner can still record a clean Claude exit" {
  p="$(new_project)"
  punch_open "$p"
  stub="$BATS_TEST_TMPDIR/session-end-bin"
  mkdir -p "$stub"
  cat >"$stub/ps" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"-o comm="*) echo claude ;;
  *"-o lstart="*) echo "Mon Jan  1 00:00:00 2026" ;;
  *"-o ppid="*) echo 1 ;;
esac
STUB
  chmod +x "$stub/ps"
  payload="$BATS_TEST_TMPDIR/session-end.json"
  printf '{"session_id":"shift-session","reason":"exit"}\n' >"$payload"
  runner="$BATS_TEST_TMPDIR/session-end-runner"
  cat >"$runner" <<'RUNNER'
#!/usr/bin/env bash
set -u
p="$1"
hook="$2"
payload="$3"
stub="$4"
printf 'shift-session\n\n%s\nMon Jan  1 00:00:00 2026\nclaude\n' "$$" >"$p/.nightshift/.shift-session"
printf 'shift-session\nclaude\n1\n\n%s\nMon Jan  1 00:00:00 2026\n' "$$" >"$p/.nightshift/.shift-lease"
CLAUDE_PROJECT_DIR="$p" PATH="$stub:$PATH" exec bash "$hook" <"$payload"
RUNNER
  chmod +x "$runner"

  run bash "$runner" "$p" "$HOOKS/session-end.sh" "$payload" "$stub"
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/.session-end" ]
}

@test "a newer watchman generation fences an older recovered worker" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" shift-session
  first="$(take_lease "$p" shift-session claude)"
  second="$(take_lease "$p" shift-session claude)"
  [ "${first%% *}" -lt "${second%% *}" ]

  run claude_read "$p" shift-session \
    NIGHTSHIFT_REVIVAL=1 NIGHTSHIFT_LEASE_GENERATION="${first%% *}" NIGHTSHIFT_LEASE_NONCE="${first#* }"
  is_deny "$output"
  printf '%s' "$output" | grep -q "no longer owns the shift"
}

@test "a recovery child cannot use tools after clock-out released its lease" {
  p="$(new_project claude-post-clockout)"
  punch_open "$p"
  claude_bind "$p" test-shift-session
  claim="$(take_lease "$p" test-shift-session claude)"
  punch_done "$p"
  run gate "$p" \
    NIGHTSHIFT_REVIVAL=1 NIGHTSHIFT_LEASE_GENERATION="${claim%% *}" NIGHTSHIFT_LEASE_NONCE="${claim#* }"
  is_release

  run claude_read "$p" test-shift-session \
    NIGHTSHIFT_REVIVAL=1 NIGHTSHIFT_LEASE_GENERATION="${claim%% *}" NIGHTSHIFT_LEASE_NONCE="${claim#* }"
  is_deny "$output"
  printf '%s' "$output" | grep -q "no longer owns an active shift"

  c="$(new_project codex-post-clockout)"
  punch_open "$c"
  codex_bind "$c" shift-session
  claim="$(take_lease "$c" shift-session codex)"
  punch_done "$c"
  run bash -c \
    'jq -nc '\''{hook_event_name:"Stop",session_id:"shift-session",transcript_path:""}'\'' |
      CODEX_PROJECT_DIR="$1" NIGHTSHIFT_REVIVAL=1 \
      NIGHTSHIFT_LEASE_GENERATION="$3" NIGHTSHIFT_LEASE_NONCE="$4" \
      bash "$2/codex/clock-out-gate.sh"' \
    nightshift "$c" "$HOOKS" "${claim%% *}" "${claim#* }"
  [ "$status" -eq 0 ]

  run codex_read "$c" shift-session \
    NIGHTSHIFT_REVIVAL=1 NIGHTSHIFT_LEASE_GENERATION="${claim%% *}" NIGHTSHIFT_LEASE_NONCE="${claim#* }"
  is_deny "$output"
  printf '%s' "$output" | grep -q "no longer owns an active shift"
}

@test "a reopened interactive Claude process reclaims a dead original lease and refreshes liveness" {
  p="$(new_project)"
  punch_open "$p"
  (exit 0) &
  dead=$!
  wait "$dead"
  printf 'shift-session\n\n%s\n\nclaude\n' "$dead" >"$p/.nightshift/.shift-session"
  printf 'shift-session\nclaude\n1\n\n%s\n\n' "$dead" >"$p/.nightshift/.shift-lease"

  stub="$BATS_TEST_TMPDIR/reclaim-bin"
  mkdir -p "$stub"
  cat >"$stub/ps" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"-o comm="*) echo claude ;;
  *"-o lstart="*) echo "Mon Jan  1 00:00:00 2026" ;;
  *"-o ppid="*) echo 1 ;;
esac
STUB
  chmod +x "$stub/ps"

  run claude_read "$p" shift-session PATH="$stub:$PATH"
  is_allow
  [ "$(sed -n 3p "$p/.nightshift/.shift-lease")" = "2" ]
  [ "$(sed -n 5p "$p/.nightshift/.shift-lease")" = "$(sed -n 3p "$p/.nightshift/.shift-session")" ]
  sed -n 5p "$p/.nightshift/.shift-lease" | grep -qE '^[0-9]+$'
}

@test "racing lease transfers publish one whole winning generation" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" shift-session
  take_lease "$p" shift-session claude >"$BATS_TEST_TMPDIR/claim-a" &
  one=$!
  take_lease "$p" shift-session claude >"$BATS_TEST_TMPDIR/claim-b" &
  two=$!
  wait "$one" "$two"
  a="$(cat "$BATS_TEST_TMPDIR/claim-a")"
  b="$(cat "$BATS_TEST_TMPDIR/claim-b")"
  [ "${a%% *}" -ne "${b%% *}" ]

  final_generation="$(sed -n 3p "$p/.nightshift/.shift-lease")"
  final_nonce="$(sed -n 4p "$p/.nightshift/.shift-lease")"
  case "$final_generation $final_nonce" in
    "$a")
      winner="$a"
      loser="$b"
      ;;
    "$b")
      winner="$b"
      loser="$a"
      ;;
    *)
      false
      ;;
  esac

  run claude_read "$p" shift-session \
    NIGHTSHIFT_REVIVAL=1 NIGHTSHIFT_LEASE_GENERATION="${loser%% *}" NIGHTSHIFT_LEASE_NONCE="${loser#* }"
  is_deny "$output"
  run claude_read "$p" shift-session \
    NIGHTSHIFT_REVIVAL=1 NIGHTSHIFT_LEASE_GENERATION="${winner%% *}" NIGHTSHIFT_LEASE_NONCE="${winner#* }"
  is_allow
}

@test "a fresh fallback rebinds continuity but keeps the original stale thread fenced" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" original-session
  claim="$(take_lease "$p" original-session claude)"
  generation="${claim%% *}"
  nonce="${claim#* }"

  run claude_read "$p" recovered-session \
    NIGHTSHIFT_REVIVAL=1 NIGHTSHIFT_LEASE_GENERATION="$generation" NIGHTSHIFT_LEASE_NONCE="$nonce"
  is_allow
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "recovered-session" ]
  [ "$(lease_mode "$p/.nightshift/.shift-session")" = "600" ]
  [ "$(sed -n 1p "$p/.nightshift/.shift-lease")" = "original-session" ]

  run claude_read "$p" original-session
  is_deny "$output"
  run claude_read "$p" helper-session
  is_allow
}

@test "an unbound fresh recovery admits only the watchman child until it records a session" {
  p="$(new_project)"
  punch_open "$p"
  claim="$(take_lease "$p" "" claude)"
  generation="${claim%% *}"
  nonce="${claim#* }"

  run claude_read "$p" helper-session
  is_deny "$output"
  [ ! -e "$p/.nightshift/.shift-session" ]

  run claude_read "$p" recovered-session \
    NIGHTSHIFT_REVIVAL=1 NIGHTSHIFT_LEASE_GENERATION="$generation" NIGHTSHIFT_LEASE_NONCE="$nonce"
  is_allow
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "recovered-session" ]

  run claude_read "$p" helper-session
  is_allow
}

@test "Codex also fences an unbound fresh-recovery window" {
  p="$(new_project)"
  punch_open "$p"
  claim="$(take_lease "$p" "" codex)"
  generation="${claim%% *}"
  nonce="${claim#* }"

  run codex_read "$p" helper-session
  is_deny "$output"
  [ ! -e "$p/.nightshift/.shift-session" ]

  run codex_read "$p" recovered-session \
    NIGHTSHIFT_REVIVAL=1 NIGHTSHIFT_LEASE_GENERATION="$generation" NIGHTSHIFT_LEASE_NONCE="$nonce"
  is_allow
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "recovered-session" ]
}

@test "Codex applies the same generation fence without inventing process ancestry" {
  p="$(new_project)"
  punch_open "$p"
  codex_bind "$p" shift-session
  claim="$(take_lease "$p" shift-session codex)"
  generation="${claim%% *}"
  nonce="${claim#* }"

  run codex_read "$p" shift-session
  is_deny "$output"
  run codex_read "$p" shift-session \
    NIGHTSHIFT_REVIVAL=1 NIGHTSHIFT_LEASE_GENERATION="$generation" NIGHTSHIFT_LEASE_NONCE="$nonce"
  is_allow
  [ -z "$(sed -n 5p "$p/.nightshift/.shift-lease")" ]

  run codex_read "$p" helper-session
  is_allow
}

@test "a malformed lease fails closed for the shift but not another conversation" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" shift-session
  printf 'broken\n' >"$p/.nightshift/.shift-lease"

  run claude_read "$p" shift-session
  is_deny "$output"
  run claude_read "$p" helper-session
  is_allow
}

@test "the active lease is runtime-owned across shift and helper conversations" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" shift-session
  printf '0123456789abcdef0123456789abcdef\n' >"$p/.nightshift/.mutex-scope"

  run claude_bash "$p" shift-session "rm -f .nightshift/.shift-lease"
  is_deny "$output"
  printf '%s' "$output" | grep -q "process lease is runtime-owned"
  [ -f "$p/.nightshift/.shift-lease" ]

  run claude_bash "$p" helper-session "rm -f .nightshift/.shift-lease"
  is_deny "$output"
  [ -f "$p/.nightshift/.shift-lease" ]

  run claude_bash "$p" helper-session "rm -f .nightshift/.mutex-scope"
  is_deny "$output"
  [ -f "$p/.nightshift/.mutex-scope" ]

  for command in \
    "rm -f .nightshift/.shift-*" \
    "rm -f .nightshift/.mutex-*" \
    "rm -f .nightshift/.shift-{lease,armed}" \
    "cd .nightshift && rm -f .shift-*" \
    "find .nightshift -name '.shift-*' -delete" \
    "rm -rf .nightshift"; do
    run claude_bash "$p" helper-session "$command"
    is_deny "$output"
    [ -f "$p/.nightshift/.shift-lease" ]
  done

  run claude_bash "$p" helper-session "rm -f .nightshift/.shift-session.tmp.*"
  is_allow
  run claude_bash "$p" helper-session "rm -f tmp/.lease-* tmp/.shift-*"
  is_allow
  run claude_bash "$p" helper-session "git commit -m 'rm -rf .nightshift'"
  is_allow
  run claude_bash "$p" helper-session 'git commit -m "document .nightshift/.shift-lease"'
  is_allow
  run claude_bash "$p" helper-session 'stamp=$(date); git commit -m "document .nightshift/.shift-lease"'
  is_allow
  run claude_bash "$p" helper-session 'git commit -m "document \$(rm -f .nightshift/.shift-lease)"'
  is_allow
  run claude_bash "$p" helper-session "git commit -m '\$(rm -f .nightshift/.shift-lease)'"
  is_allow
  run claude_bash "$p" helper-session "git commit -m \"\$(rm -f .nightshift/.shift-lease)\""
  is_deny "$output"
  [ -f "$p/.nightshift/.shift-lease" ]
  run claude_bash "$p" helper-session 'git commit -m "`rm -f .nightshift/.shift-lease`"'
  is_deny "$output"
  [ -f "$p/.nightshift/.shift-lease" ]

  run bash -c \
    'jq -nc '\''{tool_name:"mcp__shell__run",session_id:"helper-session",tool_input:{command:"git commit -m \"document .nightshift/.shift-lease\""}}'\'' |
      CLAUDE_PROJECT_DIR="$1" bash "$2/hardhat.sh"' \
    nightshift "$p" "$HOOKS"
  is_allow

  payload="$(jq -nc --arg command $'git commit -m "line one\nline two: .nightshift/.shift-lease"' \
    '{tool_name:"mcp__shell__run",session_id:"helper-session",tool_input:{command:$command}}')"
  run bash -c 'printf "%s" "$1" | CLAUDE_PROJECT_DIR="$2" bash "$3/hardhat.sh"' \
    nightshift "$payload" "$p" "$HOOKS"
  is_allow

  payload="$(jq -nc --arg command $'git commit -m "$(printf x;\nrm -f .nightshift/.shift-lease)"' \
    '{tool_name:"mcp__shell__run",session_id:"helper-session",tool_input:{command:$command}}')"
  run bash -c 'printf "%s" "$1" | CLAUDE_PROJECT_DIR="$2" bash "$3/hardhat.sh"' \
    nightshift "$payload" "$p" "$HOOKS"
  is_deny "$output"
  [ -f "$p/.nightshift/.shift-lease" ]

  run bash -c \
    'jq -nc '\''{tool_name:"mcp__shell__run",session_id:"helper-session",tool_input:{command:"rm -f .nightshift/.shift-{lease,armed}"}}'\'' |
      CLAUDE_PROJECT_DIR="$1" bash "$2/hardhat.sh"' \
    nightshift "$p" "$HOOKS"
  is_deny "$output"
  [ -f "$p/.nightshift/.shift-lease" ]

  run bash -c \
    'jq -nc '\''{tool_name:"apply_patch",session_id:"shift-session",tool_input:{patch:"*** Update File: .nightshift/.shift-lease"}}'\'' |
      CODEX_PROJECT_DIR="$1" bash "$2/codex/hardhat.sh"' \
    nightshift "$p" "$HOOKS"
  is_deny "$output"
}

@test "opaque local-tool payloads fail closed if the exact JSON parser disappears" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" shift-session
  noparser="$BATS_TEST_TMPDIR/no-lease-parser"
  mkdir -p "$noparser"
  for tool in bash grep sed cat printf env sh ps dirname head tail tr awk date mkdir rm cut wc sleep kill git ln mv; do
    command -v "$tool" >/dev/null && ln -sf "$(command -v "$tool")" "$noparser/$tool"
  done
  payload="$(jq -nc \
    '{tool_name:"mcp__filesystem__write_file",session_id:"helper-session",tool_input:{path:".nightshift/.shift-lease",content:"broken"}}')"

  run bash -c 'printf "%s" "$1" | env PATH="$2" CLAUDE_PROJECT_DIR="$3" bash "$4/hardhat.sh"' \
    nightshift "$payload" "$noparser" "$p" "$HOOKS"
  is_deny "$output"
  printf '%s' "$output" | grep -q "process lease is runtime-owned"
  [ -f "$p/.nightshift/.shift-lease" ]
}

@test "the payload decoder distinguishes commands from static commit messages" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" shift-session
  nojq="$BATS_TEST_TMPDIR/mcp-lease-parser"
  mkdir -p "$nojq"
  for tool in bash grep sed cat printf env sh ps dirname head tail tr awk date mkdir rm cut wc sleep kill git ln mv jq; do
    command -v "$tool" >/dev/null && ln -sf "$(command -v "$tool")" "$nojq/$tool"
  done

  payload="$(jq -nc \
    '{tool_name:"mcp__shell__run",session_id:"helper-session",tool_input:{command:"rm -f .nightshift/.shift-{lease,armed}"}}')"
  run bash -c 'printf "%s" "$1" | env PATH="$2" CLAUDE_PROJECT_DIR="$3" bash "$4/hardhat.sh"' \
    nightshift "$payload" "$nojq" "$p" "$HOOKS"
  is_deny "$output"
  [ -f "$p/.nightshift/.shift-lease" ]

  payload="$(jq -nc \
    '{tool_name:"mcp__shell__run",session_id:"helper-session",tool_input:{command:"git commit -m \"document .nightshift/.shift-lease\""}}')"
  run bash -c 'printf "%s" "$1" | env PATH="$2" CLAUDE_PROJECT_DIR="$3" bash "$4/hardhat.sh"' \
    nightshift "$payload" "$nojq" "$p" "$HOOKS"
  is_allow

  payload="$(jq -nc --arg command $'git commit -m "line one\nline two: .nightshift/.shift-lease"' \
    '{tool_name:"mcp__shell__run",session_id:"helper-session",tool_input:{command:$command}}')"
  run bash -c 'printf "%s" "$1" | env PATH="$2" CLAUDE_PROJECT_DIR="$3" bash "$4/hardhat.sh"' \
    nightshift "$payload" "$nojq" "$p" "$HOOKS"
  is_allow
}

@test "the payload decoder preserves trailing command newlines" {
  # shellcheck source=plugins/nightshift/hooks/shared/hardhat-core.sh
  . "$HOOKS/shared/hardhat-core.sh"
  command=$'printf safe\n\n'
  payload="$(jq -nc --arg command "$command" \
    '{tool_name:"mcp__shell__run",tool_input:{command:$command}}')"
  expected="$BATS_TEST_TMPDIR/expected-command"
  captured="$BATS_TEST_TMPDIR/captured-command"
  printf '%s' "$command" >"$expected"
  CAPTURED_TARGET="$captured"
  capture_target() { printf '%s' "$1" >"$CAPTURED_TARGET"; return 1; }

  run ns_hardhat_payload_targets mcp__shell__run "$payload" "" capture_target
  [ "$status" -eq 1 ]
  cmp "$expected" "$captured"

  # Without jq there is no general JSON reader, so an opaque payload fails closed.
  noparser="$BATS_TEST_TMPDIR/trailing-no-parser"
  mkdir -p "$noparser"
  ln -sf "$(command -v bash)" "$noparser/bash"
  run env PATH="$noparser" CAPTURED_TARGET="$captured" bash -c '
    . "$1"
    capture_target() { printf "%s" "$1" >"$CAPTURED_TARGET"; return 1; }
    ns_hardhat_payload_targets mcp__shell__run "$2" "" capture_target
  ' nightshift "$HOOKS/shared/hardhat-core.sh" "$payload"
  [ "$status" -eq 2 ]
}

@test "a recovered lease fails closed when a hook payload omits session identity" {
  p="$(new_project claude-no-session)"
  punch_open "$p"
  claude_bind "$p" shift-session
  take_lease "$p" shift-session claude >/dev/null
  run bash -c \
    'jq -nc '\''{tool_name:"Read",tool_input:{file_path:"README.md"}}'\'' |
      CLAUDE_PROJECT_DIR="$1" bash "$2/hardhat.sh"' \
    nightshift "$p" "$HOOKS"
  is_deny "$output"

  c="$(new_project codex-no-session)"
  punch_open "$c"
  codex_bind "$c" shift-session
  take_lease "$c" shift-session codex >/dev/null
  run bash -c \
    'jq -nc '\''{tool_name:"mcp__filesystem__read_file",tool_input:{path:"README.md"}}'\'' |
      CODEX_PROJECT_DIR="$1" bash "$2/codex/hardhat.sh"' \
    nightshift "$c" "$HOOKS"
  is_deny "$output"
}

@test "fence-check reads the on-disk lease and refuses when it is missing" {
  p="$(new_project fence-missing)"
  punch_open "$p"
  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/continuity-handoff.sh" \
    fence-check --project "$p"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.takeoverAllowed == false' >/dev/null
  take_lease "$p" shift-session claude >/dev/null
  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/continuity-handoff.sh" \
    fence-check --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.takeoverAllowed == true and .priorOwnerFenced == true' >/dev/null
}

@test "normal completion and STOP release the process lease on both hosts" {
  p="$(new_project claude-done)"
  punch_open "$p"
  claude_bind "$p" test-shift-session
  punch_done "$p"
  run gate "$p"
  is_release
  [ ! -e "$p/.nightshift/.shift-lease" ]

  c="$(new_project codex-stop)"
  punch_open "$c"
  codex_bind "$c" test-shift-session
  : >"$c/.nightshift/STOP"
  run bash -c \
    'jq -nc '\''{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:""}'\'' |
      CODEX_PROJECT_DIR="$1" bash "$2/codex/clock-out-gate.sh"' \
    nightshift "$c" "$HOOKS"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.continue == true' >/dev/null
  [ ! -e "$c/.nightshift/.shift-lease" ]
}

@test "an owner STOP releases through a foreign Stop event even when the lease is unusable" {
  p="$(new_project claude-owner-stop)"
  punch_open "$p"
  claude_bind "$p" owner-session
  printf 'malformed\n' >"$p/.nightshift/.shift-lease"
  printf 'owner stop\n' >"$p/.nightshift/STOP"

  run gate "$p"
  is_release
  [ -f "$p/.nightshift/.ended" ]
  [ ! -e "$p/.nightshift/.shift-armed" ]
  [ ! -e "$p/.nightshift/.shift-lease" ]

  c="$(new_project codex-owner-stop)"
  punch_open "$c"
  codex_bind "$c" owner-session
  take_lease "$c" owner-session codex >/dev/null
  printf 'owner stop\n' >"$c/.nightshift/STOP"

  run bash -c \
    'jq -nc '\''{hook_event_name:"Stop",session_id:"helper-session",transcript_path:""}'\'' |
      CODEX_PROJECT_DIR="$1" bash "$2/codex/clock-out-gate.sh"' \
    nightshift "$c" "$HOOKS"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.continue == true' >/dev/null
  [ -f "$c/.nightshift/.ended" ]
  [ ! -e "$c/.nightshift/.shift-armed" ]
  [ ! -e "$c/.nightshift/.shift-lease" ]
}

# ---- a recovery attempt that died owns nothing ----
#
# A watchman transfers the lease before it spawns, so a failed attempt leaves a foreign
# generation, a foreign nonce, and the pid of a process that is gone. Nobody holds the site
# then, and the conversation the record names has to be able to pick the shift back up. The
# evidence is the pid and its start time — the same evidence Start uses.

FOREIGN_NONCE=claude.2.4711.8.9

@test "the recorded conversation reclaims a lease left by a dead recovery attempt" {
  p="$(new_project)"
  punch_open "$p"
  dead="$(reaped_pid)"
  session_record "$p" shift-session "" "$$" "$(process_start "$$")" claude
  lease_record "$p" shift-session claude 2 "$FOREIGN_NONCE" "$dead" ""

  run claude_read "$p" shift-session
  is_allow
  [ "$(lease_scope "$p")" = "shift-session" ]
  [ "$(lease_generation "$p")" = "3" ]
  [ -z "$(lease_nonce "$p")" ]
  [ "$(lease_holder_pid "$p")" = "$$" ]
  [ "$(reclaim_log_count "$p" 2 3)" -eq 1 ]

  # The fence lifts once. Every later call is an ordinary owned call, not another reclaim.
  run claude_read "$p" shift-session
  is_allow
  [ "$(lease_generation "$p")" = "3" ]
  [ "$(reclaim_log_count "$p")" -eq 1 ]
}

@test "a live recovery worker keeps the fence and keeps its own lease" {
  p="$(new_project)"
  punch_open "$p"
  sleep 300 &
  holder=$!
  session_record "$p" shift-session "" "$$" "$(process_start "$$")" claude
  lease_record "$p" shift-session claude 2 "$FOREIGN_NONCE" "$holder" "$(process_start "$holder")"

  run claude_read "$p" shift-session
  is_deny "$output"
  printf '%s' "$output" | grep -q "being recovered in another process"
  printf '%s' "$output" | grep -q "stays blocked"
  [ "$(lease_generation "$p")" = "2" ]
  [ "$(lease_nonce "$p")" = "$FOREIGN_NONCE" ]
  [ "$(lease_holder_pid "$p")" = "$holder" ]
  [ "$(reclaim_log_count "$p")" -eq 0 ]

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

@test "a dead recovery attempt is not reclaimable by a conversation the record no longer names" {
  p="$(new_project)"
  punch_open "$p"
  dead="$(reaped_pid)"
  session_record "$p" recovered-session "" "" "" claude
  lease_record "$p" original-session claude 2 "$FOREIGN_NONCE" "$dead" ""

  run claude_read "$p" original-session
  is_deny "$output"
  printf '%s' "$output" | grep -q "continued in a recovered process"
  [ "$(lease_scope "$p")" = "original-session" ]
  [ "$(lease_generation "$p")" = "2" ]
  [ "$(lease_nonce "$p")" = "$FOREIGN_NONCE" ]
  [ "$(reclaim_log_count "$p")" -eq 0 ]

  run claude_read "$p" helper-session
  is_allow
}

@test "a recovery attempt with no attached process keeps the fence" {
  p="$(new_project)"
  punch_open "$p"
  claude_bind "$p" shift-session
  take_lease "$p" shift-session claude >/dev/null

  run claude_read "$p" shift-session
  is_deny "$output"
  printf '%s' "$output" | grep -q "continued in a recovered process"
  [ "$(reclaim_log_count "$p")" -eq 0 ]
}

@test "a holder the host cannot classify keeps the fence rather than reading as dead" {
  p="$(new_project)"
  punch_open "$p"
  session_record "$p" shift-session "" "" "" claude
  lease_record "$p" shift-session claude 2 "$FOREIGN_NONCE" 4711 ""

  # An EPERM or an unrecognised kill error is missing evidence, not death.
  runner="$BATS_TEST_TMPDIR/unclassifiable-holder"
  cat >"$runner" <<'RUNNER'
#!/usr/bin/env bash
set -u
. "$1"
ns_pid_alive() { return 3; }
ns_lease_reclaim_recorded "$2/.nightshift" shift-session claude "$$" ""
RUNNER
  chmod +x "$runner"

  run bash "$runner" "$LIB" "$p"
  [ "$status" -eq 1 ]
  [ "$(lease_generation "$p")" = "2" ]
  [ "$(lease_nonce "$p")" = "$FOREIGN_NONCE" ]
  [ "$(reclaim_log_count "$p")" -eq 0 ]
}

@test "Codex reclaims a dead recovery attempt without inventing process ancestry" {
  p="$(new_project)"
  punch_open "$p"
  dead="$(reaped_pid)"
  session_record "$p" shift-session "" "" "" codex
  lease_record "$p" shift-session codex 4 codex.4.4711.8.9 "$dead" ""

  run codex_read "$p" shift-session
  is_allow
  [ "$(lease_generation "$p")" = "5" ]
  [ -z "$(lease_nonce "$p")" ]
  [ -z "$(lease_holder_pid "$p")" ]
  [ "$(reclaim_log_count "$p" 4 5)" -eq 1 ]
}
