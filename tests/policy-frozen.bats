#!/usr/bin/env bats
# The owner's file is where a preference is written; tonight's policy is where it is fixed.
#
# These assert what consumers do, not that a field appears in JSON: a shift that started with the
# report off keeps it off, files where it was told to file, and keeps the cadence it was composed
# with, however the owner's file changes underneath it.

load helpers

SH="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/shift-policy.sh"
LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
ARCHIVE_SH="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/archive-receipts.sh"

# compose <project> — write tonight's policy the way composition does: before the site is armed,
# which is the only time the policy may be written at all.
compose() {
  rm -f "$1/.nightshift/.shift-armed"
  jq -nc '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-09-02T00:00:00Z",
           source:"composition",verificationLevel:"final",toolingPolicy:"existing-tools"}' |
    "$SH" --project "$1" set --from-json - >/dev/null
}

# owner_rules <project> <jq filter> — the owner edits their own file.
owner_rules() {
  jq "$2" "$1/.nightshift/rules.json" >"$1/r.json"
  mv "$1/r.json" "$1/.nightshift/rules.json"
}

pref() { bash -c '. "$1"; ns_policy_pref "$2" "$3" "$4"' _ "$LIB" "$1" "$2" "$3"; }

@test "an edit to the owner's file lands on the next shift, not the one running" {
  p="$(new_project frozen-edit)"
  owner_rules "$p" '.report.enabled = false | .archive.root = "history" | .report.progressMinutes = 5'
  compose "$p"

  # Composed with the report off, filing to history, on a five-minute cadence.
  [ "$(pref "$p" report enabled)" = false ]
  [ "$(pref "$p" archive root)" = history ]
  [ "$(pref "$p" report progressMinutes)" = 5 ]

  # The owner changes their mind mid-shift. Tonight does not move.
  owner_rules "$p" '.report.enabled = true | .archive.root = "elsewhere" | .report.progressMinutes = 45'
  [ "$(pref "$p" report enabled)" = false ]
  [ "$(pref "$p" archive root)" = history ]
  [ "$(pref "$p" report progressMinutes)" = 5 ]

  # Composing again is the authorized update path, and it takes the new values.
  rm -f "$p/.nightshift/shift-policy.json"
  compose "$p"
  [ "$(pref "$p" report enabled)" = true ]
  [ "$(pref "$p" archive root)" = elsewhere ]
  [ "$(pref "$p" report progressMinutes)" = 45 ]
}

@test "the consumers themselves follow the frozen policy, not the owner's current file" {
  p="$(new_project frozen-consumers)"
  owner_rules "$p" '.report.enabled = false | .handoff.enabled = false | .archive.root = "history"
    | .archive.layout = "shift" | .report.legacyItemReceipts = true'
  compose "$p"
  owner_rules "$p" '.report.enabled = true | .handoff.enabled = true | .archive.root = "elsewhere"
    | .archive.layout = "date" | .report.legacyItemReceipts = false'

  run bash -c '. "$1"; ns_report_enabled "$2"' _ "$LIB" "$p"
  [ "$status" -ne 0 ] || { echo "the report came back on mid-shift"; return 1; }
  run bash -c '. "$1"; ns_handoff_enabled "$2"' _ "$LIB" "$p"
  [ "$status" -ne 0 ] || { echo "the handoff came back on mid-shift"; return 1; }
  run bash -c '. "$1"; ns_report_legacy_receipts "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ] || { echo "legacy receipts stopped mid-shift"; return 1; }

  # The destination is the one this shift was composed with, layout and root together.
  run bash -c '. "$1"; ns_archive_dir "$2" 2026-09-05 9f2c40ab77e51d63' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ "$output" = "$p/.nightshift/history/shift-9f2c40ab77e51d63" ]
}

