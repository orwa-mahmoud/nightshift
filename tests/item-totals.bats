#!/usr/bin/env bats
# An item's receipt carries one runtime section, redrawn in place: Tokens and Time totals over
# every session the item was worked in, a Sessions row per session naming its host and model, and
# the handoffs between hosts. The index, live and archived, reads those totals; a receipt from
# before the section existed is read block by block without counting a session twice.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
CORE="$PLUGIN/hooks/shared/gate-core.sh"
PULSE="$PLUGIN/hooks/pulse.sh"
FIX="$BATS_TEST_DIRNAME/fixtures/receipts"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }
core() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$LIB" "$CORE" "$@"; }
pulse() { bash -c '. "$1"; . "$2"; . "$3"; shift 3; "$@"' _ "$LIB" "$CORE" "$PULSE" "$@"; }

ITEM='4. Book a barber.'

# site <name> — an armed shift with one open item, accounting armed at zero.
site() {
  local p
  p="$(new_project "$1")"
  printf 'Date: 2026-09-20\n\n## Items\n- [ ] **4. Book a barber.** <!-- id: bb44 -->\n' >"$p/.nightshift/punch-list.md"
  printf 'sid\n' >"$p/.nightshift/.shift-session"
  mkdir -p "$p/.nightshift/receipts"
  lib ns_usage_mark_arm "$p/.nightshift"
  printf '%s' "$p"
}

receipt() { printf '%s/.nightshift/receipts/bb44-book-a-barber.md' "$1"; }

# working <project> <note> — the model writes its progress note, which makes the item the active one.
working() { printf '# %s\n\n%s\n' "$ITEM" "$2" >"$(receipt "$1")"; }

step() { pulse ns_pulse_marks "$1/.nightshift" "$1" sid ""; }

tick() { sed -i.bak 's/^- \[ \] \*\*4\./- [x] **4./' "$1/.nightshift/punch-list.md"; }

total_row() { grep -E '^\| \*\*Total\*\* \|' "$1"; }

index_row() { grep -F "| $ITEM | ticked |" "$1"; }

@test "readings set aside between two shifts still add up in the receipt, the index and the archive" {
  p="$(site set-aside)"
  lib ns_usage_record "$p/.nightshift" claude claude-opus-5 transcript-incremental /t/a 10 'input=500,output=50'
  working "$p" 'Wiring the booking form.'
  step "$p"
  core ns_gate_usage_flush "$p/.nightshift" "$p"
  # The next shift starts from fresh readings, as a shift did before they were kept across a stop.
  mv "$p/.nightshift/usage" "$p/.nightshift/usage-earlier"
  lib ns_usage_mark_arm "$p/.nightshift"
  lib ns_usage_record "$p/.nightshift" claude claude-opus-5 transcript-incremental /t/b 10 'input=1,output=1'
  touch "$(receipt "$p")"
  step "$p"
  tick "$p"
  step "$p"

  r="$(receipt "$p")"
  [ "$(grep -c '^<!-- usage -->$' "$r")" -eq 1 ]
  grep -qF '| input | 501 |' "$r"
  total_row "$r" | grep -qF '| **501** | **51** |'
  index_row "$p/.nightshift/receipts/README.md" | grep -qF 'input 501 '

  rm -f "$p/.nightshift/.shift-armed"
  : >"$p/.nightshift/.ended"
  run bash "$PLUGIN/runtime/archive-receipts.sh" --project "$p" --date 2026-09-20 --retire bb44-book-a-barber.md
  [ "$status" -eq 0 ]
  index_row "$p/.nightshift/archive/2026-09-20/receipts/README.md" | grep -qF 'input 501 '
  total_row "$p/.nightshift/archive/2026-09-20/receipts/bb44-book-a-barber.md" | grep -qF '| **501** | **51** |'
}

