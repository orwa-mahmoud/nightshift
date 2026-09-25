#!/usr/bin/env bats
# Permanent item ids: given when the shift policy is recorded, ignored by every label reader, and
# what an item's receipt is named and found by across a renumber or a retitle.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
LIB="$ROOT/plugins/nightshift/lib/lib.sh"
CORE="$ROOT/plugins/nightshift/hooks/shared/gate-core.sh"
PULSE="$ROOT/plugins/nightshift/hooks/pulse.sh"
SP="$ROOT/plugins/nightshift/runtime/shift-policy.sh"
PL="$ROOT/plugins/nightshift/runtime/punch-list.sh"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }
core() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$LIB" "$CORE" "$@"; }
pulse() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$LIB" "$PULSE" "$@"; }

# record <project> [extra-json] — the shift policy as Start records it, before the site is armed.
record() {
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  rm -f "$1/.nightshift/.shift-armed"
  jq -nc --argjson extra "$extra" '{schemaVersion:1,shiftId:"1111222233334444",createdAt:"2026-09-24T00:00:00Z",
    source:"start-defaults",deadlineEpoch:null,verificationLevel:"none",toolingPolicy:"existing-tools"} + $extra' |
    bash "$SP" --project "$1" set --from-json - >/dev/null
}

# ids <project> — the id on each item line, list order.
ids() { sed -n 's/^- \[[ xX]\].*<!-- id: \([a-z0-9]*\) -->$/\1/p' "$1/.nightshift/punch-list.md"; }

@test "recording the policy gives every item a permanent id and keeps one it already has" {
  p="$(new_project ids-assign)"
  printf '# c\n\n## Items\n- [ ] **1. first.**\n  - a sub-bullet\n- [x] **2. done.**\n- [ ] **3. kept.** <!-- id: zz99 -->\n' \
    >"$p/.nightshift/punch-list.md"
  record "$p"
  [ "$(ids "$p" | wc -l | tr -d ' ')" -eq 3 ]
  ids "$p" | head -n2 | grep -qxE '[a-z][a-z0-9]{3}'
  [ "$(ids "$p" | sed -n 3p)" = zz99 ]
  [ "$(ids "$p" | sort -u | wc -l | tr -d ' ')" -eq 3 ]
  grep -qxF '  - a sub-bullet' "$p/.nightshift/punch-list.md"
}

@test "the recorded digest is of the list with its ids, so arming does not read as a change" {
  p="$(new_project ids-digest)"
  printf '## Items\n- [ ] **1. first.**\n- [ ] **2. second.**\n' >"$p/.nightshift/punch-list.md"
  record "$p"
  [ "$(jq -r .itemsDigest "$p/.nightshift/shift-policy.json")" = "$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")" ]
  : >"$p/.nightshift/.shift-armed"
  run gate "$p"
  is_block "$output"
  [[ "$output" != *'since this shift armed'* ]] || false
}

@test "recording again keeps every id, and a line that loses its id gets a new one" {
  p="$(new_project ids-stable)"
  printf '## Items\n- [ ] **1. first.**\n- [ ] **2. second.**\n' >"$p/.nightshift/punch-list.md"
  record "$p"
  before="$(ids "$p")"
  rm -f "$p/.nightshift/shift-policy.json"
  record "$p"
  [ "$(ids "$p")" = "$before" ]

  first="$(printf '%s\n' "$before" | head -n1)"
  sed -i.bak "s/ <!-- id: $first -->//" "$p/.nightshift/punch-list.md"
  rm -f "$p/.nightshift/shift-policy.json"
  record "$p"
  [ "$(ids "$p" | head -n1)" != "$first" ]
  [ "$(ids "$p" | sed -n 2p)" = "$(printf '%s\n' "$before" | sed -n 2p)" ]
}

@test "an id already used in the history is never given again" {
  p="$(new_project ids-history)"
  mkdir -p "$p/.nightshift/archive/2026-09-01" "$p/.nightshift/receipts"
  printf '## Items\n- [x] **1. old.** <!-- id: aaaa -->\n' >"$p/.nightshift/archive/2026-09-01/punch-list.md"
  : >"$p/.nightshift/receipts/bbbb-carried.md"
  for id in aaaa bbbb cccc; do
    lib ns_item_id_used "$p/.nightshift" "$id" "cccc" || { echo "$id reads as free"; return 1; }
  done
  run lib ns_item_id_used "$p/.nightshift" dddd "cccc"
  [ "$status" -ne 0 ]
  run lib ns_item_new_id "$p/.nightshift" "cccc"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[a-z][a-z0-9]{3}$ ]] || false
}

