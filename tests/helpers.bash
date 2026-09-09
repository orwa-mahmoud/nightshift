# Shared helpers for the nightshift hook tests.
# Paths are relative to this file so suites under tests/<host>/ resolve the plugin too.
_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$_TEST_ROOT/../plugins/nightshift/hooks"
RULES_TEMPLATE="$_TEST_ROOT/../plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json"

# Create an isolated project with its own git repo and a .nightshift dir. Echoes the path.
# The suite must see only the env a test passes explicitly — a developer's own shell (or a
# host that feeds settings env into commands) must never leak NIGHTSHIFT_* into fixtures.
while IFS='=' read -r _v _; do
  case "$_v" in NIGHTSHIFT_*) unset "$_v" ;; esac
done < <(env)

new_project() {
  local p="$BATS_TEST_TMPDIR/${1:-proj}"
  mkdir -p "$p/.nightshift"
  cp "$RULES_TEMPLATE" "$p/.nightshift/rules.json" # as setup does — the one copy of every knob
  : >"$p/.nightshift/.shift-armed"                 # as /nightshift:start does — a shift is running
  git -C "$p" init -q
  git -C "$p" config user.email dev@example.com
  git -C "$p" config user.name tester
  git -C "$p" commit -q --allow-empty -m init
  printf '%s' "$p"
}

# Create the recommended layout: a plain workspace folder that is NOT a repo, holding the code
# repo one level down and .nightshift beside it. Echoes the workspace path.
new_workspace() {
  local w="$BATS_TEST_TMPDIR/${1:-ws}"
  mkdir -p "$w/.nightshift"
  cp "$RULES_TEMPLATE" "$w/.nightshift/rules.json"
  : >"$w/.nightshift/.shift-armed"
  add_repo "$w" repo
  printf '%s' "$w"
}

# add_repo <workspace> <name> — add another git repo one level down.
add_repo() {
  local r="$1/$2"
  mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email dev@example.com
  git -C "$r" config user.name tester
  git -C "$r" commit -q --allow-empty -m init
}

# Give <project>/.nightshift its own local receipts repo, as /nightshift:setup does.
receipts_init() {
  printf 'STOP\n.stall\n.notified\ndeadline\n.shift-session.tmp.*\n.shift-lease\n.shift-lease.tmp.*\n.lease-lock.d/\n' >"$1/.nightshift/.gitignore"
  git -C "$1/.nightshift" init -q
  git -C "$1/.nightshift" add -A
  git -C "$1/.nightshift" -c user.name=t -c user.email=t@example.com commit -q -m init
}

# A punch list with one open and one ticked box (TICKED=1, TOTAL=2).
# A background writer races the watchman it is meant to feed: on a loaded runner every sample can
# land before the subshell is even scheduled, so a live session reads as dead and the test fails
# with nothing wrong in the code. Writers signal once they are running; this blocks until then, so
# a red suite always means a real defect.
wait_writer() {
  local flag="$1" i=0
  while [ ! -e "$flag" ]; do
    i=$((i + 1))
    [ "$i" -lt 400 ] || { echo "background writer never started: $flag" >&2; return 1; }
    sleep 0.05
  done
}

punch_open() { printf '## Items\n- [ ] **1. first.**\n- [x] **2. done.**\n' >"$1/.nightshift/punch-list.md"; }
punch_done() { printf '## Items\n- [x] **1. first.**\n- [x] **2. done.**\n' >"$1/.nightshift/punch-list.md"; }

# gate <project> [ENV=VAL ...] — pipes a minimal Stop payload; the gate reads stdin now.
gate() {
  local p="$1"
  shift
  jq -nc '{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:""}' |
    env "$@" CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/clock-out-gate.sh"
}

# hardhat_bash <project> <command> [ENV=VAL ...]
hardhat_bash() {
  local p="$1" c="$2"
  shift 2
  jq -nc --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}' |
    env "$@" CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
}

# hardhat_sid_bash <project> <session-id> <command> [ENV=VAL ...]
hardhat_sid_bash() {
  local p="$1" sid="$2" c="$3"
  shift 3
  jq -nc --arg sid "$sid" --arg c "$c" \
    '{tool_name:"Bash",session_id:$sid,tool_input:{command:$c}}' |
    env "$@" CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
}

# hardhat_bash_cwd <project> <cwd> <command> [ENV=VAL ...]
hardhat_bash_cwd() {
  local p="$1" w="$2" c="$3"
  shift 3
  jq -nc --arg c "$c" --arg w "$w" '{tool_name:"Bash",cwd:$w,tool_input:{command:$c}}' |
    env "$@" CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
}

# hardhat_ask <project> [ENV=VAL ...]
hardhat_ask() {
  local p="$1"
  shift
  jq -nc '{tool_name:"AskUserQuestion",tool_input:{}}' |
    env "$@" CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
}