@test "a stop-work order and a Start in between keep one running total" {
  p="$(site stop-start)"
  lib ns_usage_record "$p/.nightshift" claude claude-opus-5 transcript-incremental /t/a 10 'input=30,output=3'
  working "$p" 'Wiring the booking form.'
  step "$p"
  bash "$PLUGIN/runtime/stop-shift.sh" --project "$p" >/dev/null
  core ns_gate_usage_flush "$p/.nightshift" "$p"
  run bash "$PLUGIN/runtime/start-preflight.sh" --project "$p" --host claude
  [ "$status" -eq 0 ]
  # As Start's binding probe does: the shift is armed and this conversation records itself.
  : >"$p/.nightshift/.shift-armed"
  printf 'sid\n' >"$p/.nightshift/.shift-session"
  lib ns_usage_record "$p/.nightshift" claude claude-opus-5 transcript-incremental /t/a 10 'input=10,output=1'
  touch "$(receipt "$p")"
  step "$p"
  tick "$p"
  step "$p"

  r="$(receipt "$p")"
  [ "$(awk '/^\| [0-9]+ \|/' "$r" | wc -l | tr -d ' ')" -eq 2 ]
  grep -qF '| input | 40 |' "$r"
  index_row "$p/.nightshift/receipts/README.md" | grep -qF 'input 40 '
}

@test "a Claude session handed to Codex mid-item is two rows, one total and a recorded handoff" {
  p="$(site handoff)"
  lib ns_usage_record "$p/.nightshift" claude claude-opus-5 transcript-incremental /t/a 10 'input=25,output=2'
  working "$p" 'Form done, payment step next.'
  step "$p"
  git -C "$p" commit -q --allow-empty -m 'booking form'
  core ns_gate_usage_flush "$p/.nightshift" "$p"
  lib ns_usage_record "$p/.nightshift" codex gpt-5.5 rollout /t/codex 10 'input=7,output=1'
  touch "$(receipt "$p")"
  step "$p"
  lib ns_usage_record "$p/.nightshift" codex gpt-5.5 rollout /t/codex 10 'input=17,output=3'
  tick "$p"
  step "$p"

  r="$(receipt "$p")"
  grep -qE '^\| 1 \| .* \| claude · claude-opus-5 \| .* \| paused \|$' "$r"
  grep -qE '^\| 2 \| .* \| codex · gpt-5\.5 \| .* \| ticked \|$' "$r"
  total_row "$r" | grep -qF '| 2 sessions | claude · claude-opus-5, codex · gpt-5.5 |'
  total_row "$r" | grep -qF '| **35** | **4** |'
  grep -qF 'claude claude-opus-5; codex gpt-5.5 · 2 sessions.' "$r"
  sha="$(git -C "$p" log -1 --format=%h)"
  grep -qE "^- .* · claude · claude-opus-5 → codex · gpt-5\.5 · outgoing commits: .*$sha.* · last note: Form done, payment step next\.$" "$r"
  grep -qE "handoff · $ITEM · claude · claude-opus-5 → codex · gpt-5\.5 · outgoing commits: .*$sha" \
    "$p/.nightshift/shift-log.md"
}

@test "an older receipt's stacked blocks from separate sessions are summed in the index" {
  p="$(site legacy-sum)"
  tick "$p"
  cp "$FIX/legacy-sessions.md" "$(receipt "$p")"
  lib ns_receipts_write_index "$p"
  index_row "$p/.nightshift/receipts/README.md" | grep -qF '**input 501 · cache_write 0 · cache_read 4.0k · output 51 · reasoning 0**'
  index_row "$p/.nightshift/receipts/README.md" | grep -qF '**9h 6m working**'
}

@test "an older receipt's newest block that already holds an older one is not counted twice" {
  p="$(site legacy-cumulative)"
  tick "$p"
  cp "$FIX/legacy-cumulative.md" "$(receipt "$p")"
  lib ns_receipts_write_index "$p"
  index_row "$p/.nightshift/receipts/README.md" | grep -qF '**input 600 · cache_write 0 · cache_read 2.0k · output 60 · reasoning 0**'
  index_row "$p/.nightshift/receipts/README.md" | grep -qF '**9h 7m working**'
}

