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
    TZ=UTC lib ns_receipt_add_session "$f" '6. Runtime only.' "$sid" "$start" "$end" "$work" "$in" "$out" "$ended"
  done < <(rows sessions.tsv)
  diff "$FIX/sessions-expected.md" "$f"
}

@test "progress updates fall due as the fixture says on Bash" {
  local mode usage minutes spent want p got n=0
  while IFS=$'\t' read -r mode usage minutes spent want; do
    n=$((n + 1))
    p="$BATS_TEST_TMPDIR/due-$n"
    mkdir -p "$p/.nightshift/usage"
    printf '## Items\n- [ ] **P01 - open.**\n' >"$p/.nightshift/punch-list.md"
    jq -n --arg m "$mode" --arg u "$usage" '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",
      createdAt:"2026-09-02T00:00:00Z",source:"composition",verificationLevel:"none",
      toolingPolicy:"existing-tools",
      receipts:{progressMode:$m,usage:$u,progressMinutes:20,progressTokens:1000}}' \
      >"$p/.nightshift/shift-policy.json"
    printf '%s\tarm\t\n' "$(($(date +%s) - minutes * 60))" >"$p/.nightshift/usage/marks.tsv"
    [ "$spent" = - ] ||
      lib ns_usage_record "$p/.nightshift" claude m transcript-incremental /t/a 1 "input=$spent,output=0"
    if lib ns_usage_progress_due "$p" P01; then got=yes; else got=no; fi
    [ "$got" = "$want" ] || { echo "$mode $usage $minutes $spent: got $got, want $want"; return 1; }
  done < <(rows progress-due.tsv)
}

@test "shifts are filed into the fixture's archive folders on Bash" {
  local action day id want got p="$BATS_TEST_TMPDIR/folders"
  mkdir -p "$p/.nightshift"
  while IFS=$'\t' read -r action day id want; do
    if [ "$action" = old ]; then
      mkdir -p "$p/.nightshift/archive/$day"
      continue
    fi
    if [ "$action" = records ]; then
      mkdir -p "$p/.nightshift/archive/$day"
      printf 'an earlier night\n' >"$p/.nightshift/archive/$day/shipped.md"
      continue
    fi
    got="$(lib ns_archive_dir "$p" "$day" "$id")"
    [ "${got##*/}" = "$want" ] || { echo "$day $id: got ${got##*/}, want $want"; return 1; }
  done < <(rows archive-folders.tsv)
}

@test "an ended shift's punch list is filed and trimmed as the fixture says on Bash" {
  local p="$BATS_TEST_TMPDIR/punch-archive"
  mkdir -p "$p/.nightshift"
  cp "$FIX/punch-archive/list.md" "$p/.nightshift/punch-list.md"
  lib ns_archive_punch_list "$p" "$p/.nightshift/archive/2026-09-05" 1111222233334444 2026-09-05 >/dev/null
  cmp "$FIX/punch-archive/archived.md" "$p/.nightshift/archive/2026-09-05/punch-list.md"
  cmp "$FIX/punch-archive/live.md" "$p/.nightshift/punch-list.md"
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

@test "paused time matches the fixture on Bash" {
  local marks pauses from to between reasons n=0 site ns usage pair epoch reason
  local got_between got_reasons
  while IFS=$'\t' read -r marks pauses from to between reasons; do
    n=$((n + 1))
    site="$BATS_TEST_TMPDIR/pauses-$n"
    ns="$site/.nightshift"
    mkdir -p "$ns"
    usage="$(lib ns_usage_dir "$ns")"
    mkdir -p "$usage"
    : >"$usage/marks.tsv"
    for epoch in $marks; do
      printf '%s\tx\n' "$epoch" >>"$usage/marks.tsv"
    done
    : >"$usage/pauses.tsv"
    local -a pairs=()
    IFS='|' read -ra pairs <<<"$pauses"
    for pair in "${pairs[@]}"; do
      epoch="${pair%%=*}"
      reason="${pair#*=}"
      printf '%s\t%s\n' "$epoch" "$reason" >>"$usage/pauses.tsv"
    done
    got_between="$(lib ns_usage_paused_between "$ns" "$from" "$to" || true)"
    got_between="${got_between//$'\t'/=}"
    [ -n "$got_between" ] || got_between=none
    got_reasons="$(lib ns_usage_pauses_by_reason "$ns" "$from" "$to" | tr '\t' '=' | paste -sd'|' -)"
    [ -n "$got_reasons" ] || got_reasons=none
    [ "$got_between" = "$between" ] || { echo "case $n between: got $got_between, want $between"; return 1; }
    [ "$got_reasons" = "$reasons" ] || { echo "case $n reasons: got $got_reasons, want $reasons"; return 1; }
  done < <(rows pauses.tsv)
}

@test "hardhat decisions match the fixture on Bash" {
  local name state envset command want p setting reason
  local -a settings=()
  while IFS=$'\t' read -r name state envset command want; do
    p="$(new_project "hh-$name")"
    if [ "$state" = done ]; then
      punch_done "$p"
    else
      punch_open "$p"
    fi
    settings=()
    if [ "$envset" != - ]; then
      IFS=';' read -ra settings <<<"$envset"
    fi
    run hardhat_bash "$p" "$command" "${settings[@]}"
    if [ "$want" = allow ]; then
      is_allow || { echo "$name: status $status output $output"; return 1; }
    else
      is_deny "$output" || { echo "$name deny: $output"; return 1; }
      reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
      case "$reason" in
        "$want"*) ;;
        *) echo "$name: got $reason"; echo "want prefix $want"; return 1 ;;
      esac
    fi
  done < <(rows hardhat-decisions.tsv)
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
