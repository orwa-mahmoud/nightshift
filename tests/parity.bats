#!/usr/bin/env bats
# One fixture set, two runtimes. Every row in tests/fixtures/parity/ is an input and the output the
# Bash and the PowerShell implementation must both produce. This file runs the Bash half;
# tests/windows/parity-logic.ps1 runs the same rows through the PowerShell module.

load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
CORE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/gate-core.sh"
FIX="$BATS_TEST_DIRNAME/fixtures/parity"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }
core() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$LIB" "$CORE" "$@"; }

# rows <file> — the fixture's cases, without comments or blank lines.
rows() { grep -v -e '^#' -e '^$' "$FIX/$1"; }

@test "usage numbers scale to the fixture on Bash" {
  local n want got
  while IFS=$'\t' read -r n want; do
    got="$(lib ns_usage_scale "$n")"
    [ "$got" = "$want" ] || { echo "$n: got $got, want $want"; return 1; }
  done < <(rows usage-scale.tsv)
}

@test "receipt basenames match the fixture on Bash" {
  local label want got
  while IFS=$'\t' read -r label want; do
    got="$(lib ns_receipt_basename "$label")"
    [ "$got" = "$want" ] || { echo "$label: got $got, want $want"; return 1; }
  done < <(rows receipt-basenames.tsv)
}

@test "receipts are listed in the fixture's order on Bash" {
  local names want got
  local -a list
  while IFS=$'\t' read -r names want; do
    read -ra list <<<"$names"
    got="$(printf '/r/%s\n' "${list[@]}" | lib ns_receipts_item_order | sed 's#^/r/##' | paste -sd' ' -)"
    [ "$got" = "$want" ] || { echo "got $got"; echo "want $want"; return 1; }
  done < <(rows receipt-order.tsv)
}

@test "receipt digests match the fixture on Bash" {
  local text want got
  while IFS=$'\t' read -r text want; do
    printf '%b' "$text" >"$BATS_TEST_TMPDIR/receipt.md"
    got="$(lib ns_usage_receipt_hash "$BATS_TEST_TMPDIR/receipt.md")"
    [ "$got" = "$want" ] || { echo "$text: got $got, want $want"; return 1; }
  done < <(rows receipt-hash.tsv)
}

@test "item labels and ids match the fixture on Bash" {
  local line label id got
  while IFS=$'\t' read -r line label id; do
    printf '## Items\n%s\n' "$line" >"$BATS_TEST_TMPDIR/list.md"
    got="$(lib ns_item_rows "$BATS_TEST_TMPDIR/list.md")"
    [ "$got" = "$label	$id" ] || { echo "$line: got '$got', want '$label	$id'"; return 1; }
  done < <(rows item-labels.tsv)
}

@test "a receipt's Sessions table renders the fixture on Bash" {
  local sid start end work in out ended f="$BATS_TEST_TMPDIR/receipt.md"
  while IFS=$'\t' read -r sid start end work in out ended; do
    lib ns_receipt_add_session "$f" '6. Runtime only.' "$sid" "$start" "$end" "$work" "$in" "$out" "$ended"
  done < <(rows sessions.tsv)
  diff "$FIX/sessions-expected.md" "$f"
}

@test "punch-list counts, tick labels, and digests match the fixture on Bash" {
  local file open ticked l1 l2 l3 contract items list
  while IFS=$'\t' read -r file open ticked l1 l2 l3 contract items; do
    list="$FIX/punch/$file"
    [ "$(lib ns_open_boxes "$list")" = "$open" ] || { echo "$file open"; return 1; }
    [ "$(lib ns_ticked_boxes "$list")" = "$ticked" ] || { echo "$file ticked"; return 1; }
    [ "$(core ns_gate_ticked_labels "$list" | paste -sd'|' -)" = "$l1|$l2|$l3" ] \
      || { echo "$file labels"; return 1; }
    [ "$(lib ns_punch_contract_digest "$list")" = "$contract" ] || { echo "$file contract"; return 1; }
    [ "$(lib ns_punch_items_digest "$list")" = "$items" ] || { echo "$file items"; return 1; }
  done < <(rows punch.tsv)
}

@test "the PowerShell half reads the same fixtures and runs in the Windows suite" {
  grep -qF 'fixtures/parity' "$BATS_TEST_DIRNAME/windows/parity-logic.ps1"
  grep -qF 'parity-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$BATS_TEST_DIRNAME/windows/parity-logic.ps1"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