@test "a custom template is the one the shift was composed with" {
  p="$(new_project frozen-template)"
  owner_rules "$p" '.handoff.templatePath = "docs/handoff.md" | .report.templatePath = "docs/report.md"'
  compose "$p"
  owner_rules "$p" '.handoff.templatePath = "docs/other.md" | .report.templatePath = ""'
  [ "$(pref "$p" handoff templatePath)" = "docs/handoff.md" ]
  [ "$(pref "$p" report templatePath)" = "docs/report.md" ]
}

@test "a snapshot that cannot be read never hands the shift back to the mutable file" {
  p="$(new_project frozen-malformed)"
  owner_rules "$p" '.report.enabled = false | .archive.root = "history"'
  compose "$p"
  printf '{ "schemaVersion": 1,\n' >"$p/.nightshift/shift-policy.json"

  # Empty, so each caller takes its own shipped default. Not the owner's file, which the
  # unreadable snapshot was there to fix in the first place.
  [ -z "$(pref "$p" archive root)" ]
  [ -z "$(pref "$p" report enabled)" ]
  run bash -c '. "$1"; ns_archive_root "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ "$output" = "$p/.nightshift/archive" ]
  run bash -c '. "$1"; ns_report_enabled "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
}

@test "a policy written before this feature still honours the owner's file" {
  p="$(new_project frozen-legacy)"
  owner_rules "$p" '.report.enabled = false | .archive.root = "history"'
  # A snapshot from an older Nightshift: valid, and carrying none of the preference blocks.
  jq -nc '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-09-02T00:00:00Z",
           source:"composition",verificationLevel:"final",toolingPolicy:"existing-tools"}' \
    >"$p/.nightshift/shift-policy.json"
  [ "$(pref "$p" report enabled)" = false ]
  [ "$(pref "$p" archive root)" = history ]
}

@test "an owner override written into the policy itself is left alone" {
  p="$(new_project frozen-explicit)"
  owner_rules "$p" '.report.progressMode = "time"'
  rm -f "$p/.nightshift/.shift-armed"
  jq -nc '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-09-02T00:00:00Z",
           source:"composition",verificationLevel:"final",toolingPolicy:"existing-tools",
           report:{enabled:true,progressMode:"tokens"}}' |
    "$SH" --project "$p" set --from-json - >/dev/null
  # What the candidate stated stands; the rest of the block is not invented around it.
  [ "$(pref "$p" report progressMode)" = tokens ]
  jq -e '.report.progressMode == "tokens" and (.report | has("usage") | not)' \
    "$p/.nightshift/shift-policy.json" >/dev/null
}

@test "the frozen policy resolves the same with no jq and no python3" {
  p="$(new_project frozen-no-parser)"
  owner_rules "$p" '.report.enabled = false | .archive.root = "history" | .handoff.sections = ["changed"]'
  compose "$p"
  with="$("$SH" --project "$p" resolve --table)"

  bin="$p/bin"
  mkdir -p "$bin"
  for tool in bash sed grep awk tr cat sort head cut date env dirname basename ls mv cp rm find wc mkdir printf; do
    src="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$src" "$bin/$tool"
  done
  run env PATH="$bin" "$SH" --project "$p" resolve --table
  [ "$status" -eq 0 ]
  [ "$output" = "$with" ]
  printf '%s\n' "$output" | grep -qxF 'report.enabled=false (one-shift, shift)'
  printf '%s\n' "$output" | grep -qxF 'handoff.sections=["changed"] (one-shift, shift)'
}

@test "Windows freezes and reads the same policy the same way" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  p="$(new_project frozen-parity)"
  owner_rules "$p" '.report.enabled = false | .archive.root = "history" | .archive.layout = "shift"'
  compose "$p"
  owner_rules "$p" '.report.enabled = true | .archive.root = "elsewhere"'
  module="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"
  run pwsh -NoProfile -NonInteractive -Command \
    "Import-Module '$module' -Force -DisableNameChecking; Resolve-NSPolicy -Workspace '$p' -Table"
  [ "$status" -eq 0 ]
  [ "$output" = "$("$SH" --project "$p" resolve --table)" ]
  printf '%s\n' "$output" | grep -qxF 'report.enabled=false (one-shift, shift)'
}
