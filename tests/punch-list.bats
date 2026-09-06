#!/usr/bin/env bats
# One item at a time, without re-reading the whole list to get it.
#
# The model used to re-read the entire punch list at the start of every item, because the Gates
# block may legitimately change mid-shift. On a long list that is thousands of tokens per item to
# see one block. The helper prints the two things an item needs — and nothing else, and in the
# file's own words.
#
# The other half is the contract holding still. Watching for tampering used to be the model's job,
# on a file the model also edits; the gate records digests at arming and checks them instead.

load helpers

SH="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/punch-list.sh"
LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
CORE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/gate-core.sh"
GATE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/clock-out-gate.sh"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

# a_list <project> — a punch list with a contract, a gates block, and three items, one of which
# carries fenced code and a nested list.
a_list() {
  cat >"$1/.nightshift/punch-list.md" <<'LIST'
# Punch list

## Shift

The contract the owner wrote. Nobody edits this while a shift runs.

## Gates

- Run the item's own checks before its commit.

## Items

- [x] **P01 - already done.**

  Its own sub-bullet.

- [ ] **P02 - the open one.**

  Why it matters.

  ```bash
  echo "fenced code inside an item"
  ```

  - a nested bullet
    - and a deeper one

  Last line of P02.

- [ ] **P03 - the one after.**

  Nothing special.

## Notes

Trailing prose that belongs to no item.
LIST
}

@test "next prints the gates block and the first open item, and nothing else" {
  p="$(new_project pl-next)"
  a_list "$p"
  run "$SH" --project "$p" next
  [ "$status" -eq 0 ]

  printf '%s\n' "$output" | grep -qF '## Gates'
  printf '%s\n' "$output" | grep -qF "Run the item's own checks"
  printf '%s\n' "$output" | grep -qF 'P02 - the open one'
  # Not the finished item, not the one after it, not the trailing prose, not the contract.
  ! printf '%s\n' "$output" | grep -qF 'P01 - already done'
  ! printf '%s\n' "$output" | grep -qF 'P03 - the one after'
  ! printf '%s\n' "$output" | grep -qF 'Trailing prose'
  ! printf '%s\n' "$output" | grep -qF 'The contract the owner wrote'
}

@test "an item's fenced code and nested bullets come through whole" {
  p="$(new_project pl-whole)"
  a_list "$p"
  run "$SH" --project "$p" next
  printf '%s\n' "$output" | grep -qF 'echo "fenced code inside an item"'
  printf '%s\n' "$output" | grep -qF -e '- a nested bullet'
  printf '%s\n' "$output" | grep -qF -e '    - and a deeper one'
  printf '%s\n' "$output" | grep -qF 'Last line of P02.'
}

@test "item prints one named item, whether it is open or ticked" {
  p="$(new_project pl-named)"
  a_list "$p"
  run "$SH" --project "$p" item P03
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'P03 - the one after'
  ! printf '%s\n' "$output" | grep -qF 'P02 - the open one'

  # A model resuming mid-item after a revival asks for its own item, which may already be ticked.
  run "$SH" --project "$p" item P01
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'P01 - already done'

  run "$SH" --project "$p" item P99
  [ "$status" -eq 2 ]
}

@test "a list with nothing open says none" {
  p="$(new_project pl-none)"
  printf '# Punch list\n\n## Gates\n\n- one gate.\n\n## Items\n\n- [x] **P01 - done.**\n' \
    >"$p/.nightshift/punch-list.md"
  run "$SH" --project "$p" next
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'none'
}

@test "the helper is a reader: the file is untouched" {
  p="$(new_project pl-readonly)"
  a_list "$p"
  before="$(cksum <"$p/.nightshift/punch-list.md")"
  run "$SH" --project "$p" next
  run "$SH" --project "$p" item P03
  [ "$(cksum <"$p/.nightshift/punch-list.md")" = "$before" ]
}

# The digests. A tick is invisible to them; anything else about an item is not.

@test "ticking a box changes neither digest" {
  p="$(new_project pl-tick)"
  a_list "$p"
  contract="$(lib ns_punch_contract_digest "$p/.nightshift/punch-list.md")"
  items="$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")"

  sed 's/- \[ \] \*\*P02/- [x] **P02/' "$p/.nightshift/punch-list.md" >"$p/t.md"
  mv "$p/t.md" "$p/.nightshift/punch-list.md"
  [ "$(lib ns_punch_contract_digest "$p/.nightshift/punch-list.md")" = "$contract" ]
  [ "$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")" = "$items" ]
}

