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
  grep -qF '| input | 122 |' "$f"
  grep -qF '| cache write | 55.5k |' "$f"
  grep -qF '| cache read | 47.5M |' "$f"
  grep -qF '| output | 42.1k |' "$f"
  grep -qF '| reasoning | 7.3k |' "$f"
  grep -qF '<!-- tokens 122 55458 47457543 42091 7332 -->' "$f"
  grep -qF '| Time |' "$f"
  ! grep -qF 'exact:' "$f" || false
  grep -q $'\t2. Make the packed Node-only build reproducible.\t' "$p/.nightshift/usage/marks.tsv"
  # Tokens and Time sit under the heading, before any later narrative.
  awk '
    $0 == "# 2. Make the packed Node-only build reproducible." { head = NR }
    /^\| Tokens \|/ { usage = NR }
    /^\| Time \|/ { dur = NR }
    END { if (!(head && usage && dur && head < usage && usage < dur)) exit 1 }
  ' "$f"
}

@test "an unbolded ticked line writes usage into the item file, not an x- sidecar" {
  p="$(new_project receipts-unbold)"
  printf '## Items\n- [x] 1. Title without bold.\n' >"$p/.nightshift/punch-list.md"
  lib ns_usage_record "$p/.nightshift" claude claude-opus-5 transcript-incremental /t/a 10 \
    'input=10,cache_write=0,cache_read=0,output=4,reasoning=1'
  core ns_gate_usage_sync "$p/.nightshift" "$p" "$p/.nightshift/punch-list.md" 1
  [ -f "$p/.nightshift/receipts/1-title-without-bold.md" ]
  [ ! -e "$p/.nightshift/receipts/x-1-title-without-bold.md" ]
  grep -qF '<!-- tokens 10 0 0 4 1 -->' "$p/.nightshift/receipts/1-title-without-bold.md"
}

@test "the index reads an old x- sidecar when the item file has no exact line" {
  p="$(new_project receipts-sidecar)"
  printf 'Date: 2026-09-14\n\n## Items\n- [x] **1. Title without bold.**\n' \
    >"$p/.nightshift/punch-list.md"
  mkdir -p "$p/.nightshift/receipts"
  printf '# 1. Title without bold.\n\ndone.\n' >"$p/.nightshift/receipts/1-title-without-bold.md"
  printf '# leftover\n\n**Usage:** input 10 · cache_write 0 · cache_read 0 · output 4 · reasoning 1\n  Source: claude claude-opus-5, cumulative counters, segments 1; exact: 10 / 0 / 0 / 4 / 1\n**Duration:** 5m 00s\n' \
    >"$p/.nightshift/receipts/x-1-title-without-bold.md"
  lib ns_receipts_write_index "$p"
  grep -qF '| 1. Title without bold. | ticked | **input 10 · cache_write 0 · cache_read 0 · output 4 · reasoning 1** | **5m 0s working** |' \
    "$p/.nightshift/receipts/README.md"
}

@test "the index Time column lists working and paused, and totals add both" {
  p="$(new_project receipts-time)"
  printf 'Date: 2026-09-14\n\n## Items\n- [x] **1. First.**\n- [x] **2. Second.**\n' \
    >"$p/.nightshift/punch-list.md"
  mkdir -p "$p/.nightshift/receipts"
  printf '# 1. First.\n\n**Usage:** input 1 · cache_write 0 · cache_read 0 · output 1 · reasoning 0\n  Source: claude claude-opus-5, cumulative counters, segments 1; exact: 1 / 0 / 0 / 1 / 0\n**Duration:** 30m 0s working (wall 1h 0m; paused 30m 0s, owner stop-work); 2026-09-14T10:00Z → 2026-09-14T11:00Z\n' \
    >"$p/.nightshift/receipts/1-first.md"
  printf '# 2. Second.\n\n**Usage:** input 2 · cache_write 0 · cache_read 0 · output 2 · reasoning 0\n  Source: claude claude-opus-5, cumulative counters, segments 1; exact: 2 / 0 / 0 / 2 / 0\n**Duration:** 10m 0s working; 2026-09-14T11:00Z → 2026-09-14T11:10Z\n' \
    >"$p/.nightshift/receipts/2-second.md"
  lib ns_receipts_write_index "$p"
  grep -qF '| 1. First. | ticked | **input 1 · cache_write 0 · cache_read 0 · output 1 · reasoning 0** | **30m 0s working · 30m 0s paused** |' \
    "$p/.nightshift/receipts/README.md"
  grep -qF '| 2. Second. | ticked | **input 2 · cache_write 0 · cache_read 0 · output 2 · reasoning 0** | **10m 0s working** |' \
    "$p/.nightshift/receipts/README.md"
  grep -qF '| **Totals** |  | **input 3 · cache_write 0 · cache_read 0 · output 3 · reasoning 0** | **40m 0s working · 30m 0s paused** |' \
    "$p/.nightshift/receipts/README.md"
}

