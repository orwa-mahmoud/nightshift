#!/usr/bin/env bats
# Strict-subset reader for rules.json — no jq or python3 on the arm/deny path.

bats_require_minimum_version 1.5.0

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
LIB="$ROOT/plugins/nightshift/lib/lib.sh"
TEMPLATE="$ROOT/plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json"
START="$ROOT/plugins/nightshift/skills/start/SKILL.md"
DOCTOR="$ROOT/plugins/nightshift/runtime/doctor.sh"
STATUS="$ROOT/plugins/nightshift/runtime/status.sh"
HOOKS="$ROOT/plugins/nightshift/hooks"

no_json_bin() {
  build_toolset_bin "$1" bash sh sed tr sort grep cut awk cat mktemp uname date \
    rm mv cp ln printf head tail wc find test dirname basename cksum env true false
}

@test "the shipped template is the accepted shape" {
  run bash -c '. "$1"; ns_rules_load "$2" && rule "$3" watchMinutes "" && printf x' \
    _ "$LIB" "$TEMPLATE" "$(dirname "$TEMPLATE")/../.."
  # rule() wants workspace/.nightshift/rules.json — load the template path directly.
  run bash -c '. "$1"; ns_rules_load "$2" && ns_rules_get "$2" watchMinutes' _ "$LIB" "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" = 10 ]
  run bash -c '. "$1"; ns_rules_load "$2" && ns_rules_get "$2" receiptsAutoCommit' _ "$LIB" "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" = false ]
  run bash -c '. "$1"; ns_rules_tool_state "$2" AskUserQuestion' _ "$LIB" "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" = deny ]
}

@test "comments, trailing commas, unknown types, and unexpected nesting fail closed" {
  dir="$BATS_TEST_TMPDIR/bad"
  mkdir -p "$dir"
  printf '{ "watchMinutes": 10, }\n' >"$dir/trailing.json"
  printf '{ "watchMinutes": 10 }\n// comment\n' >"$dir/comment.json"
  printf '{ "watchMinutes": null }\n' >"$dir/null.json"
  printf '{ "watchMinutes": 1.5 }\n' >"$dir/float.json"
  printf '{ "elevation": { "sudo": "deny" } }\n' >"$dir/nest.json"
  printf '{not json\n' >"$dir/broken.json"

  reject() {
    run bash -c '. "$1"; ns_rules_load "$2" && exit 0; printf "%s\n" "$NS_RULES_ERR"; exit 1' \
      _ "$LIB" "$1"
  }
  reject "$dir/trailing.json"
  [ "$status" -eq 1 ]
  [ "$output" = "trailing comma" ]

  reject "$dir/comment.json"
  [ "$status" -eq 1 ]
  [ "$output" = comment ]

  reject "$dir/null.json"
  [ "$status" -eq 1 ]
  [ "$output" = "unknown type" ]

  reject "$dir/float.json"
  [ "$status" -eq 1 ]
  [ "$output" = "unknown type" ]

  reject "$dir/nest.json"
  [ "$status" -eq 1 ]
  [ "$output" = "unexpected nesting" ]

  reject "$dir/broken.json"
  [ "$status" -eq 1 ]
  [ "$output" = "not a JSON object" ]
}

