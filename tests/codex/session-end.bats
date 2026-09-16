load ../helpers

HOOKS="$BATS_TEST_DIRNAME/../../plugins/nightshift/hooks"
CODEX_HOOKS="$HOOKS/codex"

codex_session_end() {
  local p="$1" sid="$2" reason="${3:-other}"
  hook_payload "$(jq -nc --arg p "$p" --arg sid "$sid" --arg reason "$reason" \
    '{session_id:$sid,cwd:$p,reason:$reason}')" \
    env CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/session-end.sh"
}

@test "codex session-end writes the marker only for the bound session" {
  p="$(new_project)"
  punch_open "$p"
  printf 'right-id\n\n\n\ncodex\n' >"$p/.nightshift/.shift-session"
  codex_session_end "$p" wrong-id other
  [ ! -f "$p/.nightshift/.session-end" ]
  codex_session_end "$p" right-id other
  grep -q 'clean session end (other)' "$p/.nightshift/.session-end"
}

@test "codex session-end is a no-op for a watchman revival" {
  p="$(new_project)"
  punch_open "$p"
  printf 'right-id\n\n\n\ncodex\n' >"$p/.nightshift/.shift-session"
  jq -nc --arg p "$p" '{session_id:"right-id",cwd:$p,reason:"other"}' |
    env CODEX_PROJECT_DIR="$p" NIGHTSHIFT_REVIVAL=1 bash "$CODEX_HOOKS/session-end.sh"
  [ ! -f "$p/.nightshift/.session-end" ]
}

@test "codex session-end records reason other even without a payload reason" {
  p="$(new_project)"
  punch_open "$p"
  printf 'right-id\n\n\n\ncodex\n' >"$p/.nightshift/.shift-session"
  jq -nc --arg p "$p" '{session_id:"right-id",cwd:$p}' |
    env CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/session-end.sh"
  grep -q 'clean session end (other)' "$p/.nightshift/.session-end"
}