@test "a policy that states its items digest leaves the list alone" {
  p="$(new_project ids-stated)"
  printf '## Items\n- [ ] **1. first.**\n' >"$p/.nightshift/punch-list.md"
  before="$(cksum <"$p/.nightshift/punch-list.md")"
  record "$p" '{"itemsDigest":"0000000000000000000000000000000000000000000000000000000000000000"}'
  [ "$(cksum <"$p/.nightshift/punch-list.md")" = "$before" ]
}

@test "label readers never see the id comment" {
  p="$(new_project ids-labels)"
  printf '## Items\n- [x] **1. done.** <!-- id: aa11 -->\n- [x] plain done <!-- id: bb22 -->\n- [ ] **3. open — later** <!-- id: cc33 -->\n' \
    >"$p/.nightshift/punch-list.md"
  list="$p/.nightshift/punch-list.md"
  [ "$(core ns_gate_ticked_labels "$list" | paste -sd'|' -)" = '1. done.|plain done' ]
  [ "$(core ns_gate_open_item "$list")" = '3. open' ]
  [ "$(pulse ns_pulse_active_item "$p")" = '3. open' ]
  [ "$(lib ns_status_open_title "$list")" = '3. open — later' ]
  [ "$(core ns_gate_uncharged_labels "$p/.nightshift" "$list" | paste -sd'|' -)" = '1. done.|plain done' ]
}

@test "punch-list item finds an item by its number, its id, or its label" {
  p="$(new_project ids-lookup)"
  printf '## Items\n- [x] **4. done.** <!-- id: aa11 -->\n- [ ] **5. open.** <!-- id: bb22 -->\n  - its bullet\n' \
    >"$p/.nightshift/punch-list.md"
  want="$(printf -- '- [ ] **5. open.** <!-- id: bb22 -->\n  - its bullet')"
  for key in 5 bb22 '5. open.'; do
    run bash "$PL" --project "$p" item "$key"
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ] || { echo "item $key: $output"; return 1; }
  done
  run bash "$PL" --project "$p" item 6
  [ "$status" -eq 2 ]
}

@test "a new receipt is named for the item's number, its title and its id" {
  p="$(new_project ids-receipt)"
  printf '## Items\n- [ ] **5. Charge the right item.** <!-- id: k7q2 -->\n- [ ] **6. No id yet.**\n' \
    >"$p/.nightshift/punch-list.md"
  [ "$(lib ns_receipt_path "$p" '5. Charge the right item.')" = "$p/.nightshift/receipts/05-charge-the-right-item-k7q2.md" ]
  [ "$(lib ns_receipt_path "$p" '6. No id yet.')" = "$p/.nightshift/receipts/6-no-id-yet.md" ]
  run pulse ns_pulse_receipts_start_line "$p" '5. Charge the right item.'
  [[ "$output" == *'.nightshift/receipts/05-charge-the-right-item-k7q2.md'* ]] || false
}

@test "a bare number followed by a dash, a bracket or a colon keeps the title in the label and the name" {
  p="$(new_project ids-dash-number)"
  printf '## Items\n- [ ] **1 — Inventory every surface.** <!-- id: ab12 -->\n- [ ] **12) Twelve things** <!-- id: cd34 -->\n- [ ] **3: Colon title** <!-- id: ef56 -->\n- [ ] **4 - Hyphen title — a note** <!-- id: gh78 -->\n- [ ] **P05 - Letter number.** <!-- id: ij90 -->\n' \
    >"$p/.nightshift/punch-list.md"
  [ "$(lib ns_item_rows "$p/.nightshift/punch-list.md" | cut -f1 | paste -sd'|' -)" = \
    '1 — Inventory every surface.|12) Twelve things|3: Colon title|4 - Hyphen title|P05' ]
  r="$p/.nightshift/receipts"
  [ "$(lib ns_receipt_path "$p" '1 — Inventory every surface.')" = "$r/01-inventory-every-surface-ab12.md" ]
  [ "$(lib ns_receipt_path "$p" '12) Twelve things')" = "$r/12-twelve-things-cd34.md" ]
  [ "$(lib ns_receipt_path "$p" '3: Colon title')" = "$r/03-colon-title-ef56.md" ]
  [ "$(lib ns_receipt_path "$p" '4 - Hyphen title')" = "$r/04-hyphen-title-gh78.md" ]
  # A code before a dash stays the label, and the name takes the words of the whole title.
  [ "$(lib ns_receipt_path "$p" 'P05')" = "$r/P05-letter-number-ij90.md" ]
}

