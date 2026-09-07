#!/usr/bin/env bats
# A hook is a process, not a library. Every test that sources a hook and calls its functions proves
# the functions work; none of them proves the file runs. `hooks/pulse.sh` defined its functions
# after the block that calls them, so a real Claude Code invocation reached the calls with the names
# undefined, wrote "command not found" to stderr, exited 0, and recorded no usage at all. The whole
# suite passed throughout.
#
# These run each hook the way a host runs it — as a process, with a payload on stdin — and hold the
# rule that makes the class impossible: in a file that both defines functions and executes, the
# executable block comes last.

load helpers

HOOKS="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks"
FIX="$BATS_TEST_DIRNAME/fixtures/usage/claude-multiline.jsonl"

# armed_site <name> — a scaffolded, armed workspace whose session id the payload will carry.
armed_site() {
  local p
  p="$(new_project "$1")"
  printf '# Punch list\n\n## Items\n\n- [ ] **A1 — a thing.**\n' >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  printf 'sess-hook-entry\n' >"$p/.nightshift/.shift-session"
  cp "$FIX" "$p/transcript.jsonl"
  printf '%s' "$p"
}

payload() { # <project>
  printf '{"session_id":"sess-hook-entry","transcript_path":"%s/transcript.jsonl","cwd":"%s","tool_name":"Edit","tool_input":{}}' "$1" "$1"
}

@test "the Claude pulse runs as a process and records a reading" {
  p="$(armed_site hook-entry-claude)"
  run env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/pulse.sh" <<<"$(payload "$p")"
  [ "$status" -eq 0 ]
  # The defect was invisible in stdout and in the exit code. It was only ever on stderr.
  [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
  [ -f "$p/.nightshift/usage/segments.tsv" ]
  [ "$(wc -l <"$p/.nightshift/usage/segments.tsv" | tr -d ' ')" -eq 1 ]
}

@test "the Codex and Cursor pulses run as processes too" {
  for host in codex cursor; do
    p="$(armed_site "hook-entry-$host")"
    run env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/$host/pulse.sh" <<<"$(payload "$p")"
    [ "$status" -eq 0 ] || { echo "$host exited $status"; return 1; }
    [ -z "$stderr" ] || { echo "$host stderr: $stderr"; return 1; }
  done
}

@test "the gate and the session hooks run as processes without an undefined name" {
  p="$(armed_site hook-entry-others)"
  for h in clock-out-gate.sh session-end.sh session-start.sh hardhat.sh; do
    run env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/$h" <<<"$(payload "$p")"
    printf '%s' "$stderr" | grep -q 'command not found' \
      && { echo "$h: $stderr"; return 1; }
  done
  return 0
}

# The rule itself, checked by reading rather than by running: a hook that defines functions and then
# executes must place the executable block after the last definition. Reading catches it in a file
# whose execution path happens not to reach the undefined name today.
@test "every hook puts its executable block after the last function it defines" {
  local f exec_line last_fn rel
  for f in "$HOOKS"/*.sh "$HOOKS"/codex/*.sh "$HOOKS"/cursor/*.sh; do
    [ -f "$f" ] || continue
    case "$f" in */lib-io.sh) continue ;; esac
    exec_line="$(grep -nF 'BASH_SOURCE[0]}" = "$0"' "$f" | head -1 | cut -d: -f1)"
    [ -n "$exec_line" ] || continue
    last_fn="$(grep -nE '^[A-Za-z_][A-Za-z_0-9]*\(\) \{' "$f" | tail -1 | cut -d: -f1)"
    [ -n "$last_fn" ] || continue
    rel="${f#"$HOOKS"/}"
    [ "$exec_line" -gt "$last_fn" ] || {
      echo "$rel: executable block at line $exec_line, but a function is defined at $last_fn"
      return 1
    }
  done
}

# ------------------------------------------------------------------------------------------------
# Stdin, bounded
#
# A hook handed a descriptor that never reaches EOF used to sit in `cat` until something killed it:
# one held a session for five and a half hours with its payload in argv the whole time. These hold
# every hook to a bounded read, and to reaching its own fallbacks when nothing arrives.

# held_open <hook> [argv…] — the hook with stdin open and silent, the case that used to hang.
#
# `timeout` is GNU and is not on a stock macOS runner; perl's alarm is, and is the same measurement.
# HELD_ELAPSED is what the assertion reads: the hook has its own bound, so finishing quickly is the
# claim, not the exit status of whatever ran it.
held_open() {
  local hook="$1" start end
  shift
  start="$(date +%s)"
  run env CLAUDE_PROJECT_DIR="$WS" CURSOR_PROJECT_DIR="$WS" CODEX_PROJECT_DIR="$WS" \
    perl -e 'alarm 10; exec @ARGV or exit 127' bash "$hook" "$@" < <(sleep 30)
  end="$(date +%s)"
  HELD_ELAPSED=$((end - start))
}

@test "a hook whose stdin never closes still finishes, and uses the payload it was given" {
  ws="$(armed_site stdin-held)"
  WS="$ws"
  payload="$(payload "$ws")"

  # Cursor's before-submit is where this was found live: the payload was in argv the whole time.
  held_open "$HOOKS/cursor/before-submit.sh" "$payload"
  [ "$HELD_ELAPSED" -lt 8 ]

  # The pulse proves the argv payload was actually read: no session id, no pulse file.
  rm -f "$ws/.nightshift/.shift-pulse"
  held_open "$HOOKS/cursor/pulse.sh" "$payload"
  [ "$HELD_ELAPSED" -lt 8 ]
  [ -f "$ws/.nightshift/.shift-pulse" ]
  grep -q 'sess-hook-entry$' "$ws/.nightshift/.shift-pulse"

  # Codex documents no argv fallback, so it has nothing to fall back to and simply finishes.
  held_open "$HOOKS/codex/pulse.sh" "$payload"
  [ "$HELD_ELAPSED" -lt 8 ]

  # The guard hook decides on the same payload and lets an ordinary command through.
  held_open "$HOOKS/cursor/hardhat.sh" "$payload"
  [ "$HELD_ELAPSED" -lt 8 ]
}

@test "a payload delivered on stdin parses the way it always did" {
  ws="$(armed_site stdin-normal)"
  run env CLAUDE_PROJECT_DIR="$ws" bash "$HOOKS/pulse.sh" <<<"$(payload "$ws")"
  [ "$status" -eq 0 ]
  [ -f "$ws/.nightshift/.shift-pulse" ]
  grep -q 'sess-hook-entry$' "$ws/.nightshift/.shift-pulse"
}

@test "empty stdin falls through to the environment the host set" {
  ws="$(armed_site stdin-env)"
  run env CURSOR_PROJECT_DIR="$ws" CURSOR_HOOK_INPUT="$(payload "$ws")" \
    bash "$HOOKS/cursor/pulse.sh" </dev/null
  [ "$status" -eq 0 ]
  [ -f "$ws/.nightshift/.shift-pulse" ]
}

@test "no hook reads stdin unbounded" {
  # The bound belongs to every hook, not to the one where the hang was found.
  for h in "$HOOKS"/*.sh "$HOOKS"/codex/*.sh "$HOOKS"/cursor/*.sh; do
    ! grep -qE '\$\(cat\)|`cat`' "$h" || { echo "reads stdin unbounded: $h"; return 1; }
  done
  grep -qF 'ns_read_stdin_bounded()' "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/common.sh"
}
