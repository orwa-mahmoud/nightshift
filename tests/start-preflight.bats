#!/usr/bin/env bats
# The Start skill's one preflight. Every line is a verdict the skill acts on, so the vocabulary
# and the exit code are the contract — not the prose that used to carry these rules.

bats_require_minimum_version 1.5.0

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
PREFLIGHT="$PLUGIN/runtime/start-preflight.sh"
PS1_TWIN="$PLUGIN/runtime/windows/start-preflight.ps1"
START="$PLUGIN/skills/start/SKILL.md"
HOSTS="$PLUGIN/skills/nightshift/references/start-hosts.md"

load helpers

# A fresh site with one open item and no leftovers: nothing to refuse, nothing to repair.
setup_site() { # <name> [punch-body]
  local p
  p="$(new_project "$1")"
  rm -f "$p/.nightshift/.shift-armed"
  printf '%s' "${2:-## Items
- [ ] **1. work.**
}" >"$p/.nightshift/punch-list.md"
  printf '%s' "$p"
}

@test "a clean site arms and every line is a verdict" {
  p="$(setup_site preflight-clean)"
  run bash "$PREFLIGHT" --project "$p" --host claude
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^ok host claude$'
  printf '%s\n' "$output" | grep -qE '^ok workspace '
  printf '%s\n' "$output" | grep -qE '^ok work-mode repository$'
  printf '%s\n' "$output" | grep -qE '^ok work-target '
  printf '%s\n' "$output" | grep -qE '^ok rules readable$'
  printf '%s\n' "$output" | grep -qE '^ok punch-list open=1 ticked=0$'
  printf '%s\n' "$output" | grep -qE '^ok deadline none \(finite list'
  printf '%s\n' "$output" | grep -qE '^ok provision none pending$'
  while IFS= read -r line; do
    case "$line" in
      ok\ * | warn\ * | repair\ * | refuse\ *) ;;
      *) echo "not a verdict: $line"; return 1 ;;
    esac
  done < <(printf '%s\n' "$output")
}

@test "a missing site refuses and names the repair" {
  p="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$p"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse workspace no usable .nightshift/'
  printf '%s\n' "$output" | grep -qF 'repair run Nightshift setup in this project'
}

@test "an invalid workspace link refuses rather than guessing a workspace" {
  p="$(setup_site preflight-link)"
  printf '/nowhere/at/all\n' >"$p/.nightshift-link"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse link .nightshift-link does not name one existing Nightshift workspace'
  printf '%s\n' "$output" | grep -qF 'repair rewrite .nightshift-link'
}

@test "a paused shift with a spent deadline gets no silent new budget" {
  p="$(setup_site preflight-spent)"
  : >"$p/.nightshift/STOP"
  printf '100\n' >"$p/.nightshift/deadline"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse control a paused shift with an expired deadline does not get a silent new budget'
  printf '%s\n' "$output" | grep -qF 'never clear STOP and never invent a time budget'
  [ -f "$p/.nightshift/STOP" ]
  [ -f "$p/.nightshift/deadline" ]
}

@test "an open-ended item with no deadline refuses instead of inventing hours" {
  p="$(setup_site preflight-open-ended '## Items
- [ ] **1. walkthrough.** Ending: open-ended
')"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse deadline an open-ended item has no clock'
  printf '%s\n' "$output" | grep -qF 'repair compose the shift through Hunt, which asks for hours; never invent a number'
}

@test "a future deadline is kept and projected, a spent one is cleared" {
  p="$(setup_site preflight-future)"
  future=$(($(date +%s) + 7200))
  printf '%s\n' "$future" >"$p/.nightshift/deadline"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "ok deadline $future (file"
  [ -f "$p/.nightshift/deadline" ]

  q="$(setup_site preflight-spent-clear)"
  printf '100\n' >"$q/.nightshift/deadline"
  run bash "$PREFLIGHT" --project "$q"
  [ "$status" -eq 0 ]
  [ ! -e "$q/.nightshift/deadline" ]
  printf '%s\n' "$output" | grep -qF 'ok markers '
}

