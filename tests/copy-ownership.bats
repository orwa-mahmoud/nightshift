#!/usr/bin/env bats
# A plugin copy answers only the host that installed it. A checkout still serves every host.

bats_require_minimum_version 1.5.0

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
NS_BIN="$PLUGIN/runtime/ns"
LIB="$PLUGIN/lib/lib.sh"

# host_env <home> command… — drop every host variable this shell may have inherited.
host_env() {
  local home="$1"
  shift
  env -u NIGHTSHIFT_HOST -u NIGHTSHIFT_WORKSPACE \
    -u CLAUDE_PROJECT_DIR -u CLAUDECODE -u CLAUDE_PLUGIN_ROOT \
    -u CODEX_PROJECT_DIR -u CODEX_HOME -u CODEX_SANDBOX -u CODEX_SANDBOX_MODE \
    -u CURSOR_PROJECT_DIR -u CURSOR_PLUGIN_ROOT -u CURSOR_TRACE_ID \
    -u CURSOR_AGENT -u CURSOR_VERSION -u CURSOR_CONVERSATION_ID \
    "HOME=$home" "$@"
}

@test "the installing host is the profile plugins directory, and a checkout serves every host" {
  home="$BATS_TEST_TMPDIR/home-markers"
  mkdir -p "$home/.claude/plugins/cache/ns" \
    "$home/.cursor/plugins/local/ns" \
    "$home/.codex/plugins/cache/m/ns/1" \
    "$home/.claude/plugins-extra/ns" \
    "$BATS_TEST_TMPDIR/checkout"
  run host_env "$home" bash -c '
    . "$1"
    printf "%s\n" \
      "$(ns_installing_host "$2")" \
      "$(ns_installing_host "$3")" \
      "$(ns_installing_host "$4")" \
      "$(ns_installing_host "$5")" \
      "$(ns_installing_host "$6")"
  ' _ "$LIB" \
    "$home/.claude/plugins/cache/ns" \
    "$home/.cursor/plugins/local/ns" \
    "$home/.codex/plugins/cache/m/ns/1" \
    "$home/.claude/plugins-extra/ns" \
    "$BATS_TEST_TMPDIR/checkout"
  [ "$status" -eq 0 ]
  [ "$output" = $'claude\ncursor\ncodex\nany\nany' ]
}

@test "ns bind reports cursor when the environment also carries CLAUDE_* variables" {
  p="$(new_project own-bind-cursor)"
  run host_env "$HOME" bash -c 'cd "$1" && CURSOR_AGENT=1 CLAUDE_PROJECT_DIR="$1" CLAUDECODE=1 "$2" bind' \
    _ "$p" "$NS_BIN"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'HOST	cursor'
}