@test "rewording, deleting or inserting an item moves the items digest" {
  p="$(new_project pl-items)"
  a_list "$p"
  before="$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")"

  sed 's/P03 - the one after/P03 - the one after, reworded/' "$p/.nightshift/punch-list.md" >"$p/t.md"
  mv "$p/t.md" "$p/.nightshift/punch-list.md"
  [ "$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")" != "$before" ]

  a_list "$p"
  grep -v 'P03 - the one after' "$p/.nightshift/punch-list.md" >"$p/t.md"
  mv "$p/t.md" "$p/.nightshift/punch-list.md"
  [ "$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")" != "$before" ]

  a_list "$p"
  awk '/^## Notes$/ { print "- [ ] **P04 - snuck in.**"; print "" } { print }' \
    "$p/.nightshift/punch-list.md" >"$p/t.md"
  mv "$p/t.md" "$p/.nightshift/punch-list.md"
  [ "$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")" != "$before" ]

  # Below the items section is not the items section: notes the owner keeps under the list are
  # theirs to edit, and the gate does not hold them still.
  a_list "$p"
  printf '\nAnother note.\n' >>"$p/.nightshift/punch-list.md"
  [ "$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")" = "$before" ]
}

@test "editing the contract moves the contract digest and leaves the items alone" {
  p="$(new_project pl-contract)"
  a_list "$p"
  contract="$(lib ns_punch_contract_digest "$p/.nightshift/punch-list.md")"
  items="$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")"

  sed 's/Nobody edits this while a shift runs./Anyone may edit this./' \
    "$p/.nightshift/punch-list.md" >"$p/t.md"
  mv "$p/t.md" "$p/.nightshift/punch-list.md"
  [ "$(lib ns_punch_contract_digest "$p/.nightshift/punch-list.md")" != "$contract" ]
  [ "$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")" = "$items" ]
}

@test "the gates block is outside both digests, because the owner may change it mid-shift" {
  p="$(new_project pl-gates)"
  a_list "$p"
  contract="$(lib ns_punch_contract_digest "$p/.nightshift/punch-list.md")"
  items="$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")"

  sed "s/Run the item's own checks before its commit./Run the whole suite before every commit./" \
    "$p/.nightshift/punch-list.md" >"$p/t.md"
  mv "$p/t.md" "$p/.nightshift/punch-list.md"
  [ "$(lib ns_punch_contract_digest "$p/.nightshift/punch-list.md")" = "$contract" ]
  [ "$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")" = "$items" ]
}

@test "a checkout that converts line endings is not a changed contract" {
  p="$(new_project pl-crlf)"
  a_list "$p"
  lf_contract="$(lib ns_punch_contract_digest "$p/.nightshift/punch-list.md")"
  lf_items="$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")"

  # What a Windows checkout of the same list looks like on disk.
  awk '{ printf "%s\r\n", $0 }' "$p/.nightshift/punch-list.md" >"$p/crlf.md"
  mv "$p/crlf.md" "$p/.nightshift/punch-list.md"
  grep -q $'\r' "$p/.nightshift/punch-list.md"

  [ "$(lib ns_punch_contract_digest "$p/.nightshift/punch-list.md")" = "$lf_contract" ]
  [ "$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")" = "$lf_items" ]
}

# The gate side. A contract that moved is a block in its own right, before any question of
# shortening the reminder arises.

# armed <project> — the same list, with the digests recorded as arming records them.
armed() {
  a_list "$1"
  {
    printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z",'
    printf '"source":"composition","verificationLevel":"final","toolingPolicy":"existing-tools",'
    printf '"contractDigest":"%s","itemsDigest":"%s"}\n' \
      "$(lib ns_punch_contract_digest "$1/.nightshift/punch-list.md")" \
      "$(lib ns_punch_items_digest "$1/.nightshift/punch-list.md")"
  } >"$1/.nightshift/shift-policy.json"
}

# edit <project> <sed script> — the owner's editor, or someone else's.
edit() {
  sed "$2" "$1/.nightshift/punch-list.md" >"$1/edited.md"
  mv "$1/edited.md" "$1/.nightshift/punch-list.md"
}

block() {
  jq -nc '{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:""}' |
    env CLAUDE_PROJECT_DIR="$1" bash "$GATE"
}
reason() { printf '%s' "$1" | jq -r '.reason // empty'; }

@test "an untouched contract blocks on the work, not on the list" {
  p="$(new_project pl-gate-clean)"
  armed "$p"
  run block "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  ! reason "$output" | grep -qF 'since this shift armed'
}

@test "ticking a box is not a contract mismatch" {
  p="$(new_project pl-gate-tick)"
  armed "$p"
  edit "$p" 's/- \[ \] \*\*P02/- [x] **P02/'
  run block "$p"
  ! reason "$output" | grep -qF 'since this shift armed'
}

@test "an edited contract blocks, naming the contract" {
  p="$(new_project pl-gate-contract)"
  armed "$p"
  edit "$p" 's/Nobody edits this while a shift runs./Anyone may edit this./'
  run block "$p"
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  reason "$output" | grep -qF 'shift contract above the Items heading'
  reason "$output" | grep -qF 'your ticks stand'
}

@test "a reworded item blocks, naming the item and ruling a tick out as the cause" {
  p="$(new_project pl-gate-item)"
  armed "$p"
  edit "$p" 's/P03 - the one after/P03 - something else entirely/'
  run block "$p"
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  reason "$output" | grep -qF 'reworded, removed or inserted'
  reason "$output" | grep -qF 'Ticking a box is invisible to this check'
}