@test "an item whose title carries no number is numbered by its place in the list" {
  p="$(new_project ids-unnumbered)"
  printf '## Items\n- [ ] **1. First.** <!-- id: ab12 -->\n- [ ] **Keep the model** <!-- id: cd34 -->\n' \
    >"$p/.nightshift/punch-list.md"
  [ "$(lib ns_receipt_path "$p" 'Keep the model')" = "$p/.nightshift/receipts/02-keep-the-model-cd34.md" ]
}

@test "between shifts a receipt takes the name its item carries now; on shift it keeps its name" {
  p="$(new_project ids-rename)"
  r="$p/.nightshift/receipts"
  mkdir -p "$r"
  printf '## Items\n- [x] **1 — Inventory.** <!-- id: ab12 -->\n- [ ] **2. Fix the resolver.** <!-- id: cd34 -->\n- [ ] **3. Held.** <!-- id: ef56 -->\n' \
    >"$p/.nightshift/punch-list.md"
  printf 'cut down to its number\n' >"$r/1.md"
  printf 'named by id first\n' >"$r/cd34-fix-the-resolver.md"
  touch -t 202609240101 "$r/cd34-fix-the-resolver.md"
  # On shift the names hold still.
  touch "$p/.nightshift/.shift-armed"
  lib ns_receipts_write_index "$p"
  [ -f "$r/1.md" ] && [ -f "$r/cd34-fix-the-resolver.md" ]
  # Between shifts each receipt follows its item, keeps its time, and the index links the new name.
  rm -f "$p/.nightshift/.shift-armed"
  lib ns_receipts_write_index "$p"
  [ "$(cat "$r/01-inventory-ab12.md")" = 'cut down to its number' ]
  [ "$(cat "$r/02-fix-the-resolver-cd34.md")" = 'named by id first' ]
  [ ! -e "$r/1.md" ] && [ ! -e "$r/cd34-fix-the-resolver.md" ]
  [ -z "$(find "$r/02-fix-the-resolver-cd34.md" -newermt '2026-09-24 01:02' 2>/dev/null)" ]
  grep -qF '[./02-fix-the-resolver-cd34.md](./02-fix-the-resolver-cd34.md)' "$r/README.md"
}

@test "a receipt never moves onto a link planted at its new name" {
  p="$(new_project ids-rename-link)"
  r="$p/.nightshift/receipts"
  mkdir -p "$r"
  rm -f "$p/.nightshift/.shift-armed"
  printf '## Items\n- [ ] **3. Held.** <!-- id: ef56 -->\n' >"$p/.nightshift/punch-list.md"
  printf 'the receipt\n' >"$r/ef56-held.md"
  printf 'outside\n' >"$BATS_TEST_TMPDIR/outside.md"
  ln -s "$BATS_TEST_TMPDIR/outside.md" "$r/03-held-ef56.md"
  lib ns_receipts_rename "$p"
  [ "$(cat "$r/ef56-held.md")" = 'the receipt' ]
  [ -L "$r/03-held-ef56.md" ]
  [ "$(cat "$BATS_TEST_TMPDIR/outside.md")" = outside ]
}

@test "recording the policy gives receipts their items' names before the shift arms" {
  p="$(new_project ids-rename-record)"
  mkdir -p "$p/.nightshift/receipts"
  printf '# c\n\n## Items\n- [ ] **4. Renumbered.** <!-- id: k7q2 -->\n' >"$p/.nightshift/punch-list.md"
  printf 'carried\n' >"$p/.nightshift/receipts/k7q2-old-title.md"
  record "$p"
  [ "$(cat "$p/.nightshift/receipts/04-renumbered-k7q2.md")" = carried ]
  [ ! -e "$p/.nightshift/receipts/k7q2-old-title.md" ]
}