@test "every stale run-control marker is cleared before anything writes a new one" {
  p="$(setup_site preflight-markers)"
  for m in STOP .stall .notified .ended .session-end .shift-pulse .mint-failed .shift-session \
    .shift-armed .watchman-tick; do
    : >"$p/.nightshift/$m"
  done
  mkdir -p "$p/.nightshift/.lock.d"
  printf 'sid\ntranscript\n1\nstart\nclaude\n' >"$p/.nightshift/.shift-lease"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse lease malformed'
  rm -f "$p/.nightshift/.shift-lease"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 0 ]
  for m in STOP .stall .notified .ended .session-end .shift-pulse .mint-failed .shift-session \
    .shift-armed .watchman-tick .lock.d .shift-lease; do
    [ ! -e "$p/.nightshift/$m" ] || { echo "left behind: $m"; return 1; }
  done
}

@test "a live recorded session refuses a second shift beside it" {
  p="$(setup_site preflight-live)"
  flag="$BATS_TEST_TMPDIR/live-flag"
  ( : >"$flag"; sleep 5 ) &
  worker=$!
  wait_writer "$flag"
  start="$(bash -c ". \"$PLUGIN/lib/lib.sh\"; ns_process_start $worker")"
  printf 'sid-1\n/tmp/t.jsonl\n%s\n%s\nclaude\n' "$worker" "$start" >"$p/.nightshift/.shift-session"
  run bash "$PREFLIGHT" --project "$p"
  kill "$worker" 2>/dev/null || true
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse session an agent is already working this punch list on claude'
  printf '%s\n' "$output" | grep -qF 'repair ask Nightshift for status'
  [ -f "$p/.nightshift/.shift-session" ]
}

@test "a missing rules file refuses and points at Setup" {
  p="$(setup_site preflight-rules)"
  rm -f "$p/.nightshift/rules.json"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse rules rules.json is missing'
  printf '%s\n' "$output" | grep -qF 'repair run Setup and accept the shipped rules template'
}

@test "a broken rules file refuses with the named reason" {
  p="$(setup_site preflight-rules-broken)"
  printf '{\n' >"$p/.nightshift/rules.json"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse rules rules.json is not the accepted shape:'
  printf '%s\n' "$output" | grep -qF 'never half-apply a broken file'
}

@test "an empty watchman recovery key refuses to arm" {
  p="$(setup_site preflight-watchkeys)"
  jq '.revivalPrompt = ""' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.tmp"
  mv "$p/.nightshift/rules.tmp" "$p/.nightshift/rules.json"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse rules revivalPrompt is empty, so the watchman would refuse to arm'
  printf '%s\n' "$output" | grep -qF 'repair restore revivalPrompt from the shipped rules template with Setup'
}

@test "watchMinutes 0 leaves the watchman disarmed and needs no recovery keys" {
  p="$(setup_site preflight-nowatch)"
  jq '.watchMinutes = 0 | .revivalPrompt = ""' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.tmp"
  mv "$p/.nightshift/rules.tmp" "$p/.nightshift/rules.json"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'ok watch-minutes 0 (watchman disarmed)'
}

@test "an unrecovered provisioning transaction refuses with the restore instruction" {
  p="$(setup_site preflight-provision)"
  printf '{\n' >"$p/.nightshift/provision-transaction.json"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse provision an interrupted install cannot be proven recovered'
  printf '%s\n' "$output" | grep -qF '.nightshift/provision-transaction.json and provision-baseline/, restore by hand or run'
  printf '%s\n' "$output" | grep -qF 'provision.sh rollback after fixing the target, then Start again'
}

@test "an empty punch list warns rather than refusing, and names what is staged" {
  p="$(setup_site preflight-empty '## Items
')"
  printf '## Work order\n\nHours: 2\n\n- [ ] **1. staged.**\n' >"$p/.nightshift/work-orders.md"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'ok punch-list open=0 ticked=0'
  printf '%s\n' "$output" | grep -qF 'ok staged orders=1 drafts=0'
  printf '%s\n' "$output" | grep -qF 'warn punch-list empty - offer the staged orders and drafts'
}

@test "a future state-version fails closed and never rewrites the marker" {
  p="$(setup_site preflight-future-state)"
  printf '99\n' >"$p/.nightshift/state-version"
  run bash "$PREFLIGHT" --project "$p"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse state-version Nightshift state-version is newer than this plugin supports'
  printf '%s\n' "$output" | grep -qF 'Start never writes it'
  [ "$(cat "$p/.nightshift/state-version")" = 99 ]
}

