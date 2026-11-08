#!/usr/bin/env bats
# Named evidence: check off leaves a tick alone, and block names a file that is not present.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
LIB="$ROOT/plugins/nightshift/lib/lib.sh"
CHECK="$ROOT/plugins/nightshift/lib/evidence-check.sh"
PS1="$ROOT/plugins/nightshift/lib/evidence-check.ps1"
MOD="$ROOT/plugins/nightshift/lib/Nightshift.psm1"

setup() {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/no-owner"
  export APPDATA="$BATS_TEST_TMPDIR/no-owner"
  mkdir -p "$XDG_CONFIG_HOME"
  # shellcheck disable=SC1090
  . "$LIB"
  # shellcheck disable=SC1090
  . "$CHECK"
}

write_item() { # <project> <evidence-line>
  cat >"$1/.nightshift/punch-list.md" <<EOF
## Items

- [x] **Shot.** <!-- id: ab12 -->
  - Evidence: $2
EOF
}

@test "check off ignores a missing file, and block names it" {
  p="$(new_project evidence-off)"
  punch="$p/.nightshift/punch-list.md"
  write_item "$p" 'the screen `shot.png`'
  run ns_evidence_problems "$p" "$punch" "Shot."
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run ns_evidence_hold "$p" "$punch"
  [ -z "$output" ]

  write_item "$p" 'the screen `shot.png` check: block'
  run ns_evidence_problems "$p" "$punch" "Shot."
  [ "$output" = "missing shot.png" ]
  run ns_evidence_hold "$p" "$punch"
  printf '%s\n' "$output" | grep -qF 'Shot. is ticked and its evidence is not present: missing shot.png'

  receipt="$(ns_receipt_path "$p" "Shot." ab12)"
  dir="${receipt%.md}"
  mkdir -p "$dir"
  printf 'not an image' >"$dir/shot.png"
  run ns_evidence_problems "$p" "$punch" "Shot."
  [ "$output" = "type shot.png" ]
  printf '\211PNG\r\n\032\nxx' >"$dir/shot.png"
  run ns_evidence_problems "$p" "$punch" "Shot."
  [ -z "$output" ]

  ln -s shot.png "$dir/other.png"
  write_item "$p" 'the screen `other.png` check: block'
  run ns_evidence_problems "$p" "$punch" "Shot."
  [ "$output" = "link other.png" ]
  : >"$dir/notes.txt"
  write_item "$p" 'the screen `notes.txt` check: block'
  run ns_evidence_problems "$p" "$punch" "Shot."
  [ "$output" = "empty notes.txt" ]

  write_item "$p" 'the screen `shot.png` check: block review: on'
  run ns_evidence_problems "$p" "$punch" "Shot."
  [ "$output" = "reviewed" ]
  mkdir -p "$(dirname "$receipt")"
  printf '## Reviewed\n\nThe shot shows the change.\n' >"$receipt"
  run ns_evidence_problems "$p" "$punch" "Shot."
  [ -z "$output" ]

  write_item "$p" 'the screen kind: ui check: report'
  rm -f "$dir/shot.png"
  run ns_evidence_problems "$p" "$punch" "Shot."
  [ "$output" = "pattern ui" ]
  run ns_evidence_hold "$p" "$punch"
  [ -z "$output" ]

  write_item "$p" 'the screen kind: refactor check: block'
  run ns_evidence_problems "$p" "$punch" "Shot."
  [ -z "$output" ]
  run ns_evidence_receipt_text "$p" "$punch" "Shot."
  [ "$output" = "Nothing mechanical to check." ]
  run ns_evidence_hold "$p" "$punch"
  [ -z "$output" ]
}

@test "PowerShell names the same missing file" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  p="$(new_project evidence-ps)"
  write_item "$p" 'the screen `shot.png` check: block'
  run pwsh -NoProfile -Command "Import-Module '$MOD' -Force -DisableNameChecking; . '$PS1'; Get-NSEvidenceHold '$p' '$p/.nightshift/punch-list.md'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'Shot. is ticked and its evidence is not present: missing shot.png' \
    || { printf '%s\n' "$output"; return 1; }
}