@test "each installed copy answers only its own host" {
  home="$BATS_TEST_TMPDIR/home-copies"
  mkdir -p "$home/.claude/plugins" "$home/.cursor/plugins" "$home/.codex/plugins"
  cp -R "$PLUGIN" "$home/.claude/plugins/nightshift"
  cp -R "$PLUGIN" "$home/.cursor/plugins/nightshift"
  cp -R "$PLUGIN" "$home/.cursor/plugins/nightshift-extra"
  cp -R "$PLUGIN" "$home/.codex/plugins/nightshift"
  claude_root="$(cd -P "$home/.claude/plugins/nightshift" && pwd)"
  cursor_root="$(cd -P "$home/.cursor/plugins/nightshift" && pwd)"
  cursor_extra="$(cd -P "$home/.cursor/plugins/nightshift-extra" && pwd)"
  codex_root="$(cd -P "$home/.codex/plugins/nightshift" && pwd)"
  p="$(new_project own-copies)"
  copies="$(bash -c '. "$1"; ns_layout_path "$2/.nightshift" hook-copies' _ "$LIB" "$p")"
  payload="$(jq -nc --arg w "$p" \
    '{conversation_id:"sess-own",session_id:"sess-own",cwd:$w,tool_name:"Shell",tool_input:{command:"true"},prompt:"hello",status:"completed",reason:"completed"}')"

  for hook in hardhat.sh pulse.sh clock-out-gate.sh session-end.sh before-submit.sh; do
    rm -f "$copies"
    run hook_payload "$payload" host_env "$home" \
      env CURSOR_PROJECT_DIR="$p" CLAUDE_PROJECT_DIR="$p" \
      bash "$claude_root/hooks/cursor/$hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$copies" ]

    run hook_payload "$payload" host_env "$home" \
      env CURSOR_PROJECT_DIR="$p" CLAUDE_PROJECT_DIR="$p" \
      bash "$cursor_root/hooks/cursor/$hook"
    [ "$status" -eq 0 ]
    [ -f "$copies" ]
    roots="$(awk -F '\t' '{print $4}' "$copies" | sort -u)"
    [ "$roots" = "$cursor_root" ]
  done

  printf '%s\n/tmp/t.jsonl\n\n\ncursor\n' sess-own >"$p/.nightshift/.shift-session"
  : >"$p/.nightshift/.shift-armed"
  run host_env "$home" env CURSOR_AGENT=1 CLAUDE_PROJECT_DIR="$p" \
    bash "$cursor_root/runtime/start-preflight.sh" --project "$p" --phase bind
  [ "$status" -eq 0 ]

  run hook_payload "$payload" host_env "$home" \
    env CURSOR_PROJECT_DIR="$p" CLAUDE_PROJECT_DIR="$p" \
    bash "$cursor_extra/hooks/cursor/hardhat.sh"
  run host_env "$home" env CURSOR_AGENT=1 CLAUDE_PROJECT_DIR="$p" \
    bash "$cursor_root/runtime/start-preflight.sh" --project "$p" --phase bind
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'refuse copies 2'

  rm -f "$copies" "$p/.nightshift/.shift-session"
  claude_payload="$(jq -nc --arg w "$p" \
    '{session_id:"sess-own",cwd:$w,tool_name:"Bash",tool_input:{command:"true"}}')"
  run hook_payload "$claude_payload" host_env "$home" \
    env CLAUDE_PROJECT_DIR="$p" bash "$cursor_root/hooks/hardhat.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$copies" ]
  run hook_payload "$claude_payload" host_env "$home" \
    env CLAUDE_PROJECT_DIR="$p" bash "$claude_root/hooks/hardhat.sh"
  [ -f "$copies" ]
  [ "$(awk -F '\t' '{print $4}' "$copies" | sort -u)" = "$claude_root" ]

  rm -f "$copies"
  codex_payload="$(jq -nc --arg w "$p" \
    '{session_id:"sess-own",cwd:$w,tool_name:"Bash",tool_input:{command:"true"}}')"
  run hook_payload "$codex_payload" host_env "$home" \
    env CODEX_PROJECT_DIR="$p" bash "$claude_root/hooks/codex/hardhat.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$copies" ]
  run hook_payload "$codex_payload" host_env "$home" \
    env CODEX_PROJECT_DIR="$p" bash "$codex_root/hooks/codex/hardhat.sh"
  [ -f "$copies" ]
  [ "$(awk -F '\t' '{print $4}' "$copies" | sort -u)" = "$codex_root" ]

  rm -f "$copies"
  run hook_payload "$payload" host_env "$home" \
    env CURSOR_PROJECT_DIR="$p" bash "$PLUGIN/hooks/cursor/hardhat.sh"
  [ -f "$copies" ]
  [ "$(awk -F '\t' '{print $4}' "$copies" | sort -u)" = "$(cd -P "$PLUGIN" && pwd)" ]

  run host_env "$home" env CURSOR_AGENT=1 CLAUDE_PROJECT_DIR="$p" CLAUDECODE=1 \
    bash "$claude_root/runtime/ns" start-preflight --project "$p" --host cursor
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF "refuse ownership this copy was installed for claude ($claude_root); this session is cursor"
  printf '%s\n' "$output" | grep -qF "repair Use the copy installed for cursor, under the user profile's .cursor/plugins directory."

  run host_env "$home" env CURSOR_AGENT=1 CLAUDE_PROJECT_DIR="$p" \
    bash "$claude_root/runtime/ns" help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'host cursor'
  ! printf '%s\n' "$output" | grep -qF 'refuse ownership' || false

  verbs="$(host_env "$home" env CURSOR_AGENT=1 CLAUDE_PROJECT_DIR="$p" \
    bash "$claude_root/runtime/ns" help | awk 'NR>2 && $1 ~ /^[a-z0-9-]+$/ && $1 != "ns" {print $1}')"
  [ -n "$verbs" ]
  for verb in $verbs; do
    case " help bind path status doctor " in
      *" $verb "*)
        run host_env "$home" env CURSOR_AGENT=1 CLAUDE_PROJECT_DIR="$p" \
          bash "$claude_root/runtime/ns" "$verb"
        ! printf '%s\n' "$output" | grep -qF 'refuse ownership' || {
          echo "read-only verb refused: $verb"; return 1
        }
        ;;
      *)
        run host_env "$home" env CURSOR_AGENT=1 CLAUDE_PROJECT_DIR="$p" \
          bash "$claude_root/runtime/ns" "$verb"
        [ "$status" -eq 2 ]
        printf '%s\n' "$output" | grep -qF 'refuse ownership' || {
          echo "state-changing verb did not refuse: $verb"; return 1
        }
        ;;
    esac
  done

  run host_env "$home" env CURSOR_AGENT=1 CLAUDE_PROJECT_DIR="$p" \
    bash "$cursor_root/runtime/ns" bind
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'HOST	cursor'

  run host_env "$home" bash "$claude_root/runtime/start-watchman.sh" --project "$p" --host cursor
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'refuse ownership'
  run host_env "$home" bash "$claude_root/runtime/cursor/watchman.sh" --project "$p" --interval 0 --max-wakes 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
