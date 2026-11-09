#!/usr/bin/env bats
# One owner's customisation, end to end: a three-line UI recipe of their own, a receipt titled
# Deliverables, a required screenshot, and a profile that changes one unrelated setting. Each step
# goes through the entry point an owner or the gate uses.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
CHECK="$PLUGIN/lib/evidence-check.sh"
INDEX="$PLUGIN/runtime/catalog-index.sh"
APPLY="$PLUGIN/runtime/apply-profile.sh"
ARCHIVE="$PLUGIN/runtime/archive-receipts.sh"
PNG=$'\211PNG\r\n\032\nxx'

setup() {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/no-owner"
  export APPDATA="$XDG_CONFIG_HOME"
  mkdir -p "$XDG_CONFIG_HOME"
}

owner_project() { # <name> <recipe-folder relative to .nightshift>
  local p
  p="$(new_project "$1")"
  rm -f "$p/.nightshift/.shift-armed"
  printf '2\n' >"$p/.nightshift/state-version"
  mkdir -p "$p/.nightshift/$2" "$p/notes"
  printf '# UI — what I check on a screen\nCapture the changed screen at 375 px as checkout.png.\nOpen it and compare it with the item.\n' \
    >"$p/.nightshift/$2/ui.md"
  printf '# {item}\n\n## Deliverables\n\n| What | Where |\n| --- | --- |\n' >"$p/notes/receipt.md"
  jq '.receipts.templatePath = "notes/receipt.md"' "$p/.nightshift/rules.json" >"$p/rules.tmp"
  mv "$p/rules.tmp" "$p/.nightshift/rules.json"
  cat >"$p/.nightshift/punch-list.md" <<'EOF'
## Items

- [x] **1. Restyle checkout.** <!-- id: ab12 -->
  - Evidence: kind: ui, the screen `checkout.png` check: block
EOF
  printf '%s' "$p"
}

write_receipt() { # <receipt>
  mkdir -p "$(dirname "$1")"
  printf '# 1. Restyle checkout.\n\n## Deliverables\n\n| What | Where |\n| --- | --- |\n| Screen | [checkout](%s/checkout.png) |\n' \
    "$(basename "${1%.md}")" >"$1"
}

@test "an owner's recipe, receipt layout and profile survive a round trip, and the screenshot gates and files" {
  p="$(owner_project own-bash catalogs/evidence)"

  # The project recipe wins over the shipped ui kind, three lines and all.
  run bash "$INDEX" --catalog evidence --project "$p" --path ui
  [ "$status" -eq 0 ]
  [ "$output" = "$p/.nightshift/catalogs/evidence/ui.md" ]

  # A profile changes one unrelated setting and keeps the owner's receipt template.
  run bash "$APPLY" --project "$p" --profile no-push --mode replace --apply
  [ "$status" -eq 0 ]
  jq -e '.forbiddenCommands == "git .*push" and .receipts.templatePath == "notes/receipt.md"' \
    "$p/.nightshift/rules.json" >/dev/null

  # Reopened from disk: the recipe is still selected and the setting resolves.
  run bash "$INDEX" --catalog evidence --project "$p" --path ui
  [ "$output" = "$p/.nightshift/catalogs/evidence/ui.md" ]
  run bash "$PLUGIN/runtime/shift-policy.sh" --project "$p" resolve --table
  [ "$status" -eq 0 ]

  # The missing screenshot holds clock-out; supplying it releases the gate.
  # shellcheck disable=SC1090
  . "$LIB"
  # shellcheck disable=SC1090
  . "$CHECK"
  receipt="$(ns_receipt_path "$p" "1. Restyle checkout." ab12)"
  write_receipt "$receipt"
  run ns_evidence_hold "$p" "$p/.nightshift/punch-list.md"
  printf '%s\n' "$output" | grep -qF 'missing checkout.png'
  mkdir -p "${receipt%.md}"
  printf '%s' "$PNG" >"${receipt%.md}/checkout.png"
  run ns_evidence_hold "$p" "$p/.nightshift/punch-list.md"
  [ -z "$output" ]
  grep -qxF '## Deliverables' "$receipt"

  # After Archive the reviewer still opens the screenshot from the filed receipt.
  ended="$(ns_layout_path "$p/.nightshift" ended)"
  mkdir -p "$(dirname "$ended")"
  : >"$ended"
  run bash "$ARCHIVE" --project "$p" --date 2026-11-08 --retire "$(basename "$receipt")"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  filed="$p/.nightshift/archive/2026-11-08/receipts/$(basename "$receipt")"
  [ -f "$filed" ]
  grep -qxF '## Deliverables' "$filed"
  link="$(sed -n 's/.*\[checkout\](\([^)]*\)).*/\1/p' "$filed")"
  [ -f "$(dirname "$filed")/$link" ]
}

@test "the same round trip on PowerShell, in a workspace that keeps its recipe in the older folder" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  p="$(owner_project own-ps evidence/kinds)"
  run pwsh -NoProfile -File "$PLUGIN/runtime/windows/catalog-index.ps1" --catalog evidence --project "$p" --path ui
  [ "$status" -eq 0 ]
  [ "$output" = "$p/.nightshift/evidence/kinds/ui.md" ]

  run pwsh -NoProfile -File "$PLUGIN/runtime/windows/apply-profile.ps1" -Project "$p" -Profile no-push -Mode replace -Apply
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  jq -e '.forbiddenCommands == "git .*push" and .receipts.templatePath == "notes/receipt.md"' \
    "$p/.nightshift/rules.json" >/dev/null

  receipt="$(pwsh -NoProfile -Command "Import-Module '$PLUGIN/lib/Nightshift.psm1' -Force -DisableNameChecking; Get-NSReceiptPath '$p' '1. Restyle checkout.' ab12")"
  write_receipt "$receipt"
  hold() { pwsh -NoProfile -Command "Import-Module '$PLUGIN/lib/Nightshift.psm1' -Force -DisableNameChecking; Get-NSEvidenceHold -Workspace '$p' -PunchList '$p/.nightshift/punch-list.md'"; }
  run hold
  printf '%s\n' "$output" | grep -qF 'missing checkout.png'
  mkdir -p "${receipt%.md}"
  printf '%s' "$PNG" >"${receipt%.md}/checkout.png"
  run hold
  [ -z "$output" ]

  ended="$(bash -c '. "$1"; ns_layout_path "$2/.nightshift" ended' _ "$LIB" "$p")"
  mkdir -p "$(dirname "$ended")"
  : >"$ended"
  run pwsh -NoProfile -File "$PLUGIN/runtime/windows/archive-receipts.ps1" -Project "$p" -Date 2026-11-08 -Retire "$(basename "$receipt")"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  filed="$p/.nightshift/archive/2026-11-08/receipts/$(basename "$receipt")"
  grep -qxF '## Deliverables' "$filed"
  link="$(sed -n 's/.*\[checkout\](\([^)]*\)).*/\1/p' "$filed")"
  [ -f "$(dirname "$filed")/$link" ]
}
