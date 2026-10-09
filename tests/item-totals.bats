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