@test "check off leaves the receipt alone, and report names the missing file without blocking" {
  p="$(new_project evidence-report)"
  punch="$p/.nightshift/punch-list.md"
  write_item "$p" 'the screen `shot.png`'
  receipt="$(ns_receipt_path "$p" "Shot." ab12)"
  mkdir -p "$(dirname "$receipt")"
  printf '# Shot.\n\nunchanged\n' >"$receipt"
  before="$(cat "$receipt")"
  ns_evidence_record "$p/.nightshift" "$p" "Shot."
  [ "$(cat "$receipt")" = "$before" ]
  run gate "$p"
  is_release

  write_item "$p" 'the screen `shot.png` check: report'
  receipt="$(ns_receipt_path "$p" "Shot." ab12)"
  mkdir -p "$(dirname "$receipt")"
  printf '# Shot.\n\nunchanged\n' >"$receipt"
  ns_evidence_record "$p/.nightshift" "$p" "Shot."
  grep -qF 'missing shot.png' "$receipt"
  run ns_evidence_hold "$p" "$punch"
  [ -z "$output" ]
  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/morning-receipt.sh" --project "$p" --view owner
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'evidence: missing shot.png'
}

@test "the item setting beats the shift setting" {
  p="$(new_project evidence-item-wins)"
  punch="$p/.nightshift/punch-list.md"
  jq '.receipts.evidence.check = "block"' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.json.tmp"
  mv "$p/.nightshift/rules.json.tmp" "$p/.nightshift/rules.json"
  write_item "$p" 'the screen `shot.png` check: off'
  run ns_evidence_problems "$p" "$punch" "Shot."
  [ -z "$output" ]
  write_item "$p" 'the screen `shot.png`'
  run ns_evidence_problems "$p" "$punch" "Shot."
  [ "$output" = "missing shot.png" ]
}

@test "hold closes as stopped and the shift can end; park writes one entry; note ticks with the reason" {
  p="$(new_project evidence-hold)"
  cat >"$p/.nightshift/punch-list.md" <<'EOF'
## Items

- [ ] **Shot.** <!-- id: ab12 -->
  - Evidence: the screen `shot.png` check: block unavailable: hold
EOF
  run ns_evidence_unavailable "$p" "Shot." "no browser"
  [ "$output" = "hold" ]
  grep -qF -- '- [-] **Shot.**' "$p/.nightshift/punch-list.md"
  receipt="$(ns_receipt_path "$p" "Shot." ab12)"
  grep -qF 'shot.png: unavailable — no browser' "$receipt"
  grep -qF 'accepted-tradeoff' "$p/.nightshift/inbox/snag-log.md" || grep -qF 'accepted-tradeoff' "$p/.nightshift/snag-log.md"
  run gate "$p"
  is_release

  p="$(new_project evidence-park)"
  cat >"$p/.nightshift/punch-list.md" <<'EOF'
## Items

- [ ] **Shot.** <!-- id: ab12 -->
  - Evidence: the screen `shot.png` unavailable: park
EOF
  run ns_evidence_unavailable "$p" "Shot." "no browser"
  [ "$output" = "park" ]
  run ns_evidence_unavailable "$p" "Shot." "no browser"
  [ "$output" = "park" ]
  lot="$p/.nightshift/inbox/parking-lot.md"
  [ -f "$lot" ] || lot="$p/.nightshift/parking-lot.md"
  [ "$(grep -cF 'Evidence for Shot. could not be produced' "$lot")" -eq 1 ]
  grep -qF 'leave the item open and keep working' "$lot"
  grep -qF -- '- [ ] **Shot.**' "$p/.nightshift/punch-list.md"

  p="$(new_project evidence-note)"
  cat >"$p/.nightshift/punch-list.md" <<'EOF'
## Items

- [ ] **Shot.** <!-- id: ab12 -->
  - Evidence: the screen `shot.png` unavailable: note
EOF
  run ns_evidence_unavailable "$p" "Shot." "no browser"
  [ "$output" = "note" ]
  grep -qF -- '- [x] **Shot.**' "$p/.nightshift/punch-list.md"
  receipt="$(ns_receipt_path "$p" "Shot." ab12)"
  grep -qF 'shot.png: unavailable — no browser' "$receipt"
  run ns_evidence_hold "$p" "$p/.nightshift/punch-list.md"
  [ -z "$output" ]
}

@test "PowerShell hold, park, and note match" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  p="$(new_project evidence-ps-unavail)"
  cat >"$p/.nightshift/punch-list.md" <<'EOF'
## Items

- [ ] **Shot.** <!-- id: ab12 -->
  - Evidence: the screen `shot.png` unavailable: hold
EOF
  run pwsh -NoProfile -Command "Import-Module '$MOD' -Force -DisableNameChecking; . '$PS1'; Invoke-NSEvidenceUnavailable -Workspace '$p' -Label 'Shot.' -Reason 'no browser'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'hold' || { printf '%s\n' "$output"; return 1; }
  grep -qF -- '- [-] **Shot.**' "$p/.nightshift/punch-list.md"
}