@test "each host gets its own permission-mode note" {
  p="$(setup_site preflight-perms)"
  run bash "$PREFLIGHT" --project "$p" --host claude
  printf '%s\n' "$output" | grep -qF 'warn permissions no frictionless grant in'
  mkdir -p "$p/.claude"
  printf '{"permissions":{"defaultMode":"bypassPermissions"}}\n' >"$p/.claude/settings.local.json"
  run bash "$PREFLIGHT" --project "$p" --host claude
  printf '%s\n' "$output" | grep -qF 'ok permissions frictionless permissions are granted at'
  run bash "$PREFLIGHT" --project "$p" --host codex
  printf '%s\n' "$output" | grep -qF 'codex -a never -s danger-full-access'
  run bash "$PREFLIGHT" --project "$p" --host cursor
  printf '%s\n' "$output" | grep -qF 'never passes the IDE conversation id to agent --resume'
}

# Codex hands identity to Nightshift through hook payloads, so the checkpoint can only run once
# the binding probe has written .shift-session — after the marker, before the watchman.
@test "the bind phase classifies the recorded Codex identity" {
  p="$(setup_site preflight-bind)"
  printf '019624f3-6a41-7a6f-9f1e-3a8f0b2c4d5e\n/tmp/r.jsonl\n\n\ncodex\n' >"$p/.nightshift/.shift-session"
  run bash "$PREFLIGHT" --project "$p" --phase bind
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'ok codex-identity resumable'

  printf 'thread_abc123\n/tmp/r.jsonl\n\n\ncodex\n' >"$p/.nightshift/.shift-session"
  run bash "$PREFLIGHT" --project "$p" --phase bind
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse codex-identity unsupported'
  printf '%s\n' "$output" | grep -qF 'before the watchman or item work'

  printf 'sid\n/tmp/t.jsonl\n\n\nclaude\n' >"$p/.nightshift/.shift-session"
  run bash "$PREFLIGHT" --project "$p" --phase bind
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'ok codex-identity not-applicable'
}

@test "the preflight needs neither jq nor python3" {
  p="$(setup_site preflight-noparser)"
  bin="$BATS_TEST_TMPDIR/nojson"
  mkdir -p "$bin"
  for tool in bash sh sed awk grep tr cat cut date mkdir mv rm ls wc head tail sort uniq git \
    kill ps stat find od printf sleep touch chmod dirname basename expr sha256sum shasum; do
    src="$(command -v "$tool" 2>/dev/null)" && ln -sf "$src" "$bin/$tool"
  done
  run env -i HOME="$HOME" PATH="$bin" bash "$PREFLIGHT" --project "$p" --host claude
  [ "$status" -eq 0 ]
  # The snapshot is read either way, so the preflight never downgrades to the rules file alone.
  if printf '%s\n' "$output" | grep -qF 'no JSON parser is installed'; then
    echo "the preflight still bypasses tonight's policy without a parser"
    return 1
  fi
  printf '%s\n' "$output" | grep -qE '^(ok|warn) policy '
}

@test "the dry run reports without touching the site" {
  p="$(setup_site preflight-dry)"
  : >"$p/.nightshift/STOP"
  before="$(find "$p/.nightshift" | sort)"
  run bash "$PREFLIGHT" --project "$p" --dry-run
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'ok markers dry-run'
  [ "$(find "$p/.nightshift" | sort)" = "$before" ]
}

@test "usage errors exit 2, distinct from a refusal" {
  run bash "$PREFLIGHT" --phase nonsense --project "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  run bash "$PREFLIGHT" --host solaris --project "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
}

# Both hosts print the same sentences. The PowerShell twin is ASCII by convention, so the POSIX
# helper's verdict lines are ASCII too — otherwise "byte-identical" is a claim nobody can keep.
@test "the two helpers ship together and speak one ASCII vocabulary" {
  [ -f "$PREFLIGHT" ]
  [ -f "$PS1_TWIN" ]
  # A literal class, not a \x escape: BSD grep does not expand those inside brackets, so the
  # escaped form matches x, 8, 0 and f and proves nothing.
  nonascii="$(printf '[^\t\040-\176]')"
  if LC_ALL=C grep -qE "^[[:space:]]*(ok|warn|repair|refuse) \"[^\"]*$nonascii" "$PREFLIGHT"; then
    echo "a verdict line in the POSIX helper is not ASCII"
    return 1
  fi
  if LC_ALL=C grep -q "$nonascii" "$PS1_TWIN"; then
    echo "the Windows twin is not ASCII"
    return 1
  fi
  for phrase in 'workspace no usable .nightshift/ at' \
    'link .nightshift-link does not name one existing Nightshift workspace' \
    'control a paused shift with an expired deadline does not get a silent new budget' \
    'deadline an open-ended item has no clock' \
    'provision an interrupted install cannot be proven recovered' \
    'watch-minutes 0 (watchman disarmed)' \
    'codex-identity resumable'; do
    grep -qF "$phrase" "$PREFLIGHT" || { echo "POSIX helper lost: $phrase"; return 1; }
    grep -qF "$phrase" "$PS1_TWIN" || { echo "Windows twin lost: $phrase"; return 1; }
  done
}

