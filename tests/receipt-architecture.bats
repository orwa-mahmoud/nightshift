#!/usr/bin/env bats
# The architecture diagram: with receipts.evidence.architecture on, the model keeps one diagram and
# says per item whether it changed; the runtime snapshots each changed version into that item's
# evidence folder at the tick and links every receipt to the diagram as it stood after its item.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
CORE="$PLUGIN/hooks/shared/gate-core.sh"
PULSE="$PLUGIN/hooks/pulse.sh"
PSM1="$PLUGIN/lib/Nightshift.psm1"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }
core() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$LIB" "$CORE" "$@"; }

# diagram <project> <on|off>
diagram() {
  jq --arg v "$2" '.receipts.evidence.architecture = $v' "$1/.nightshift/rules.json" >"$1/.nightshift/rules.next"
  mv "$1/.nightshift/rules.next" "$1/.nightshift/rules.json"
}

tick() {
  sed -i.bak "s/^- \[ \] \*\*$2\./- [x] **$2./" "$1/.nightshift/punch-list.md" && rm -f "$1/.nightshift/punch-list.md.bak"
  lib ns_usage_record "$1/.nightshift" claude claude-opus-5 transcript-incremental /t/a "$2" "input=$2,output=1"
  core ns_gate_usage_sync "$1/.nightshift" "$1" "$1/.nightshift/punch-list.md" "$2"
}

block() { sed -n '/^<!-- nightshift:architecture -->$/,/^<!-- \/nightshift:architecture -->$/p' "$1"; }

# draw <project> <components...> — the diagram as the model would keep it.
draw() {
  local p="$1" c
  shift
  {
    printf '# Architecture\n\nComponents this shift touched.\n\n```mermaid\nflowchart LR\n'
    for c in "$@"; do printf '  %s\n' "$c"; done
    printf '```\n\nLegend: a box is a component; an arrow is a call.\n'
  } >"$p/.nightshift/receipts/architecture.md"
}

three_items() {
  printf '## Items\n- [ ] **1. Add the parser.** <!-- id: aa11 -->\n- [ ] **2. Tune the parser.** <!-- id: bb22 -->\n- [ ] **3. Add the cache.** <!-- id: cc33 -->\n' \
    >"$1/.nightshift/punch-list.md"
  mkdir -p "$1/.nightshift/receipts"
}

@test "an item that changes the structure is snapshotted, and one that does not links the copy before it" {
  p="$(new_project arch-snap)"
  diagram "$p" on
  three_items "$p"
  r="$p/.nightshift/receipts"
  draw "$p" 'cli --> parser'
  printf '# 1. Add the parser.\n\nDone.\n\n- Diagram: updated — added the parser behind the CLI\n' >"$r/01-add-the-parser-aa11.md"
  tick "$p" 1
  cmp "$r/architecture.md" "$r/01-add-the-parser-aa11/architecture.md"
  [ "$(block "$r/01-add-the-parser-aa11.md")" = "$(printf '%s\n' '<!-- nightshift:architecture -->' \
    '**Architecture after this item:** [architecture.md](./01-add-the-parser-aa11/architecture.md)' \
    '<!-- /nightshift:architecture -->')" ]
  # Unchanged: no new copy, and the receipt links the one before it.
  printf '# 2. Tune the parser.\n\nDone.\n\n- Diagram: unchanged — same components, faster loop\n' >"$r/02-tune-the-parser-bb22.md"
  tick "$p" 2
  [ ! -e "$r/02-tune-the-parser-bb22" ]
  block "$r/02-tune-the-parser-bb22.md" | grep -qxF '**Architecture after this item:** [architecture.md](./01-add-the-parser-aa11/architecture.md)'
  # A third item adds a component: its own copy, and the first copy is left as it stood.
  draw "$p" 'cli --> parser' 'parser --> cache'
  printf '# 3. Add the cache.\n\nDone.\n\n- Diagram: updated — added the cache under the parser\n' >"$r/03-add-the-cache-cc33.md"
  tick "$p" 3
  cmp "$r/architecture.md" "$r/03-add-the-cache-cc33/architecture.md"
  ! grep -qF cache "$r/01-add-the-parser-aa11/architecture.md" || false
  # The morning page shows the diagram and the items that changed it.
  run bash "$PLUGIN/runtime/morning-receipt.sh" --project "$p"
  section="$(printf '%s\n' "$output" | sed -n '/^## Architecture$/,/^## /p')"
  [[ "$section" == *'[architecture.md](./architecture.md), as the shift left it:'* ]] || { printf '%s\n' "$output"; return 1; }
  [[ "$section" == *'  parser --> cache'* ]] || false
  [[ "$section" == *'Legend: a box is a component; an arrow is a call.'* ]] || false
  ! printf '%s\n' "$section" | grep -qx '# Architecture' || false
  [[ "$section" == *$'Changed by:\n- 1. Add the parser. — added the parser behind the CLI\n- 3. Add the cache. — added the cache under the parser'* ]] || { printf '%s\n' "$section"; return 1; }
}

@test "with the diagram off there is no step, no copy, no link and no section" {
  p="$(new_project arch-off)"
  three_items "$p"
  r="$p/.nightshift/receipts"
  draw "$p" 'cli --> parser'
  printf '# 1. Add the parser.\n\nDone.\n' >"$r/01-add-the-parser-aa11.md"
  : >"$p/.nightshift/.shift-armed"
  line="$(bash -c '. "$1"; . "$2"; ns_pulse_receipts_start_line "$3" "$4"' _ "$LIB" "$PULSE" "$p" '2. Tune the parser.')"
  [[ "$line" != *Diagram* ]] || false
  [[ "$line" == *'Parked decisions and snags.' ]] || false
  tick "$p" 1
  [ ! -e "$r/01-add-the-parser-aa11" ]
  ! grep -qF 'nightshift:architecture' "$r/01-add-the-parser-aa11.md" || false
  run bash "$PLUGIN/runtime/morning-receipt.sh" --project "$p"
  [[ "$output" != *'## Architecture'* ]] || false
}

