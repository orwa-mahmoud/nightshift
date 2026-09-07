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
