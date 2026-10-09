#!/usr/bin/env bats
# Sizing a shift from the owner's own history: the Time and Tokens totals of ticked items'
# receipts, live and archived. A missing reading is missing, never zero, and too few readings
# estimate nothing.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
ESTIMATE="$PLUGIN/runtime/shift-estimate.sh"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

# receipt <file> <working> <input|-> <output> [cache-read] [reasoning] — an item receipt whose Time
# and Tokens section reads that working time and, unless the input is `-`, those tokens. Cache reads
# and reasoning are recorded but are not part of an item's tokens: input plus output is.
receipt() {
  mkdir -p "${1%/*}"
  {
    printf '# An item.\n\n<!-- usage -->\n'
    if [ "$3" != - ]; then
      printf '| Tokens | Amount |\n| --- | ---: |\n| input | %s |\n| output | %s |\n\n<!-- tokens %s 0 %s %s %s -->\n\n' \
        "$3" "$4" "$3" "${5:-0}" "$4" "${6:-0}"
    fi
    printf '| Time | |\n| --- | --- |\n| working | %s |\n| wall | %s |\n<!-- /usage -->\n' "$2" "$2"
  } >"$1"
}

# history <name> — three ticked items with Claude Code readings and one open item, live; two
# archived receipts, one with Codex readings and one whose host gave no token reading.
history() {
  local p ns receipts names
  p="$(new_project "$1")"
  ns="$p/.nightshift"
  rm -f "$ns/.shift-armed"
  printf '## Items\n- [x] **1. One.** <!-- id: aa11 -->\n- [x] **2. Two.** <!-- id: bb22 -->\n- [x] **3. Three.** <!-- id: cc33 -->\n- [ ] **4. Four.** <!-- id: dd44 -->\n' \
    >"$ns/punch-list.md"
  receipts="$ns/receipts"
  names="$(lib ns_receipts_ticked_names "$p")"
  set -- $names
  receipt "$receipts/$1" '10m 0s' 400000 600000
  receipt "$receipts/$2" '20m 0s' 1500000 500000
  receipt "$receipts/$3" '30m 0s' 300000 200000
  receipt "$receipts/$(lib ns_receipts_open_names "$p")" '5h 0m' 9000000 9000000
  receipt "$ns/archive/2026-10-01/receipts/1-codex-item.md" '40m 0s' 2000000 1000000 5000000 300000
  receipt "$ns/archive/2026-10-01/receipts/2-cursor-item.md" '1h 0m' - -
  printf '# Receipts\n' >"$ns/archive/2026-10-01/receipts/README.md"
  printf '# Morning\n' >"$ns/archive/2026-10-01/receipts/morning-2026-10-01.md"
  printf '%s' "$p"
}

@test "an empty history estimates nothing" {
  p="$(new_project empty)"
  run bash "$ESTIMATE" --project "$p" --items 4
  [ "$status" -eq 0 ]
  [ "$output" = 'estimate none: no ticked item has a receipt yet' ]
}

@test "per-item figures come from ticked receipts, live and archived, with missing readings named" {
  p="$(history mixed)"
  run bash "$ESTIMATE" --project "$p"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat <<'EOF'
estimate from 5 ticked items: 3 live, 2 archived
time per item: median 30m 0s · range 10m 0s to 1h 0m · from 5 items
tokens per item: median 1.5M · range 500.0k to 3.0M · from 4 items, 1 without a reading
EOF
)" ] || { printf '%s\n' "$output"; return 1; }
}

@test "for a drafted list it suggests a total, a deadline and a budget in the punch list's syntax" {
  p="$(history suggest)"
  run bash "$ESTIMATE" --project "$p" --items 4
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | tail -n 3 >"$BATS_TEST_TMPDIR/suggestions.txt"
  [ "$(cat "$BATS_TEST_TMPDIR/suggestions.txt")" = "$(cat <<'EOF'
for 4 items: time 2h 0m to 4h 0m · tokens 6.0M to 12.0M
suggested deadline: 2h 30m from the start
suggested budget: soft 30m / 1.5M tokens, hard 1h / 3M tokens
EOF
)" ] || { printf '%s\n' "$output"; return 1; }
  # The suggested budget is one the punch list accepts as written.
  run lib ns_budget_parse 'soft 30m / 1.5M tokens, hard 1h / 3M tokens'
  [ "$status" -eq 0 ]
  [ "$output" = '1800 1500000 3600 3000000' ]
}

@test "too few readings estimate nothing for that figure" {
  p="$(new_project few)"
  rm -f "$p/.nightshift/.shift-armed"
  receipt "$p/.nightshift/archive/2026-10-01/receipts/1-a.md" '10m 0s' 100 100
  receipt "$p/.nightshift/archive/2026-10-01/receipts/2-b.md" '20m 0s' - -
  run bash "$ESTIMATE" --project "$p" --items 2
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat <<'EOF'
estimate from 2 ticked items: 0 live, 2 archived
time per item: too few readings (2 of at least 3)
tokens per item: too few readings (1 of at least 3), 1 without a reading
for 2 items: no estimate
EOF
)" ] || { printf '%s\n' "$output"; return 1; }
}

@test "the verb is read-only and refuses a malformed item count" {
  p="$(history readonly)"
  before="$(cd "$p" && find . -type f | LC_ALL=C sort | xargs cksum)"
  bash "$ESTIMATE" --project "$p" --items 3 >/dev/null
  [ "$(cd "$p" && find . -type f | LC_ALL=C sort | xargs cksum)" = "$before" ]
  run bash "$ESTIMATE" --project "$p" --items 0
  [ "$status" -eq 1 ]
  run bash "$ESTIMATE" --project "$p" --items many
  [ "$status" -eq 1 ]
}

@test "native Windows prints the same estimate, and its suite is registered" {
  grep -qF 'shift-estimate-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  for case in mixed:3 empty:2 few:2; do
    name="${case%%:*}"
    case "$name" in
      mixed) p="$(history ps-mixed)" ;;
      empty) p="$(new_project ps-empty)" ;;
      few)
        p="$(new_project ps-few)"
        receipt "$p/.nightshift/archive/2026-10-01/receipts/1-a.md" '10m 0s' 100 100
        ;;
    esac
    want="$(bash "$ESTIMATE" --project "$p" --items "${case#*:}")"
    got="$(pwsh -NoProfile -NonInteractive -File "$PLUGIN/runtime/windows/shift-estimate.ps1" -Project "$p" -Items "${case#*:}")"
    [ "$got" = "$want" ] || { echo "$name"; echo "bash:"; echo "$want"; echo "PowerShell:"; echo "$got"; return 1; }
  done
}