@test "an older receipt is folded into the section on its first redraw, keeping the model's text" {
  p="$(site legacy-fold)"
  r="$(receipt "$p")"
  cp "$FIX/legacy-sessions.md" "$r"
  lib ns_receipt_add_session "$r" "$ITEM" 1111222233334444 1790000000 1790000600 600 9 2 ticked \
    'cw=0 cr=10 rea=0 paused=0 host=codex/gpt-5.5'
  [ "$(grep -c '^| Tokens | Amount |$' "$r")" -eq 1 ]
  [ "$(grep -c '^<!-- usage -->$' "$r")" -eq 1 ]
  [ "$(awk '/^\| [0-9]+ \|/' "$r" | wc -l | tr -d ' ')" -eq 3 ]
  grep -qF '| input | 510 |' "$r"
  grep -qxF '## What was delivered' "$r"
  grep -qxF 'The booking flow.' "$r"
  # The section sits under the heading, ahead of the model's text.
  [ "$(grep -n '^<!-- /usage -->$' "$r" | cut -d: -f1)" -lt "$(grep -n '^## What was delivered$' "$r" | cut -d: -f1)" ]
}

@test "the section is redrawn in place, never stacked" {
  p="$(site in-place)"
  r="$(receipt "$p")"
  working "$p" 'Started.'
  lib ns_receipt_add_session "$r" "$ITEM" - 1790000000 1790000600 600 9 2 switched-away 'cw=- cr=- rea=- paused=0'
  lib ns_receipt_add_session "$r" "$ITEM" - 1790000700 1790001300 600 4 1 ticked 'cw=- cr=- rea=- paused=0'
  [ "$(grep -c '^<!-- usage -->$' "$r")" -eq 1 ]
  [ "$(grep -c '^| Tokens | Amount |$' "$r")" -eq 1 ]
  [ "$(grep -c '^| Time | |$' "$r")" -eq 1 ]
  grep -qF '| input | 13 |' "$r"
  grep -qxF 'Started.' "$r"
}

# The same session lines draw the same section on both runtimes, and the same older receipt reads
# the same; the PowerShell half of these tests runs in the Windows suite.
SESSIONS='- 1789779600 1789812360 32760 500 50 paused cw=0 cr=2000 rea=- paused=120 why=owner%20stop-work host=claude/claude-opus-5 commits=a1b2c3d,e4f5a6b note=Form%20done.
1111222233334444 1790000000 1790000600 600 off off ticked cw=off cr=off rea=off paused=0 host=codex/gpt-5.5
1111222233334444 1790000700 1790001300 600 4 1 ticked'