@test "with the diagram on, the item-start notice carries the step, in both runtimes" {
  p="$(new_project arch-notice)"
  diagram "$p" on
  three_items "$p"
  line() { bash -c '. "$1"; . "$2"; ns_pulse_receipts_start_line "$3" "$4"' _ "$LIB" "$PULSE" "$p" "$1"; }
  [[ "$(line '1. Add the parser.')" == *'Verification · Outputs · Parked decisions and snags; after the commit and before the tick, update .nightshift/receipts/architecture.md only if this item changed the structure, then write `Diagram: updated — <what changed>` or `Diagram: unchanged — <why>` in the receipt.' ]] || { line '1. Add the parser.'; return 1; }
  command -v pwsh >/dev/null 2>&1 || return 0
  got="$(NS_MODULE="$PSM1" NS_WS="$p" pwsh -NoProfile -NonInteractive -Command '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); Import-Module $env:NS_MODULE -Force -DisableNameChecking; Get-NSPulseReceiptsStartLine -Workspace $env:NS_WS -Label "1. Add the parser."')"
  [ "$got" = "$(line '1. Add the parser.')" ] || { echo "PowerShell: $got"; return 1; }
}

@test "a renamed snapshot folder is followed by the receipts that link it" {
  p="$(new_project arch-rename)"
  diagram "$p" on
  three_items "$p"
  r="$p/.nightshift/receipts"
  draw "$p" 'cli --> parser'
  printf '# 1. Add the parser.\n\nDone.\n\n- Diagram: updated — added the parser\n' >"$r/01-add-the-parser-aa11.md"
  printf '# 2. Tune the parser.\n\nDone.\n\n- Diagram: unchanged — same parts\n' >"$r/02-tune-the-parser-bb22.md"
  tick "$p" 1
  tick "$p" 2
  touch -t 202609240101 "$r/02-tune-the-parser-bb22.md"
  # Between shifts item 1 is retitled; its folder moves and item 2's link follows it.
  rm -f "$p/.nightshift/.shift-armed"
  sed -i.bak 's/Add the parser\./Add the fast parser./' "$p/.nightshift/punch-list.md" && rm -f "$p/.nightshift/punch-list.md.bak"
  lib ns_receipts_rename "$p"
  [ -f "$r/01-add-the-fast-parser-aa11/architecture.md" ]
  block "$r/02-tune-the-parser-bb22.md" | grep -qF '(./01-add-the-fast-parser-aa11/architecture.md)'
  [ -z "$(find "$r/02-tune-the-parser-bb22.md" -newermt '2026-09-24 01:02' 2>/dev/null)" ]
}

@test "PowerShell snapshots, links and renders the section the same way" {
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  p="$(new_project arch-parity)"
  diagram "$p" on
  three_items "$p"
  r="$p/.nightshift/receipts"
  draw "$p" 'cli --> parser'
  printf '# 1. Add the parser.\n\nDone.\n\n- Diagram: updated — added the parser\n' >"$r/01-add-the-parser-aa11.md"
  printf '# 2. Tune the parser.\n\nDone.\n\n- Diagram: unchanged — same parts\n' >"$r/02-tune-the-parser-bb22.md"
  sed -i.bak 's/^- \[ \] \*\*1\./- [x] **1./; s/^- \[ \] \*\*2\./- [x] **2./' "$p/.nightshift/punch-list.md" && rm -f "$p/.nightshift/punch-list.md.bak"
  cp -R "$p" "$BATS_TEST_TMPDIR/arch-parity-ps"
  q="$BATS_TEST_TMPDIR/arch-parity-ps"
  for label in '1. Add the parser.' '2. Tune the parser.'; do
    lib ns_architecture_tick "$p/.nightshift" "$p" "$label"
    NS_MODULE="$PSM1" NS_NS="$q/.nightshift" NS_WS="$q" NS_LABEL="$label" pwsh -NoProfile -NonInteractive -Command \
      'Import-Module $env:NS_MODULE -Force -DisableNameChecking; Invoke-NSArchitectureTick $env:NS_NS $env:NS_WS $env:NS_LABEL'
  done
  for f in 01-add-the-parser-aa11.md 02-tune-the-parser-bb22.md 01-add-the-parser-aa11/architecture.md; do
    cmp "$r/$f" "$q/.nightshift/receipts/$f" || { diff "$r/$f" "$q/.nightshift/receipts/$f"; return 1; }
  done
  [ ! -e "$q/.nightshift/receipts/02-tune-the-parser-bb22" ]
  bash_section="$(bash "$PLUGIN/runtime/morning-receipt.sh" --project "$p" | sed -n '/^## Architecture$/,/^## /p' | sed '$d')"
  ps_section="$(NS_MODULE="$PSM1" NS_WS="$q" pwsh -NoProfile -NonInteractive -Command \
    '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); Import-Module $env:NS_MODULE -Force -DisableNameChecking; Get-NSMorningReceipt -Workspace $env:NS_WS' |
    sed -n '/^## Architecture$/,/^## /p' | sed '$d')"
  [ -n "$bash_section" ]
  [ "$bash_section" = "$ps_section" ] || { echo "bash:"; echo "$bash_section"; echo "PowerShell:"; echo "$ps_section"; return 1; }
}

@test "native Windows covers the architecture diagram, and its suite is registered" {
  grep -qF 'receipt-architecture-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  run pwsh -NoProfile -File "$BATS_TEST_DIRNAME/windows/receipt-architecture-logic.ps1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}