@test "Start routes through the helper instead of restating its rules" {
  grep -qF 'runtime/start-preflight.sh' "$START"
  grep -qF 'runtime\windows\start-preflight.ps1' "$START"
  grep -qF -- '--phase bind' "$START"
  grep -qF 'refuse' "$START"
  grep -qF 'repair' "$START"
  [ -f "$HOSTS" ]
  grep -qF 'start-hosts.md' "$START"
}

# The helpers these skills used to name are gone from the runtime. A skill that still names one
# sends the model looking for a file that will never be there.
@test "the routed skills name no helper the plugin no longer ships" {
  for s in start setup status doctor; do
    f="$PLUGIN/skills/$s/SKILL.md"
    ! grep -qE 'history-context|shift-planner|shift-preview|plan-learning|quality-workflow|redact-untrusted' "$f" \
      || { echo "$s names a helper that no longer exists"; return 1; }
  done
}

@test "the Windows suite runs the portable start-preflight logic" {
  grep -qF 'start-preflight-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  [ -f "$BATS_TEST_DIRNAME/windows/start-preflight-logic.ps1" ]
}

@test "the portable Windows start-preflight logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$BATS_TEST_DIRNAME/windows/start-preflight-logic.ps1"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------
# A host launched in a parent folder, with the working directory moved afterwards, would arm the
# shift in one workspace and record its session against another. Nightshift names both and stops.

@test "a host opened on one project and a start given another refuses before arming" {
  parent="$BATS_TEST_TMPDIR/parent"
  mkdir -p "$parent"
  p="$(setup_site bind-mismatch)"
  run env CLAUDE_PROJECT_DIR="$parent" bash "$PREFLIGHT" --project "$p" --host claude
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q '^refuse binding '
  printf '%s\n' "$output" | grep -qF "$parent"
  printf '%s\n' "$output" | grep -qF "$p"
  printf '%s\n' "$output" | grep -q '^repair '
  # Nothing was armed, and no marker was left behind in either place.
  [ ! -f "$p/.nightshift/.shift-armed" ]
  [ ! -e "$parent/.nightshift" ]
}

@test "the ordinary direct launch is unaffected" {
  p="$(setup_site bind-direct)"
  run env CLAUDE_PROJECT_DIR="$p" bash "$PREFLIGHT" --project "$p" --host claude
  [ "$status" -eq 0 ]
  if printf '%s\n' "$output" | grep -q '^refuse binding '; then
    echo "a direct launch was refused"
    return 1
  fi
}

@test "a linked workspace is a binding, not a mismatch" {
  ws="$(setup_site bind-linked)"
  opened="$BATS_TEST_TMPDIR/opened-elsewhere"
  mkdir -p "$opened"
  printf '%s\n' "$ws" >"$opened/.nightshift-link"
  run env CLAUDE_PROJECT_DIR="$opened" bash "$PREFLIGHT" --project "$ws" --host claude
  [ "$status" -eq 0 ]
  if printf '%s\n' "$output" | grep -q '^refuse binding '; then
    echo "a linked workspace was read as a mismatch"
    return 1
  fi
}

@test "a host that names no project at all still starts" {
  p="$(setup_site bind-no-env)"
  run env -u CLAUDE_PROJECT_DIR -u CODEX_PROJECT_DIR bash "$PREFLIGHT" --project "$p" --host claude
  [ "$status" -eq 0 ]
  if printf '%s\n' "$output" | grep -q '^refuse binding '; then
    echo "a host with no project variable was refused"
    return 1
  fi
}