@test "Start can resolve rules and hardhat can deny sudo without jq or python3" {
  p="$(new_project rules-nojq)"
  punch_open "$p"
  bin="$(no_json_bin rules-nojq-bin)"
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash -c '. "$1"; ns_policy_resolve_table "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'watchMinutes=10 (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'elevation.sudo=deny (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'verificationLevel=none (built-in, -)'
  if printf '%s\n' "$output" | grep -qF 'jq or python3'; then
    return 1
  fi

  out="$(jq -nc --arg c 'sudo id' '{tool_name:"Bash",tool_input:{command:$c}}' |
    env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
      CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
  printf '%s' "$out" | grep -qF "needs allowance: sudo"
  if printf '%s' "$out" | grep -qF 'jq or python3'; then
    return 1
  fi
}

@test "malformed rules refuse to arm with a named reason" {
  p="$(new_project rules-malformed)"
  printf '{ "watchMinutes": 10, }\n' >"$p/.nightshift/rules.json"
  bin="$(no_json_bin rules-malformed-bin)"
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash -c '. "$1"; ns_rules_check "$2"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  [ "$output" = "trailing comma" ]

  grep -qF 'ns_rules_check' "$START"
  grep -qF 'refuse to arm' "$START"
  grep -qF 'named reason' "$START"
  if grep -qF 'install jq or python3' "$START"; then
    return 1
  fi
  if grep -qiE '\bawk\b' "$START"; then
    return 1
  fi
}

@test "Doctor and Status never ask to install jq or python3" {
  if grep -qF 'install jq or python3' "$DOCTOR"; then
    return 1
  fi
  if grep -qF 'jq or python3 required' "$STATUS"; then
    return 1
  fi
  p="$(new_project rules-doctor)"
  punch_open "$p"
  bin="$(no_json_bin rules-doctor-bin)"
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'rules.json is a JSON object'
  printf '%s' "$output" | grep -qF 'watchMinutes=10 (rules, permanent)'
  if printf '%s' "$output" | grep -qF 'jq or python3'; then
    return 1
  fi
}

@test "the reader agrees on the default awk and on gawk when present" {
  p="$(new_project rules-awk)"
  cp "$TEMPLATE" "$p/.nightshift/rules.json"
  def="$(bash -c '. "$1"; ns_rules_facts "$2/.nightshift/rules.json"' _ "$LIB" "$p")"
  [ -n "$def" ]
  printf '%s\n' "$def" | grep -q $'^r\twatchMinutes\t1\t10$'
  if command -v gawk >/dev/null 2>&1; then
    gawk_out="$(env NS_RULES_AWK=gawk bash -c '. "$1"; ns_rules_facts "$2/.nightshift/rules.json"' _ "$LIB" "$p")"
    [ "$def" = "$gawk_out" ]
    env NS_RULES_AWK=gawk bash -c '
      . "$1"
      printf "{ \"watchMinutes\": 10, }\n" >"$2/bad.json"
      ns_rules_load "$2/bad.json"
      printf "%s\n" "$NS_RULES_ERR"
    ' _ "$LIB" "$BATS_TEST_TMPDIR" | grep -qxF 'trailing comma'
  fi
}

@test "owner-facing docs never name the reader implementation" {
  if grep -qiE '\bawk\b' "$ROOT/docs/how-it-works.md"; then
    return 1
  fi
  if grep -qiE '\bawk\b' "$ROOT/docs/knobs.md"; then
    return 1
  fi
  if grep -qiE '\bawk\b' "$START"; then
    return 1
  fi
  if grep -qiE '\bawk\b' "$ROOT/plugins/nightshift/skills/doctor/SKILL.md"; then
    return 1
  fi
  if grep -qiE '\bawk\b' "$ROOT/plugins/nightshift/skills/status/SKILL.md"; then
    return 1
  fi
}

# The three settings blocks are one level of named values: a string, an integer, a bool, a null,
# or a string array. The reader carries every one of them, because a field it quietly skipped
# would read as a setting the owner never wrote.
@test "the settings blocks read back exactly as written" {
  run bash -c '. "$1"; ns_rules_get "$2" shift' _ "$LIB" "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" = '{"verificationProfile":"fast","hours":null,"execution":"review-first","toolingPolicy":"existing-tools"}' ]
  run bash -c '. "$1"; ns_rules_get "$2" handoff' _ "$LIB" "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" = '{"enabled":true,"view":"owner","language":"auto","detail":"concise","sections":[],"templatePath":""}' ]
  run bash -c '. "$1"; ns_rules_get "$2" archive' _ "$LIB" "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$output" = '{"automatic":false,"root":"archive","layout":"date","templatePath":""}' ]
}

@test "one field of a settings block reads on its own" {
  run bash -c '. "$1"; ns_rules_get_in "$2" shift verificationProfile' _ "$LIB" "$TEMPLATE"
  [ "$output" = fast ]
  run bash -c '. "$1"; ns_rules_get_in "$2" shift hours' _ "$LIB" "$TEMPLATE"
  [ "$output" = null ]
  run bash -c '. "$1"; ns_rules_get_in "$2" handoff enabled' _ "$LIB" "$TEMPLATE"
  [ "$output" = true ]
  run bash -c '. "$1"; ns_rules_get_in "$2" handoff sections' _ "$LIB" "$TEMPLATE"
  [ "$output" = '[]' ]
  run bash -c '. "$1"; ns_rules_get_in "$2" archive root' _ "$LIB" "$TEMPLATE"
  [ "$output" = archive ]
  # A field nobody wrote reads as nothing, never as a guess.
  run bash -c '. "$1"; ns_rules_get_in "$2" handoff nosuchfield' _ "$LIB" "$TEMPLATE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a populated section list and an owner value survive the round trip" {
  f="$BATS_TEST_TMPDIR/populated.json"
  printf '%s\n' '{"toolDeny":{"AskUserQuestion":"","request_user_input":"","AskQuestion":""},"shift":{"verificationProfile":"strict","hours":6},"handoff":{"sections":["shift","changed","next"],"language":"de"}}' >"$f"
  run bash -c '. "$1"; ns_rules_get_in "$2" handoff sections' _ "$LIB" "$f"
  [ "$output" = '["shift","changed","next"]' ]
  run bash -c '. "$1"; ns_rules_get_in "$2" shift hours' _ "$LIB" "$f"
  [ "$output" = 6 ]
  run bash -c '. "$1"; ns_rules_get_in "$2" handoff language' _ "$LIB" "$f"
  [ "$output" = de ]
  run bash -c '. "$1"; ns_rules_get "$2" shift' _ "$LIB" "$f"
  [ "$output" = '{"verificationProfile":"strict","hours":6}' ]
}

@test "a settings block still refuses a shape the schema does not describe" {
  d="$BATS_TEST_TMPDIR/deep"
  mkdir -p "$d/.nightshift"
  base='{"toolDeny":{"AskUserQuestion":"","request_user_input":"","AskQuestion":""},'
  printf '%s\n' "$base"'"handoff":{"view":{"nested":"deeper"}}}' >"$d/.nightshift/deep.json"
  run bash -c '. "$1"; ns_rules_load "$2"' _ "$LIB" "$d/.nightshift/deep.json"
  [ "$status" -ne 0 ]
  printf '%s\n' "$base"'"handoff":{"sections":[["nested"]]}}' >"$d/.nightshift/arr.json"
  run bash -c '. "$1"; ns_rules_load "$2"' _ "$LIB" "$d/.nightshift/arr.json"
  [ "$status" -ne 0 ]
  printf '%s\n' "$base"'"shift":{"hours":nul}}' >"$d/.nightshift/nul.json"
  run bash -c '. "$1"; ns_rules_load "$2"' _ "$LIB" "$d/.nightshift/nul.json"
  [ "$status" -ne 0 ]
}