@test "the index reads raw token integers from the hidden comment" {
  p="$(new_project receipts-comment)"
  printf 'Date: 2026-09-14\n\n## Items\n- [x] **1. First.**\n' \
    >"$p/.nightshift/punch-list.md"
  mkdir -p "$p/.nightshift/receipts"
  printf '%s\n' \
    '# 1. First.' \
    '' \
    '| Tokens | Amount |' \
    '| --- | ---: |' \
    '| input | 1 |' \
    '| cache write | 0 |' \
    '| cache read | 0 |' \
    '| output | 1 |' \
    '| reasoning | 0 |' \
    '' \
    '<!-- tokens 1 0 0 1 0 -->' \
    'claude claude-opus-5 · 1 segment. Cache reads and cache writes are separate from the input figure; reasoning is inside output.' \
    '' \
    '| Time | |' \
    '| --- | --- |' \
    '| working | 10m 0s |' \
    '| wall | 10m 0s |' \
    >"$p/.nightshift/receipts/1-first.md"
  lib ns_receipts_write_index "$p"
  grep -qF '| 1. First. | ticked | **input 1 · cache_write 0 · cache_read 0 · output 1 · reasoning 0** | **10m 0s working** |' \
    "$p/.nightshift/receipts/README.md"
}

@test "the index lists every item and is rewritten at tick" {
  p="$(new_project receipts-index)"
  printf 'Date: 2026-09-09\n\n## Items\n- [x] **2. Make the packed Node-only build reproducible.**\n- [ ] **3. Ship it — already reviewed**\n' \
    >"$p/.nightshift/punch-list.md"
  core ns_gate_usage_sync "$p/.nightshift" "$p" "$p/.nightshift/punch-list.md" 1
  idx="$p/.nightshift/receipts/README.md"
  [ -f "$idx" ]
  grep -qF '# Receipts — 2026-09-09' "$idx"
  grep -qF '| Item | State | **Usage** | **Time** | Receipt |' "$idx"
  grep -qF '| 2. Make the packed Node-only build reproducible. | ticked |' "$idx"
  grep -qF '| 3. Ship it | open |' "$idx"
  grep -qF './2-make-the-packed-node-only-build-reproducible.md' "$idx"
  grep -qF '| **Totals** |' "$idx"
}

@test "the live index links each shift summary above the item table, the same on both runtimes" {
  p="$(new_project receipts-index-morning)"
  r="$p/.nightshift/receipts"
  mkdir -p "$r"
  printf 'Date: 2026-09-09\n\n## Items\n- [x] **1. Fix the resolver.**\n- [ ] **2. Trim the bundle.**\n' \
    >"$p/.nightshift/punch-list.md"
  printf '# Morning receipt\n' >"$r/morning-2026-09-09-bbb.md"
  printf '# Morning receipt\n' >"$r/morning-2026-09-09-aaa.md"
  printf 'kept\n' >"$r/morning-2026-09-09-aaa.original.md"
  lib ns_receipts_write_index "$p"
  idx="$r/README.md"
  [ "$(sed -n 3p "$idx")" = 'Shift summary: [morning-2026-09-09-aaa.md](./morning-2026-09-09-aaa.md)' ]
  [ "$(sed -n 5p "$idx")" = 'Shift summary: [morning-2026-09-09-bbb.md](./morning-2026-09-09-bbb.md)' ]
  [ "$(sed -n 7p "$idx")" = '| Item | State | **Usage** | **Time** | Receipt |' ]
  ! grep -qF 'original' "$idx" || false
  ! grep -qF '| morning-' "$idx" || false

  ps_ready
  cp "$idx" "$p/bash-index.md"
  rm -f "$idx"
  pwsh -NoProfile -NonInteractive -Command \
    "Import-Module '$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1' -Force -DisableNameChecking; Write-NSReceiptsIndex '$p'"
  diff -u "$p/bash-index.md" "$idx"
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
  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/migrate-state.sh" --project "$p" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qF 'move      shift-report.md -> receipts/previous-report.md'
  printf '%s\n' "$output" | grep -qF 'rename    rules.json: report -> receipts'
  ! jq -e '.report' "$p/.nightshift/rules.json" >/dev/null || false
  jq -e '.receipts.enabled == true' "$p/.nightshift/rules.json"
  ! jq -e '.receipts | has("legacyItemReceipts")' "$p/.nightshift/rules.json" >/dev/null || false
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

@test "check-receipts is an alias that names check-report" {
  p="$(new_project receipts-alias)"
  run "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/check-receipts.sh" --project "$p" -h
  printf '%s' "$output$stderr" | grep -qF 'ns check-report'
}
