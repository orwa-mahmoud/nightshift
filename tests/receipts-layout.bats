#!/usr/bin/env bats
# Per-item receipts: slug, tick block, index, window, archive, migration.

load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
CORE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/gate-core.sh"
SLUGS="$BATS_TEST_DIRNAME/fixtures/receipts/slugs.tsv"
SCHEMA="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/nightshift-rules.schema.json"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }
core() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$LIB" "$CORE" "$@"; }

ps_ready() { command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"; }

@test "bash and PowerShell emit the same receipt slug for each fixture title" {
  while IFS=$'\t' read -r title want; do
    [ -n "$title" ] || continue
    got="$(lib ns_receipt_slug "$title")"
    [ "$got" = "$want" ] || { echo "posix slug '$title' -> '$got' want '$want'"; return 1; }
  done <"$SLUGS"

  ps_ready
  while IFS=$'\t' read -r title want; do
    [ -n "$title" ] || continue
    win="$(pwsh -NoProfile -NonInteractive -Command \
      "Import-Module '$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1' -Force -DisableNameChecking; Get-NSReceiptSlug -Text '$title'")"
    [ "$win" = "$want" ] || { echo "win slug '$title' -> '$win' want '$want'"; return 1; }
  done <"$SLUGS"
}

@test "a tick creates the item receipt with the scaled usage block" {
  p="$(new_project receipts-tick)"
  printf '## Items\n- [x] **2. Make the packed Node-only build reproducible.**\n' \
    >"$p/.nightshift/punch-list.md"
  lib ns_usage_record "$p/.nightshift" claude claude-opus-5 transcript-incremental /t/a 10 \
    'input=122,cache_write=55458,cache_read=47457543,output=42091,reasoning=7332'
  core ns_gate_usage_sync "$p/.nightshift" "$p" "$p/.nightshift/punch-list.md" 1

  f="$p/.nightshift/receipts/2-make-the-packed-node-only-build-reproducible.md"
  [ -f "$f" ]
  grep -qF '# 2. Make the packed Node-only build reproducible.' "$f"
  grep -qF '**Usage:** input 122 · cache_write 55.5k · cache_read 47.5M · output 42.1k · reasoning 7.3k' "$f"
  grep -qF 'exact: 122 / 55458 / 47457543 / 42091 / 7332' "$f"
  grep -qF '**Duration:**' "$f"
  grep -q $'\t2. Make the packed Node-only build reproducible.\t' "$p/.nightshift/usage/marks.tsv"
}

@test "the index lists every item and is rewritten at tick" {
  p="$(new_project receipts-index)"
  printf 'Date: 2026-09-09\n\n## Items\n- [x] **2. Make the packed Node-only build reproducible.**\n- [ ] **3. Ship it — already reviewed**\n' \
    >"$p/.nightshift/punch-list.md"
  core ns_gate_usage_sync "$p/.nightshift" "$p" "$p/.nightshift/punch-list.md" 1
  idx="$p/.nightshift/receipts/README.md"
  [ -f "$idx" ]
  grep -qF '# Receipts — 2026-09-09' "$idx"
  grep -qF '| Item | State | **Tokens** | **Time** | Receipt |' "$idx"
  grep -qF '| 2. Make the packed Node-only build reproducible. | ticked |' "$idx"
  grep -qF '| 3. Ship it | open |' "$idx"
  grep -qF './2-make-the-packed-node-only-build-reproducible.md' "$idx"
  grep -qF '| **Totals** |' "$idx"
}

@test "editing the receipt file restarts the cadence window" {
  p="$(new_project receipts-window)"
  printf '## Items\n- [ ] **2. Make the packed Node-only build reproducible.**\n' \
    >"$p/.nightshift/punch-list.md"
  mkdir -p "$p/.nightshift/usage" "$p/.nightshift/receipts"
  printf '%s\tarm\t\n' "$(($(date +%s) - 3600))" >"$p/.nightshift/usage/marks.tsv"
  f="$p/.nightshift/receipts/2-make-the-packed-node-only-build-reproducible.md"
  printf '# 2. Make the packed Node-only build reproducible.\n\ndraft.\n' >"$f"
  lib ns_usage_window "$p/.nightshift" '2. Make the packed Node-only build reproducible.' "$f"
  first="$(cut -f1 "$p/.nightshift/usage/window")"
  printf 'receipts: due\n' >"$p/.nightshift/.receipt-due"
  printf '\nprogress.\n' >>"$f"
  lib ns_usage_window "$p/.nightshift" '2. Make the packed Node-only build reproducible.' "$f"
  second="$(cut -f1 "$p/.nightshift/usage/window")"
  [ "$second" -ge "$first" ]
  [ ! -f "$p/.nightshift/.receipt-due" ]
}

@test "migrate-state renames the report block and moves shift-report.md" {
  p="$(new_project receipts-mig)"
  rm -f "$p/.nightshift/.shift-armed"
  jq '.report = {enabled:true,legacyItemReceipts:true,progressMode:"time"} | del(.receipts)' \
    "$p/.nightshift/rules.json" >"$p/.nightshift/rules.next" && mv "$p/.nightshift/rules.next" "$p/.nightshift/rules.json"
  printf 'the old page\n' >"$p/.nightshift/shift-report.md"
  mkdir -p "$p/.nightshift/receipts"
  printf 'keep\n' >"$p/.nightshift/receipts/20260902T190000Z-attended-evidence-program.md"
  lib ns_migrate_receipts_layout "$p"
  ! jq -e '.report' "$p/.nightshift/rules.json" >/dev/null
  jq -e '.receipts.enabled == true' "$p/.nightshift/rules.json"
  ! jq -e '.receipts | has("legacyItemReceipts")' "$p/.nightshift/rules.json" >/dev/null
  [ -f "$p/.nightshift/receipts/previous-report.md" ]
  grep -qxF 'the old page' "$p/.nightshift/receipts/previous-report.md"
  [ ! -e "$p/.nightshift/shift-report.md" ]
  grep -qxF 'keep' "$p/.nightshift/receipts/20260902T190000Z-attended-evidence-program.md"
}

@test "the schema rejects legacyItemReceipts" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  python3 - "$SCHEMA" <<'PY'
import json, sys
schema = json.load(open(sys.argv[1], encoding="utf-8"))
block = schema["properties"]["receipts"]
assert "legacyItemReceipts" not in block["properties"]
assert "report" not in schema["properties"]
print("ok")
PY
}

@test "check-report is an alias that names check-receipts" {
  p="$(new_project receipts-alias)"
  run "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/check-report.sh" --project "$p" -h
  printf '%s' "$output$stderr" | grep -qF 'ns check-receipts'
}
