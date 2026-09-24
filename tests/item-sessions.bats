#!/usr/bin/env bats
# Charging the item being worked: the active item comes from receipt evidence, a reading is taken
# whenever it changes, and each receipt keeps a Sessions table that carries across shifts.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
LIB="$ROOT/plugins/nightshift/lib/lib.sh"
CORE="$ROOT/plugins/nightshift/hooks/shared/gate-core.sh"
PULSE="$ROOT/plugins/nightshift/hooks/pulse.sh"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }
core() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$LIB" "$CORE" "$@"; }
pulse() { bash -c '. "$1"; . "$2"; . "$3"; shift 3; "$@"' _ "$LIB" "$CORE" "$PULSE" "$@"; }

LIST3='## Items
- [ ] **3. Blocked on a reply.** <!-- id: cc33 -->
- [ ] **4. The next one.** <!-- id: dd44 -->
- [ ] **5. Later.** <!-- id: ee55 -->
'

# site <name> — an armed shift with items 3, 4 and 5 open and the shift started at zero.
site() {
  local p
  p="$(new_project "$1")"
  printf '%s' "$LIST3" >"$p/.nightshift/punch-list.md"
  printf 'test-shift-session\n' >"$p/.nightshift/.shift-session"
  mkdir -p "$p/.nightshift/receipts"
  lib ns_usage_mark_arm "$p/.nightshift"
  printf '%s' "$p"
}

# reading <project> <input> <output> — what the host reports was spent since the previous reading.
reading() {
  lib ns_usage_record "$1/.nightshift" claude claude-opus-5 transcript-incremental /t/a 10 "input=$2,output=$3"
}

# wrote <project> <receipt-stem> <stamp> — the model wrote that receipt at that time.
wrote() {
  printf '# %s\n\nWorking on it.\n' "$2" >>"$1/.nightshift/receipts/$2.md"
  touch -t "$3" "$1/.nightshift/receipts/$2.md"
}

# step <project> — what the pulse does after a tool call: catch up ticks, then follow the active item.
step() {
  pulse ns_pulse_marks "$1/.nightshift" "$1" test-shift-session ""
}

# sessions <receipt> — the recorded session lines: shift start end working input output ended.
sessions() { awk '/^<!-- session-data$/ { on = 1; next } on && /^-->$/ { exit } on { print }' "$1"; }

tick() { # <project> <number>
  sed -i.bak "s/^- \[ \] \*\*$2\./- [x] **$2./" "$1/.nightshift/punch-list.md"
}

@test "the active item is the open item whose receipt was written last" {
  p="$(site active)"
  [ "$(pulse ns_pulse_active_item "$p")" = '3. Blocked on a reply.' ]
  wrote "$p" ee55-later 202609240300
  [ "$(pulse ns_pulse_active_item "$p")" = '5. Later.' ]
  wrote "$p" dd44-the-next-one 202609240310
  [ "$(pulse ns_pulse_active_item "$p")" = '4. The next one.' ]
  # A ticked item's receipt is never the evidence for what is being worked now.
  tick "$p" 4
  [ "$(pulse ns_pulse_active_item "$p")" = '5. Later.' ]
}

@test "a receipt named by label from an earlier shift still marks its item as the one worked" {
  p="$(site legacy-active)"
  wrote "$p" dd44-the-next-one 202609240300
  printf '# 5. Later.\n\nCarried over.\n' >"$p/.nightshift/receipts/5-later.md"
  touch -t 202609240310 "$p/.nightshift/receipts/5-later.md"
  [ "$(pulse ns_pulse_active_item "$p")" = '5. Later.' ]
}

@test "setting item 3 aside to tick item 4 charges each its own span" {
  p="$(site aside)"
  reading "$p" 10 1
  wrote "$p" cc33-blocked-on-a-reply 202609240300
  step "$p"
  reading "$p" 30 3
  wrote "$p" dd44-the-next-one 202609240310
  step "$p"
  reading "$p" 60 5
  tick "$p" 4
  step "$p"

  [ "$(cut -f2,4 "$p/.nightshift/usage/marks.tsv" | tr '\t' ':' | paste -sd'|' -)" = 'arm|3. Blocked on a reply.:switch|4. The next one.:tick' ]
  r3="$p/.nightshift/receipts/cc33-blocked-on-a-reply.md"
  r4="$p/.nightshift/receipts/dd44-the-next-one.md"
  [ "$(sessions "$r3" | awk '{ print $5, $6, $7 }')" = '40 4 switched-away' ]
  [ "$(sessions "$r4" | awk '{ print $5, $6, $7 }')" = '60 5 ticked' ]
  grep -qF '| input | 60 |' "$r4"
  grep -qF '| switched away |' "$r3"
}

@test "returning to item 3 adds a second session, and its tick counts both" {
  p="$(site return)"
  reading "$p" 10 1
  wrote "$p" cc33-blocked-on-a-reply 202609240300
  step "$p"
  reading "$p" 30 3
  wrote "$p" dd44-the-next-one 202609240310
  step "$p"
  reading "$p" 60 5
  tick "$p" 4
  step "$p"
  wrote "$p" cc33-blocked-on-a-reply 202609240320
  step "$p"
  reading "$p" 30 3
  tick "$p" 3
  step "$p"

  r3="$p/.nightshift/receipts/cc33-blocked-on-a-reply.md"
  [ "$(sessions "$r3" | awk '{ print $5, $6, $7 }' | paste -sd'|' -)" = '40 4 switched-away|30 3 ticked' ]
  grep -qF '| input | 70 |' "$r3"
  grep -qE '^\| \*\*Total\*\* \| 2 sessions \|' "$r3"
}

