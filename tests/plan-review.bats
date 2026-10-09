#!/usr/bin/env bats
# The morning review opens in the plan room: entering lists what the finished shift left for the
# owner, so the planning conversation walks them through it instead of searching for it.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

# finished <name> — a version-2 workspace whose shift has ended: one item ticked, one open, one
# stopped at its hard budget; a parked decision and a snag still open beside handled ones; the
# morning page and the receipts index.
finished() {
  local p ns
  p="$(new_project "$1")"
  ns="$p/.nightshift"
  printf '2\n' >"$ns/state-version"
  mkdir -p "$ns/run" "$ns/inbox" "$ns/receipts"
  mv "$ns/.shift-armed" "$ns/run/.shift-armed"
  printf 'shiftId=aaaa1111bbbb2222\narchiveRoot=archive\narchiveLayout=date\n' >"$ns/run/.ended"
  cat >"$ns/punch-list.md" <<'EOF'
## Items
- [x] **1. Parse the config.** <!-- id: aa11 -->
- [ ] **2. Cache the parse.** <!-- id: bb22 -->
  - Verify: the cache test
- [-] **3. Rewrite the loader.** <!-- id: cc33 -->
  - Stopped: hard 45m reached at 47m; wip commit 1a2b3c4
EOF
  cat >"$ns/inbox/parking-lot.md" <<'EOF'
# Parking Lot

---

- Keep the old flag name? · default: keep it · renaming breaks scripts
- Bump the minimum Node? · answered: yes, to 22
EOF
  cat >"$ns/inbox/snag-log.md" <<'EOF'
# Snag Log

---

- The loader retries forever on a missing file · seen in tests/loader.bats · 2026-10-09
- A typo in the help text · cli.sh · fixed · 2026-10-09
EOF
  printf '# Morning receipt\n' >"$ns/receipts/morning-2026-10-09-aaaa1111bbbb2222.md"
  printf '# Morning receipt\n' >"$ns/receipts/morning-2026-10-08-1111aaaa2222bbbb.md"
  printf '# Receipts\n' >"$ns/receipts/README.md"
  printf '%s' "$p"
}

@test "entering after a finished shift lists every open decision, snag and item, and the morning page" {
  p="$(finished review)"
  run bash "$PLUGIN/runtime/plan-enter.sh" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep '^review ')" = "$(cat <<'EOF'
review morning .nightshift/receipts/morning-2026-10-09-aaaa1111bbbb2222.md
review receipts .nightshift/receipts/README.md
review parked Keep the old flag name? · default: keep it · renaming breaks scripts
review snag The loader retries forever on a missing file · seen in tests/loader.bats · 2026-10-09
review open **2. Cache the parse.**
review stopped **3. Rewrite the loader.**
EOF
)" ] || { printf '%s\n' "$output"; return 1; }
}

@test "with no shift behind it the room is plain planning" {
  p="$(new_project plain)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '2\n' >"$p/.nightshift/state-version"
  bash "$PLUGIN/runtime/scaffold.sh" --project "$p" >/dev/null
  run bash "$PLUGIN/runtime/plan-enter.sh" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep '^review ')" = 'review none' ]
}

@test "a running shift's items are not put up for review" {
  p="$(finished running)"
  rm -f "$p/.nightshift/run/.ended"
  run lib ns_plan_review "$p/.nightshift"
  ! printf '%s\n' "$output" | grep -q '^review \(open\|stopped\) ' || false
  printf '%s\n' "$output" | grep -q '^review parked Keep the old flag name?'
}

@test "after Archive the review reads what it left live" {
  p="$(finished archived)"
  bash "$PLUGIN/runtime/archive-receipts.sh" --project "$p" --date 2026-10-09 >/dev/null 2>&1
  run lib ns_plan_review "$p/.nightshift"
  printf '%s\n' "$output" | grep -qxF 'review parked Keep the old flag name? · default: keep it · renaming breaks scripts'
  printf '%s\n' "$output" | grep -q '^review snag The loader retries forever'
  printf '%s\n' "$output" | grep -qxF 'review open **2. Cache the parse.**'
  printf '%s\n' "$output" | grep -qxF 'review stopped **3. Rewrite the loader.**'
  ! printf '%s\n' "$output" | grep -qF 'Bump the minimum Node' || false
  ! printf '%s\n' "$output" | grep -qF 'typo in the help text' || false
}

@test "the plan room records the owner's review decisions in the inbox, and nothing else outside staging" {
  p="$(finished decide)"
  rm -f "$p/.nightshift/run/.ended" "$p/.nightshift/run/.shift-armed"
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" >/dev/null
  claude() {
    hook_payload "$(printf '%s' "$2" | jq -c '. + {session_id:"planner"}')" \
      env CLAUDE_PROJECT_DIR="$1" bash "$PLUGIN/hooks/hardhat.sh"
  }
  claude "$p" '{"tool_name":"Bash","tool_input":{"command":": nightshift-plan-probe"}}' >/dev/null
  for f in inbox/parking-lot.md inbox/snag-log.md staging/drafting-table.md; do
    run claude "$p" "$(jq -nc --arg f "$p/.nightshift/$f" '{tool_name:"Edit",tool_input:{file_path:$f}}')"
    [ -z "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')" ] || { echo "$f: $output"; return 1; }
  done
  for f in punch-list.md rules.json receipts/README.md; do
    run claude "$p" "$(jq -nc --arg f "$p/.nightshift/$f" '{tool_name:"Edit",tool_input:{file_path:$f}}')"
    [ -n "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')" ] || { echo "$f was allowed"; return 1; }
  done
}

@test "the PowerShell half lists the same review and runs in the Windows suite" {
  grep -qF 'Get-NSPlanReview' "$BATS_TEST_DIRNAME/windows/plan-room-logic.ps1"
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  p="$(finished parity)"
  want="$(lib ns_plan_review "$p/.nightshift")"
  got="$(NS_MODULE="$PLUGIN/lib/Nightshift.psm1" NS_NS="$p/.nightshift" pwsh -NoProfile -NonInteractive -Command \
    'Import-Module $env:NS_MODULE -Force -DisableNameChecking; Get-NSPlanReview $env:NS_NS')"
  [ "$got" = "$want" ] || { echo "bash:"; echo "$want"; echo "PowerShell:"; echo "$got"; return 1; }
}