@test "the owner may still change the gates block mid-shift" {
  p="$(new_project pl-gate-gates)"
  armed "$p"
  edit "$p" "s/Run the item's own checks before its commit./Run the whole suite before every commit./"
  run block "$p"
  ! reason "$output" | grep -qF 'since this shift armed'
}

@test "a policy written before these fields existed compares nothing" {
  p="$(new_project pl-gate-old)"
  armed "$p"
  jq 'del(.contractDigest, .itemsDigest)' "$p/.nightshift/shift-policy.json" >"$p/old.json"
  mv "$p/old.json" "$p/.nightshift/shift-policy.json"
  edit "$p" 's/Nobody edits this while a shift runs./Anyone may edit this./'
  run block "$p"
  # Still blocked — there is open work — but not on a comparison it cannot make.
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  ! reason "$output" | grep -qF 'since this shift armed'
}

@test "a tampered contract is answered in full, never with the short line" {
  p="$(new_project pl-gate-short)"
  armed "$p"
  jq '.clockOutReminderMode = "changed-only"' "$p/.nightshift/rules.json" >"$p/knobs.json"
  mv "$p/knobs.json" "$p/.nightshift/rules.json"
  run block "$p" # the first block, after which the model holds the contract
  edit "$p" 's/Nobody edits this while a shift runs./Anyone may edit this./'
  run block "$p"
  reason "$output" | grep -qF 'shift contract above the Items heading'
  ! reason "$output" | grep -qF 'still binds'
}

# The Windows twin. Not "looks equivalent" — the same bytes and the same digests, checked against
# the POSIX side on the same file.

ps_ready() {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
}

psrun() { # <script> [args…]
  pwsh -NoProfile -NonInteractive -File "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/punch-list.ps1" "$@"
}

psfn() { # <function> <args…> — one module call, printed
  pwsh -NoProfile -NonInteractive -Command \
    "Import-Module '$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1' -Force -DisableNameChecking; $*"
}

@test "the twin prints the same bytes as the POSIX reader" {
  ps_ready
  p="$(new_project pl-twin)"
  a_list "$p"

  "$SH" --project "$p" next >"$p/posix.txt"
  psrun -Project "$p" next >"$p/windows.txt"
  diff -u "$p/posix.txt" "$p/windows.txt"

  "$SH" --project "$p" item P03 >"$p/posix-item.txt"
  psrun -Project "$p" item P03 >"$p/windows-item.txt"
  diff -u "$p/posix-item.txt" "$p/windows-item.txt"
}

@test "the twin says none, and refuses an unknown id, the same way" {
  ps_ready
  p="$(new_project pl-twin-none)"
  printf '# Punch list\n\n## Gates\n\n- one gate.\n\n## Items\n\n- [x] **P01 - done.**\n' \
    >"$p/.nightshift/punch-list.md"
  run psrun -Project "$p" next
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'none'

  a_list "$p"
  run psrun -Project "$p" item P99
  [ "$status" -eq 2 ]
}

@test "both implementations compute the same two digests" {
  ps_ready
  p="$(new_project pl-twin-digest)"
  a_list "$p"
  list="$p/.nightshift/punch-list.md"

  [ "$(psfn "Get-NSPunchContractDigest '$list'")" = "$(lib ns_punch_contract_digest "$list")" ]
  [ "$(psfn "Get-NSPunchItemsDigest '$list'")" = "$(lib ns_punch_items_digest "$list")" ]

  # And still agree once a box is ticked and the list has grown a CRLF checkout.
  sed 's/- \[ \] \*\*P02/- [x] **P02/' "$list" >"$p/t.md"
  awk '{ printf "%s\r\n", $0 }' "$p/t.md" >"$list"
  [ "$(psfn "Get-NSPunchContractDigest '$list'")" = "$(lib ns_punch_contract_digest "$list")" ]
  [ "$(psfn "Get-NSPunchItemsDigest '$list'")" = "$(lib ns_punch_items_digest "$list")" ]
}

@test "both policy writers record the same two digests at composition" {
  ps_ready
  p="$(new_project pl-twin-writer)"
  rm -f "$p/.nightshift/.shift-armed" # composition happens before the clock starts
  a_list "$p"
  cat >"$p/candidate.json" <<'JSON'
{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z",
 "source":"composition","verificationLevel":"final","toolingPolicy":"existing-tools"}
JSON

  bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/shift-policy.sh" \
    --project "$p" set --from-json "$p/candidate.json"
  posix_contract="$(jq -r .contractDigest "$p/.nightshift/shift-policy.json")"
  posix_items="$(jq -r .itemsDigest "$p/.nightshift/shift-policy.json")"
  [ "$posix_contract" = "$(lib ns_punch_contract_digest "$p/.nightshift/punch-list.md")" ]

  rm -f "$p/.nightshift/shift-policy.json"
  pwsh -NoProfile -NonInteractive -File \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/shift-policy.ps1" \
    -Project "$p" set -FromJson "$p/candidate.json"
  [ "$(jq -r .contractDigest "$p/.nightshift/shift-policy.json")" = "$posix_contract" ]
  [ "$(jq -r .itemsDigest "$p/.nightshift/shift-policy.json")" = "$posix_items" ]
}