@test "ticking an earlier item while another is worked closes the worked item's span first" {
  p="$(site earlier)"
  reading "$p" 10 1
  wrote "$p" cc33-blocked-on-a-reply 202609240300
  step "$p"
  reading "$p" 30 3
  wrote "$p" dd44-the-next-one 202609240310
  step "$p"
  reading "$p" 60 5
  tick "$p" 3
  step "$p"

  [ "$(cut -f2,4 "$p/.nightshift/usage/marks.tsv" | tr '\t' ':' | paste -sd'|' -)" = \
    'arm|3. Blocked on a reply.:switch|4. The next one.:switch|3. Blocked on a reply.:tick' ]
  r3="$p/.nightshift/receipts/cc33-blocked-on-a-reply.md"
  r4="$p/.nightshift/receipts/dd44-the-next-one.md"
  # Item 4's work in hand is its own; item 3 is charged only for what it spent before.
  [ "$(sessions "$r4" | awk '{ print $5, $6, $7 }')" = '60 5 switched-away' ]
  grep -qF '| input | 40 |' "$r3"
}

@test "only a tick is a charge: an item switched away from still gets its tick" {
  p="$(site charge)"
  reading "$p" 10 1
  wrote "$p" cc33-blocked-on-a-reply 202609240300
  step "$p"
  wrote "$p" dd44-the-next-one 202609240310
  step "$p"
  printf '## Items\n- [x] **3. Blocked on a reply.** <!-- id: cc33 -->\n- [ ] **4. The next one.** <!-- id: dd44 -->\n- [ ] **5. Later.** <!-- id: ee55 -->\n' \
    >"$p/.nightshift/punch-list.md"
  [ "$(core ns_gate_uncharged_labels "$p/.nightshift" "$p/.nightshift/punch-list.md")" = '3. Blocked on a reply.' ]
}

@test "an item parked as stalled ends its session blocked" {
  p="$(site blocked)"
  reading "$p" 10 1
  wrote "$p" cc33-blocked-on-a-reply 202609240300
  step "$p"
  printf '# Parking lot\n\n- 3. Blocked on a reply. — stalled — needs human: the vendor has not answered.\n' \
    >"$p/.nightshift/parking-lot.md"
  wrote "$p" dd44-the-next-one 202609240310
  step "$p"
  [ "$(sessions "$p/.nightshift/receipts/cc33-blocked-on-a-reply.md" | awk '{ print $7 }')" = blocked ]
}

@test "the shift's end closes the open session as paused, and the next shift continues the receipt" {
  p="$(site carry)"
  reading "$p" 10 1
  wrote "$p" cc33-blocked-on-a-reply 202609240300
  step "$p"
  reading "$p" 15 1
  core ns_gate_usage_flush "$p/.nightshift" "$p"
  r3="$p/.nightshift/receipts/cc33-blocked-on-a-reply.md"
  [ "$(sessions "$r3" | awk '{ print $5, $6, $7 }')" = '25 2 paused' ]

  # The next shift starts with fresh accounting and the same receipt.
  mv "$p/.nightshift/usage" "$p/.nightshift/usage-retired"
  lib ns_usage_mark_arm "$p/.nightshift"
  lib ns_usage_record "$p/.nightshift" claude claude-opus-5 transcript-incremental /t/b 10 'input=7,output=1'
  wrote "$p" cc33-blocked-on-a-reply 202609250300
  step "$p"
  tick "$p" 3
  step "$p"
  [ "$(sessions "$r3" | awk '{ print $5, $6, $7 }' | paste -sd'|' -)" = '25 2 paused|7 1 ticked' ]
  grep -qE '^\| \*\*Total\*\* \| 2 sessions \| .* \| \*\*32\*\* \| \*\*3\*\* \|' "$r3"
}

@test "the runtime's own writes keep the receipt's modification time" {
  p="$(site mtime)"
  wrote "$p" cc33-blocked-on-a-reply 202609240300
  before="$(lib ns_mtime "$p/.nightshift/receipts/cc33-blocked-on-a-reply.md")"
  lib ns_receipt_track_label "$p/.nightshift/receipts/cc33-blocked-on-a-reply.md" '3. Blocked on a reply.'
  lib ns_receipt_add_session "$p/.nightshift/receipts/cc33-blocked-on-a-reply.md" '3. Blocked on a reply.' \
    1111222233334444 1790210000 1790210600 600 12 3 switched-away
  [ "$(lib ns_mtime "$p/.nightshift/receipts/cc33-blocked-on-a-reply.md")" = "$before" ]
}

@test "the Sessions table is not the model's text" {
  p="$(site model-text)"
  f="$p/.nightshift/receipts/ff66-runtime-only.md"
  lib ns_receipt_add_session "$f" '6. Runtime only.' 1111222233334444 1790210000 1790210600 600 12 3 ticked
  grep -qxF '# 6. Runtime only.' "$f"
  run lib ns_receipt_has_model_text "$f"
  [ "$status" -ne 0 ]
}

@test "the PowerShell half covers the same sessions and runs in the Windows suite" {
  grep -qF 'item-sessions-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$BATS_TEST_DIRNAME/windows/item-sessions-logic.ps1"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