# ---------------------------------------------------------------------------------------------
# Shift-ownership fixtures. The conversation record and the process lease are line-oriented
# files the runtime reads by position, so a test that plants one states every line. These write
# the file directly — a fixture must be able to describe states the write helpers refuse.

# session_record <project> <sid> <transcript> <pid> <start> <host>
session_record() {
  local f="$1/.nightshift/.shift-session"
  printf '%s\n%s\n%s\n%s\n%s\n' "$2" "$3" "$4" "$5" "$6" >"$f"
  chmod 600 "$f"
}

# lease_record <project> <sid> <host> <generation> <nonce> <pid> <start>
lease_record() {
  local f="$1/.nightshift/.shift-lease"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$2" "$3" "$4" "$5" "$6" "$7" >"$f"
  chmod 600 "$f"
}

lease_scope()      { sed -n 1p "$1/.nightshift/.shift-lease"; }
lease_generation() { sed -n 3p "$1/.nightshift/.shift-lease"; }
lease_nonce()      { sed -n 4p "$1/.nightshift/.shift-lease"; }
lease_holder_pid() { sed -n 5p "$1/.nightshift/.shift-lease"; }

# process_start <pid> — the start-time line the runtime pairs with a pid, in its own format.
process_start() {
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# reaped_pid — a pid whose process has exited and been waited for: provably dead.
reaped_pid() {
  local pid
  bash -c ':' &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s' "$pid"
}

# reclaim_log_count <project> [old-generation new-generation]
# How many times the shift log records a lease reclaim: any reclaim with no generations given,
# or the exact sentence for that one transition when both are.
reclaim_log_count() {
  local log="$1/.nightshift/shift-log.md"
  local needle='lease reclaimed by the recorded conversation after a dead recovery attempt'
  [ -f "$log" ] || { printf '0'; return 0; }
  if [ "$#" -eq 3 ]; then needle="$needle (generation $2 → $3)"; fi
  grep -cF "$needle" "$log" || true
}

is_block() { printf '%s' "$1" | grep -q '"decision":"block"' && printf '%s' "$1" | jq -e . >/dev/null; }
is_deny() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"' && printf '%s' "$1" | jq -e . >/dev/null; }

# Letting something through is a positive claim, not the absence of a string: the hook must have
# run to completion AND said nothing. `! is_deny "$output"` alone also passes when the hook
# crashed, was never invoked, or exited before reaching the rule under test — which is no
# assertion at all. These read bats' own $status/$output, so call them with no arguments.
is_allow() { [ "$status" -eq 0 ] && [ -z "$output" ]; }
is_release() { [ "$status" -eq 0 ] && [ -z "$output" ]; }

# ---------------------------------------------------------------------------------------------
# Engine-parity helpers, shared by any suite comparing a native (bash/PowerShell) reimplementation
# against the Python reference: building a controlled, minimal PATH of symlinks to real tools so
# a script can be run against an exact, known toolset (with or without jq/python3) and compared
# byte-for-byte across engines. A test file that uses these sets its own `PWSH_BIN` (empty when no
# pwsh binary exists on the real PATH) before relying on `have_pwsh`.

have_pwsh() { [ -n "$PWSH_BIN" ]; }

# controlled_bin <dir-name> — makes and echoes an empty $BATS_TEST_TMPDIR/<dir-name> for a
# test to drop fake executables into.
controlled_bin() {
  local d="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# fake_exe <dir> <name> <script-line...> — writes an executable POSIX shell script.
fake_exe() {
  local dir="$1" name="$2"
  shift 2
  {
    printf '#!/bin/sh\n'
    printf '%s\n' "$@"
  } >"$dir/$name"
  chmod +x "$dir/$name"
}

# resolve_tool_path <tool> — prints an absolute path for <tool>. Bypasses any shell function
# or alias of the same name in the calling shell (a wrapped `grep`/`find`, say) so it can never
# leak into a fixture's controlled PATH, and falls back to /bin or /usr/bin for builtins like
# `test`, `printf`, `true`, `false` that `command -v` reports by bare name only.
resolve_tool_path() {
  local tool="$1" real cand
  real="$(unset -f "$tool" 2>/dev/null; command -v "$tool" 2>/dev/null)"
  case "$real" in
  */*)
    printf '%s' "$real"
    return 0
    ;;
  esac
  for cand in "/bin/$tool" "/usr/bin/$tool"; do
    if [ -x "$cand" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

# build_toolset_bin <dir-name> <tool...> — makes $BATS_TEST_TMPDIR/<dir-name> containing a
# symlink to each named tool's real, resolved location. Echoes the dir path.
build_toolset_bin() {
  local d tool real
  d="$BATS_TEST_TMPDIR/$1"
  shift
  mkdir -p "$d"
  for tool in "$@"; do
    real="$(resolve_tool_path "$tool")" || { echo "test host is missing required tool: $tool" >&2; return 1; }
    ln -s "$real" "$d/$tool"
  done
  printf '%s' "$d"
}