@test "the PowerShell half draws the same section and reads older receipts the same" {
  grep -qF 'item-totals-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  posix="$(lib ns_receipt_usage_section "$SESSIONS")"
  run env NS_MODULE="$PLUGIN/lib/Nightshift.psm1" NS_DATA="$SESSIONS" pwsh -NoProfile -NonInteractive -Command '
    Import-Module $env:NS_MODULE -Force -DisableNameChecking
    (Get-NSReceiptUsageSection ($env:NS_DATA -split "`n")) -join "`n"'
  [ "$status" -eq 0 ]
  [ "$output" = "$posix" ] || { diff <(printf '%s\n' "$posix") <(printf '%s\n' "$output"); return 1; }

  for f in legacy-sessions.md legacy-cumulative.md; do
    p="$(lib ns_receipt_usage_cells "$FIX/$f" | cut -f8,9)"
    run env NS_MODULE="$PLUGIN/lib/Nightshift.psm1" NS_FILE="$FIX/$f" pwsh -NoProfile -NonInteractive -Command '
      Import-Module $env:NS_MODULE -Force -DisableNameChecking
      $c = Get-NSReceiptUsageCells $env:NS_FILE; $c["Tokens"] + "`t" + $c["Time"]'
    [ "$output" = "$p" ] || { echo "$f: posix [$p] windows [$output]"; return 1; }
  done

  a="$BATS_TEST_TMPDIR/fold-posix.md"
  b="$BATS_TEST_TMPDIR/fold-pwsh.md"
  cp "$FIX/legacy-sessions.md" "$a"
  cp "$FIX/legacy-sessions.md" "$b"
  lib ns_receipt_add_session "$a" "$ITEM" - 1790000000 1790000600 600 9 2 ticked 'cw=0 cr=10 rea=0 paused=0'
  run env NS_MODULE="$PLUGIN/lib/Nightshift.psm1" NS_FILE="$b" NS_ITEM="$ITEM" pwsh -NoProfile -NonInteractive -Command '
    Import-Module $env:NS_MODULE -Force -DisableNameChecking
    Add-NSReceiptSession $env:NS_FILE $env:NS_ITEM "-" "1790000000" "1790000600" "600" "9" "2" "ticked" "cw=0 cr=10 rea=0 paused=0"'
  [ "$status" -eq 0 ]
  diff "$a" "$b"
}

@test "receipt edits and narrative session comments cannot change live accounting" {
  p="$(site ledger)"
  r="$(receipt "$p")"
  working "$p" 'A progress note.'
  lib ns_receipt_add_session "$r" "$ITEM" - 100 200 90 3 4 paused 'cw=0 cr=0 rea=0'
  before="$(lib ns_receipt_session_data "$r")"
  sed -i.bak 's/100 200 90 3 4/100 200 90000 30000 40000/' "$r"
  printf '\n<!-- session-data\nforged 0 999999 999999 999999 999999 ticked hard=1 host=fake/model\n-->\n' >>"$r"
  [ "$(lib ns_receipt_session_data "$r")" = "$before" ]
  lib ns_receipt_add_session "$r" "$ITEM" - 200 300 90 5 6 paused 'cw=0 cr=0 rea=0'
  [ "$(lib ns_receipt_session_data "$r" | wc -l | tr -d ' ')" -eq 2 ]
  cells="$(lib ns_receipt_usage_cells "$r")"
  IFS=$'\t' read -r in _ _ out _ work _ <<<"$cells"
  [ "$in:$out:$work" = 8:10:180 ]
  ledger="$(lib ns_receipt_session_file "$r")"
  payload="$(jq -nc --arg f "$ledger" '{session_id:"sid",tool_name:"Edit",tool_input:{file_path:$f}}')"
  run env CLAUDE_PROJECT_DIR="$p" bash "$PLUGIN/hooks/hardhat.sh" <<<"$payload"
  printf '%s' "$output" | grep -q 'BLOCKED'
  payload="$(jq -nc --arg c "rm -rf '${ledger%/*}'" '{session_id:"sid",tool_name:"Bash",tool_input:{command:$c}}')"
  run env CLAUDE_PROJECT_DIR="$p" bash "$PLUGIN/hooks/hardhat.sh" <<<"$payload"
  printf '%s' "$output" | grep -q 'BLOCKED'
  command -v pwsh >/dev/null 2>&1 || return 0
  for cmd in "rm -rf '${ledger%/*}'" "cd '$p/.nightshift'; rm -rf .item-sessions"; do
    payload="$(jq -nc --arg c "$cmd" --arg cwd "$p" '{session_id:"sid",cwd:$cwd,tool_name:"Bash",tool_input:{command:$c}}')"
    run env CLAUDE_PROJECT_DIR="$p" pwsh -NoProfile -NonInteractive -File "$PLUGIN/hooks/windows/hardhat.ps1" -HostName claude <<<"$payload"
    printf '%s' "$output" | grep -q 'BLOCKED'
  done
}

