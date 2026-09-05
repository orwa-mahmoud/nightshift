#!/usr/bin/env bats
# 06A — a one-prompt feature night on a PATH with neither python3 nor jq.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
HELPER="$BATS_TEST_DIRNAME/helpers/armed-path-no-parser.sh"
QUALITY="$PLUGIN/skills/quality/SKILL.md"
HUNT="$PLUGIN/skills/hunt/SKILL.md"
START="$PLUGIN/skills/start/SKILL.md"

# bash, coreutils, git, and the hook readers. No python3. No jq.
ARMED_PATH_TOOLSET="bash sh sed tr sort grep cut awk cat mktemp uname date \
rm mv cp ln printf head tail wc find test dirname basename cksum env true false \
chmod git touch mkdir sleep kill ps stat cmp xargs ls readlink"

@test "Quality routes a feature sentence to Hunt and keeps a quality sentence" {
  grep -qF 'continue as Hunt / Product Evolution' "$QUALITY"
  grep -qF 'Do not show Quality catalog cards' "$QUALITY"
  grep -qF 'stay in this skill' "$QUALITY"
  grep -qF 'use the next 20 hours adding features and enhancing existing ones' "$HUNT"
  grep -qF '8 hours clear lint and test debt' "$HUNT"
  grep -qF 'reads the same on every host, with or without `jq` and `python3`' "$START"
  if grep -qF 'python3' "$QUALITY"; then
    return 1
  fi
  if grep -qF 'python3' "$HUNT"; then
    return 1
  fi
}

@test "the plugin ships no Python" {
  run git -C "$ROOT" ls-files 'plugins/nightshift/**/*.py'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an armed feature shift runs Setup through clock-out without python3 or jq" {
  bin="$(build_toolset_bin armed-no-parser-bin $ARMED_PATH_TOOLSET)"
  [ ! -e "$bin/python3" ]
  [ ! -e "$bin/jq" ]

  p="$BATS_TEST_TMPDIR/armed-feature"
  mkdir -p "$p"
  git -C "$p" init -q
  git -C "$p" config user.email tester@example.com
  git -C "$p" config user.name tester
  git -C "$p" commit -q --allow-empty -m init

  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash "$HELPER" --plugin-root "$PLUGIN" --project "$p"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -qF 'PATH has neither python3 nor jq'
  printf '%s\n' "$output" | grep -qF 'ns_rules_check → 0'
  printf '%s\n' "$output" | grep -qF 'shift-policy set → wrote tonight-s snapshot with no parser'
  printf '%s\n' "$output" | grep -qF 'shift-policy get → read it back'
  printf '%s\n' "$output" | grep -qF 'resolve → the chosen level, tooling and one-shift allowance all survive with no parser'
  printf '%s\n' "$output" | grep -qF 'hardhat /usr/bin/sudo → deny'
  printf '%s\n' "$output" | grep -qF 'hardhat .nightshift//shift-policy.json write → deny'
  printf '%s\n' "$output" | grep -qF 'clock-out unreadable punch list → block (no release)'
  printf '%s\n' "$output" | grep -qF 'tick + receipt + clock-out → release'
  printf '%s\n' "$output" | grep -qF 'export-support default bundle omits planted ghp_ / AKIA'
  printf '%s\n' "$output" | grep -qxF 'armed-path: ok'
}

# The rules file predates the elevation object, so every category answers from the built-in
# patterns alone — with no parser on PATH, the reader that supplies them is awk. Creating system
# state is denied and inspecting it is ordinary work, and an open box still holds the gate shut.
@test "the built-in elevation patterns gate creation, not inspection, without python3 or jq" {
  bin="$(build_toolset_bin builtin-elevation-bin $ARMED_PATH_TOOLSET)"
  [ ! -e "$bin/python3" ]
  [ ! -e "$bin/jq" ]

  p="$(new_project no-parser-elevation)"
  punch_open "$p"
  jq 'del(.elevation)' "$p/.nightshift/rules.json" >"$p/rules.tmp"
  mv "$p/rules.tmp" "$p/.nightshift/rules.json"
  if grep -qF '"elevation"' "$p/.nightshift/rules.json"; then
    return 1
  fi

  # jq builds the payload outside the guarded PATH; only the hook runs without a parser.
  bare_hardhat() {
    jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' |
      env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" CLAUDE_PROJECT_DIR="$p" \
        bash "$HOOKS/hardhat.sh"
  }
  bare_gate() {
    printf '%s' '{"hook_event_name":"Stop","session_id":"no-parser-session","transcript_path":""}' |
      env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" CLAUDE_PROJECT_DIR="$p" \
        bash "$HOOKS/clock-out-gate.sh"
  }

  run bare_hardhat 'docker run alpine'
  is_deny "$output"
  run bare_hardhat '/usr/bin/sudo id'
  is_deny "$output"
  run bare_hardhat 'brew install jq'
  is_deny "$output"

  run bare_hardhat 'docker ps'
  is_allow
  run bare_hardhat 'docker logs nightshift'
  is_allow
  run bare_hardhat 'brew list'
  is_allow

  run bare_gate
  [ "$status" -eq 0 ]
  is_block "$output"
  [ ! -f "$p/.nightshift/.ended" ]
  [ -f "$p/.nightshift/.shift-armed" ]
}

# A punch list that exists but cannot be counted is not zero open work: the site stays armed.
@test "an uncountable punch list keeps the hardhat on" {
  p="$(new_project hardhat-uncountable)"
  punch_open "$p"
  chmod 000 "$p/.nightshift/punch-list.md"
  run hardhat_bash "$p" '/usr/bin/sudo id'
  chmod 644 "$p/.nightshift/punch-list.md"
  [ "$status" -eq 0 ]
  is_deny "$output"
}