@test "renumbering and retitling an open item between shifts keeps its receipt and totals" {
  p="$(new_project ids-renumber)"
  mkdir -p "$p/.nightshift/receipts"
  printf '## Items\n- [ ] **2. Old title.** <!-- id: k7q2 -->\n' >"$p/.nightshift/punch-list.md"
  rec="$p/.nightshift/receipts/k7q2-old-title.md"
  printf '# 2. Old title.\n\n| Tokens | Amount |\n| --- | ---: |\n| input | 10 |\n\n<!-- tokens 10 0 0 5 0 -->\n\nWhere it stands.\n' >"$rec"
  lib ns_receipt_track_label "$rec" '2. Old title.'

  # Between shifts the owner renumbers and retitles it. The id is unchanged, so is the file.
  printf '## Items\n- [ ] **1. Warm-up.**\n- [ ] **5. New title.** <!-- id: k7q2 -->\n' >"$p/.nightshift/punch-list.md"
  [ "$(lib ns_receipt_path "$p" '5. New title.')" = "$rec" ]
  lib ns_receipt_track_label "$rec" '5. New title.'
  [ "$(sed -n 1p "$rec")" = '# 5. New title.' ]
  grep -qxE 'Renamed from 2\. Old title\. on [0-9]{4}-[0-9]{2}-[0-9]{2}\.' "$rec"
  grep -qxF 'Where it stands.' "$rec"
  [ "$(grep -c '^<!-- item: ' "$rec")" -eq 1 ]
  grep -qxF '<!-- item: 5. New title. -->' "$rec"

  lib ns_receipts_write_index "$p"
  grep -F '| 5. New title. | open |' "$p/.nightshift/receipts/README.md" | grep -qF 'input 10'
  # Tracking the same label again records nothing new.
  lib ns_receipt_track_label "$rec" '5. New title.'
  [ "$(grep -c '^Renamed from ' "$rec")" -eq 1 ]
  # Between shifts the file takes the item's new name and keeps everything in it.
  rm -f "$p/.nightshift/.shift-armed"
  lib ns_receipts_write_index "$p"
  [ ! -e "$rec" ]
  grep -qxF 'Where it stands.' "$p/.nightshift/receipts/05-new-title-k7q2.md"
  grep -qF '[./05-new-title-k7q2.md](./05-new-title-k7q2.md)' "$p/.nightshift/receipts/README.md"
}

@test "the runtime's own lines do not count as the model's receipt text" {
  p="$(new_project ids-model-text)"
  mkdir -p "$p/.nightshift/receipts"
  printf '# 5. New title.\n\nRenamed from 2. Old title. on 2026-09-24.\n\n<!-- item: 5. New title. -->\n' \
    >"$p/.nightshift/receipts/k7q2-new-title.md"
  run lib ns_receipt_has_model_text "$p/.nightshift/receipts/k7q2-new-title.md"
  [ "$status" -ne 0 ]
}

@test "an earlier shift's receipt without an id is still found by its label" {
  p="$(new_project ids-legacy)"
  mkdir -p "$p/.nightshift/receipts"
  printf '## Items\n- [ ] **3. Carry over.** <!-- id: abcd -->\n' >"$p/.nightshift/punch-list.md"
  printf '# 3. Carry over.\n\nStarted last night.\n' >"$p/.nightshift/receipts/3-carry-over.md"
  [ "$(lib ns_receipt_path "$p" '3. Carry over.')" = "$p/.nightshift/receipts/3-carry-over.md" ]
}

@test "the gate charges a tick to the id-named receipt" {
  p="$(new_project ids-gate)"
  printf '## Items\n- [x] **P01 - first.** <!-- id: aa11 -->\n- [ ] **P02 - open.** <!-- id: bb22 -->\n' \
    >"$p/.nightshift/punch-list.md"
  lib ns_usage_record "$p/.nightshift" claude claude-opus-5 transcript-incremental /t/a 10 'input=4,output=2'
  core ns_gate_usage_sync "$p/.nightshift" "$p" "$p/.nightshift/punch-list.md" 1
  rec="$p/.nightshift/receipts/P01-first-aa11.md"
  [ -f "$rec" ]
  grep -qF '| input | 4 |' "$rec"
  grep -qxF '<!-- item: P01 -->' "$rec"
  grep -qF '[./P01-first-aa11.md](./P01-first-aa11.md)' "$p/.nightshift/receipts/README.md"
}

@test "the archive index lists id-named receipts in the order of their headings" {
  p="$(new_project ids-archive)"
  d="$p/.nightshift/archive/2026-09-24/receipts"
  mkdir -p "$d"
  printf '# 10. Ten.\n\ntext\n' >"$d/aaaa-ten.md"
  printf '# 2. Two.\n\ntext\n' >"$d/zzzz-two.md"
  printf '# 1. One.\n\ntext\n' >"$d/mmmm-one.md"
  lib ns_receipts_write_archive_index "$d" 2026-09-24
  [ "$(sed -n 's/^| \([0-9]*\)\. .*/\1/p' "$d/README.md" | paste -sd' ' -)" = '1 2 10' ]
}

@test "the PowerShell half covers the same ids and runs in the Windows suite" {
  grep -qF 'item-ids-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$BATS_TEST_DIRNAME/windows/item-ids-logic.ps1"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