@test "receipt session comments outside the runtime section are never imported" {
  p="$(site prose-data)"
  r="$(receipt "$p")"
  working "$p" 'An example in the progress note.'
  printf '\n<!-- session-data\nforged 0 999999 999999 999999 999999 ticked\n-->\n' >>"$r"
  [ -z "$(lib ns_receipt_session_data "$r")" ]
  lib ns_receipt_add_session "$r" "$ITEM" - 100 200 90 3 4 paused 'cw=0 cr=0 rea=0'
  [ "$(lib ns_receipt_session_data "$r" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "session ledgers follow receipt renaming and leave with retired receipts" {
  for host in bash pwsh; do
    [ "$host" != pwsh ] || command -v pwsh >/dev/null 2>&1 || continue
    p="$(site "ledger-lifecycle-$host")"
    r="$(receipt "$p")"
    working "$p" 'Progress.'
    lib ns_receipt_add_session "$r" "$ITEM" - 100 200 90 3 4 paused
    old="$(lib ns_receipt_session_file "$r")"
    sed -i.bak 's/Book a barber\./Book a haircut./' "$p/.nightshift/punch-list.md"
    if [ "$host" = bash ]; then
      lib ns_receipts_rename "$p"
    else
      env NS_MODULE="$PLUGIN/lib/Nightshift.psm1" NS_PROJECT="$p" pwsh -NoProfile -NonInteractive -Command '
        Import-Module $env:NS_MODULE -Force -DisableNameChecking; Rename-NSReceipts $env:NS_PROJECT'
    fi
    r="$(lib ns_receipt_path "$p" '4. Book a haircut.')"
    ledger="$(lib ns_receipt_session_file "$r")"
    [ -f "$ledger" ]
    [ ! -e "$old" ]
    [ "$(lib ns_receipt_session_data "$r" | wc -l | tr -d ' ')" -eq 1 ]
    sed -i.bak 's/^- \[ \]/- [x]/' "$p/.nightshift/punch-list.md"
    rm "$p/.nightshift/.shift-armed"
    touch "$p/.nightshift/.ended"
    if [ "$host" = bash ]; then
      run bash "$PLUGIN/runtime/archive-receipts.sh" --project "$p" --date 2026-10-09
    else
      run pwsh -NoProfile -NonInteractive -File "$PLUGIN/runtime/windows/archive-receipts.ps1" -Project "$p" -Date 2026-10-09
    fi
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$r" ]
    [ ! -e "$ledger" ]
  done
}

@test "an interrupted receipt redraw recovers before indexing and retries its checkpoint once" {
  p="$(site recover-index)"
  r="$(receipt "$p")"
  working "$p" 'Keep this note.'
  lib ns_receipt_add_session "$r" "$ITEM" shift 100 200 90 3 4 paused 'checkpoint=shift:1'
  before="$(cat "$r")"
  run bash -c '. "$1"; ns_receipt_redraw() { return 1; }; ns_receipt_add_session "$2" "$3" shift 200 300 90 5 6 paused checkpoint=shift:2' _ "$LIB" "$r" "$ITEM"
  [ "$status" -eq 1 ]
  [ "$(cat "$r")" = "$before" ]
  ledger="$(lib ns_receipt_session_file "$r")"
  [ -f "$ledger.pending" ]
  [ "$(lib ns_receipt_session_data "$r" | wc -l | tr -d ' ')" -eq 2 ]
  lib ns_receipts_write_index "$p"
  [ ! -e "$ledger.pending" ]
  grep -qF '| input | 8 |' "$r"
  grep -qF 'input 8 ' "$p/.nightshift/receipts/README.md"
  lib ns_receipt_add_session "$r" "$ITEM" shift 200 300 90 5 6 paused 'checkpoint=shift:2 note=Retry'
  [ "$(lib ns_receipt_session_data "$r" | wc -l | tr -d ' ')" -eq 2 ]
  grep -qxF 'Keep this note.' "$r"
}

@test "Archive recovers a pending receipt before retiring its ledger on both runtimes" {
  for host in bash pwsh; do
    [ "$host" != pwsh ] || command -v pwsh >/dev/null 2>&1 || continue
    p="$(site "recover-archive-$host")"
    r="$(receipt "$p")"
    working "$p" 'Progress.'
    run bash -c '. "$1"; ns_receipt_redraw() { return 1; }; ns_receipt_add_session "$2" "$3" shift 100 200 90 3 4 ticked checkpoint=shift:1' _ "$LIB" "$r" "$ITEM"
    [ "$status" -eq 1 ]
    ledger="$(lib ns_receipt_session_file "$r")"
    [ -f "$ledger.pending" ]
    tick "$p"
    rm "$p/.nightshift/.shift-armed"
    touch "$p/.nightshift/.ended"
    if [ "$host" = bash ]; then
      run bash "$PLUGIN/runtime/archive-receipts.sh" --project "$p" --date 2026-10-09
    else
      run pwsh -NoProfile -NonInteractive -File "$PLUGIN/runtime/windows/archive-receipts.ps1" -Project "$p" -Date 2026-10-09
    fi
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$ledger" ]
    [ ! -e "$ledger.pending" ]
    filed="$(find "$p/.nightshift/archive" -name "${r##*/}" -type f)"
    grep -qF '| input | 3 |' "$filed"
  done
}

@test "existing legacy receipt repositories ignore session state without rerunning Setup" {
  for host in bash pwsh; do
    [ "$host" != pwsh ] || command -v pwsh >/dev/null 2>&1 || continue
    p="$(site "legacy-ignore-$host")"
    r="$(receipt "$p")"
    git -C "$p/.nightshift" init --quiet
    printf STOP >"$p/.nightshift/.gitignore"
    for end in 200 300; do
      if [ "$host" = bash ]; then
        lib ns_receipt_add_session "$r" "$ITEM" shift 100 "$end" 90 3 4 paused
      else
        env NS_MODULE="$PLUGIN/lib/Nightshift.psm1" NS_RECEIPT="$r" NS_ITEM="$ITEM" NS_END="$end" pwsh -NoProfile -NonInteractive -Command '
          Import-Module $env:NS_MODULE -Force -DisableNameChecking; Add-NSReceiptSession $env:NS_RECEIPT $env:NS_ITEM shift 100 $env:NS_END 90 3 4 paused'
      fi
    done
    [ "$(head -n1 "$p/.nightshift/.gitignore")" = STOP ]
    [ "$(grep -c '^.item-sessions/$' "$p/.nightshift/.gitignore")" -eq 1 ]
    git -C "$p/.nightshift" add -A
    [ -z "$(git -C "$p/.nightshift" ls-files '.item-sessions/*')" ]
  done
}

@test "a checkpoint journal survives failure before the ledger replacement" {
  p="$(site recover-ledger-write)"
  r="$(receipt "$p")"
  working "$p" 'Keep the old receipt until recovery.'
  lib ns_receipt_add_session "$r" "$ITEM" shift 100 200 90 3 4 paused 'checkpoint=shift:1'
  run bash -c '. "$1"; ns_receipt_store_sessions() { return 1; }; ns_receipt_add_session "$2" "$3" shift 200 300 90 5 6 paused checkpoint=shift:2' _ "$LIB" "$r" "$ITEM"
  [ "$status" -eq 1 ]
  ledger="$(lib ns_receipt_session_file "$r")"
  [ "$(wc -l <"$ledger" | tr -d ' ')" -eq 1 ]
  [ "$(lib ns_receipt_session_data "$r" | wc -l | tr -d ' ')" -eq 2 ]
  lib ns_receipts_write_index "$p"
  [ ! -e "$ledger.pending" ]
  [ "$(wc -l <"$ledger" | tr -d ' ')" -eq 2 ]
  grep -qF '| input | 8 |' "$r"
}
