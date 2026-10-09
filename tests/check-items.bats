#!/usr/bin/env bats
# Checking drafted items before promotion: the shape of the plan, never the work behind a tick.
# Every finding names its item, and the check refuses nothing.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
CHECK="$PLUGIN/runtime/check-items.sh"
FIX="$BATS_TEST_DIRNAME/fixtures/check-items"

@test "a well-formed drafting table reads ok, and the template example above the rule is never read" {
  run bash "$CHECK" --project "$BATS_TEST_TMPDIR" --file "$FIX/well-formed.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat <<'EOF'
**1. Load one TOML file.**: ok
**2. Drop the environment overrides.**: ok
checked 2 items: 0 with findings
EOF
)" ] || { printf '%s\n' "$output"; return 1; }
}

@test "each defect is named against its item, and a box no item owns is named by line" {
  run bash "$CHECK" --project "$BATS_TEST_TMPDIR" --file "$FIX/defects.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat <<'EOF'
**1. No verify line.**: no Verify: line
**2. A verify line that checks nothing.**: Verify: names no command and no WHEN/THEN scenario
**3. No commit line.**: no Commit: line
**4. A budget that does not parse.**: Budget: does not parse (about an hour)
**5. A nested checkbox.**: line 23: a nested checkbox; only the item line may be a box
line 26: a checkbox outside an item line counts as an open item
line 29: a checkbox outside an item line counts as an open item
checked 5 items: 5 with findings, 2 stray checkboxes
EOF
)" ] || { printf '%s\n' "$output"; return 1; }
}

@test "a punch list is read under its Items heading only, and a receipt stands in for a commit" {
  run bash "$CHECK" --project "$BATS_TEST_TMPDIR" --file "$FIX/mixed.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat <<'EOF'
**1. Ship the site.**: ok
**2. Write the about page.**: no Commit: line
checked 2 items: 1 with findings
EOF
)" ] || { printf '%s\n' "$output"; return 1; }
}

@test "with no file named it checks the workspace's drafting table, through the dispatcher, and changes nothing" {
  p="$(new_project dispatch)"
  printf '2\n' >"$p/.nightshift/state-version"
  mkdir -p "$p/.nightshift/staging"
  cp "$FIX/defects.md" "$p/.nightshift/staging/drafting-table.md"
  before="$(cksum "$p/.nightshift/staging/drafting-table.md")"
  run env -u CLAUDE_PROJECT_DIR NIGHTSHIFT_HOST=claude bash -c 'cd "$1" && "$2" check-items' _ "$p" "$PLUGIN/runtime/ns"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF '**1. No verify line.**: no Verify: line'
  [ "$(cksum "$p/.nightshift/staging/drafting-table.md")" = "$before" ]
  q="$(new_project nothing)"
  run bash "$CHECK" --project "$q"
  [ "$status" -eq 0 ]
  [[ "$output" == 'no items to check'* ]]
}

@test "the plan room may run it, and Start arms a list it would flag" {
  p="$(new_project room)"
  rm -f "$p/.nightshift/.shift-armed"
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" >/dev/null
  hook_payload '{"tool_name":"Bash","session_id":"planner","tool_input":{"command":": nightshift-plan-probe"}}' \
    env CLAUDE_PROJECT_DIR="$p" bash "$PLUGIN/hooks/hardhat.sh" >/dev/null
  run hook_payload "$(jq -nc --arg c "\"$PLUGIN/runtime/ns\" check-items" '{tool_name:"Bash",session_id:"planner",tool_input:{command:$c}}')" \
    env CLAUDE_PROJECT_DIR="$p" bash "$PLUGIN/hooks/hardhat.sh"
  [ -z "$output" ] || { echo "$output"; return 1; }
  # An item check-items would flag still arms: the shape is the owner's call, never Start's.
  q="$(new_project start)"
  printf '## Items\n- [ ] **1. No verify and no commit.**\n' >"$q/.nightshift/punch-list.md"
  run bash "$PLUGIN/runtime/check-items.sh" --project "$q" --file "$q/.nightshift/punch-list.md"
  printf '%s\n' "$output" | grep -qxF '**1. No verify and no commit.**: no Verify: line'
  run bash "$PLUGIN/runtime/start-preflight.sh" --project "$q" --host claude
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "native Windows prints the same findings, and its suite is registered" {
  grep -qF 'check-items-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  for f in well-formed defects mixed; do
    want="$(bash "$CHECK" --project "$BATS_TEST_TMPDIR" --file "$FIX/$f.md")"
    got="$(pwsh -NoProfile -NonInteractive -File "$PLUGIN/runtime/windows/check-items.ps1" -Project "$BATS_TEST_TMPDIR" -File "$FIX/$f.md")"
    [ "$got" = "$want" ] || { echo "$f"; echo "bash:"; echo "$want"; echo "PowerShell:"; echo "$got"; return 1; }
  done
}
