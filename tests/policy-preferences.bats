load helpers

SH="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/shift-policy.sh"
LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
TEMPLATE="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json"

# The skills are told to honour report, handoff, archive, recovery and shift settings, and they are
# told to read them from the one resolved view. These hold that view to carrying them.

resolve_table() { "$SH" --project "$1" resolve --table; }

@test "the resolved view carries every preference the skills are told to honour" {
  p="$(new_project pref-view)"
  cp "$TEMPLATE" "$p/.nightshift/rules.json"
  run resolve_table "$p"
  [ "$status" -eq 0 ]
  for row in \
    'archive.automatic=false (rules, permanent)' \
    'archive.layout=date (rules, permanent)' \
    'archive.root=archive (rules, permanent)' \
    'handoff.enabled=true (rules, permanent)' \
    'handoff.view=owner (rules, permanent)' \
    'handoff.sections=[] (rules, permanent)' \
    'recovery.launchScope=inherit-recorded-scope (rules, permanent)' \
    'report.enabled=true (rules, permanent)' \
    'report.progressMode=time (rules, permanent)' \
    'report.progressMinutes=20 (rules, permanent)' \
    'report.progressTokens=100000 (rules, permanent)' \
    'report.usage=when-available (rules, permanent)' \
    'report.legacyItemReceipts=false (rules, permanent)' \
    'shift.verificationProfile=fast (rules, permanent)' \
    'shift.hours=null (rules, permanent)'; do
    printf '%s\n' "$output" | grep -qxF "$row" || { echo "missing: $row"; return 1; }
  done
}

@test "a workspace with no rules file still answers with the shipped defaults" {
  p="$(new_project pref-none)"
  rm -f "$p/.nightshift/rules.json"
  run resolve_table "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'report.enabled=true (built-in, -)'
  printf '%s\n' "$output" | grep -qxF 'report.progressMode=time (built-in, -)'
  printf '%s\n' "$output" | grep -qxF 'archive.root=archive (built-in, -)'
  printf '%s\n' "$output" | grep -qxF 'recovery.launchScope=inherit-recorded-scope (built-in, -)'
}

@test "the owner's own values are what the view reports, and presence is what makes them theirs" {
  p="$(new_project pref-owner)"
  cp "$TEMPLATE" "$p/.nightshift/rules.json"
  jq '.report.enabled = false | .report.progressMode = "tokens" | .report.progressMinutes = 5
      | .handoff.view = "engineer" | .handoff.sections = ["what changed", "what failed"]
      | .handoff.templatePath = "docs/handoff.md" | .archive.root = "history"
      | .archive.layout = "shift" | .archive.automatic = true' \
    "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run resolve_table "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'report.enabled=false (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'report.progressMode=tokens (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'report.progressMinutes=5 (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'handoff.view=engineer (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'handoff.sections=["what changed","what failed"] (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'handoff.templatePath=docs/handoff.md (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'archive.root=history (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'archive.layout=shift (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'archive.automatic=true (rules, permanent)'

  # A block the owner deleted falls back to the shipped default rather than disappearing.
  jq 'del(.report)' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run resolve_table "$p"
  printf '%s\n' "$output" | grep -qxF 'report.enabled=true (built-in, -)'
}

@test "a disabled report and an enabled handoff are independent, and so is the reverse" {
  p="$(new_project pref-independent)"
  cp "$TEMPLATE" "$p/.nightshift/rules.json"
  jq '.report.enabled = false | .handoff.enabled = true' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run resolve_table "$p"
  printf '%s\n' "$output" | grep -qxF 'report.enabled=false (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'handoff.enabled=true (rules, permanent)'
  jq '.report.enabled = true | .handoff.enabled = false' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run resolve_table "$p"
  printf '%s\n' "$output" | grep -qxF 'report.enabled=true (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'handoff.enabled=false (rules, permanent)'
}

@test "an owner extension nobody knows about survives and is never read as a permission" {
  p="$(new_project pref-extension)"
  cp "$TEMPLATE" "$p/.nightshift/rules.json"
  jq '.report.somethingNew = "keep me" | .futureKey = "mine"' \
    "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run resolve_table "$p"
  [ "$status" -eq 0 ]
  # The settings it documents still resolve, and the extension becomes no row of its own.
  printf '%s\n' "$output" | grep -qxF 'report.enabled=true (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'handoff.view=owner (rules, permanent)'
  printf '%s\n' "$output" | grep -qv 'somethingNew'
  printf '%s\n' "$output" | grep -qv 'futureKey'
  # And reading it leaves the owner's file exactly as they wrote it.
  jq -e '.report.somethingNew == "keep me" and .futureKey == "mine"' "$p/.nightshift/rules.json" >/dev/null

  # A shape the reader does not support fails the whole file closed rather than resolving part of
  # it: Start refuses to arm and the owner's guards never quietly stop applying.
  jq '.futureBlock = {"x": 1}' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run bash -c '. "$1"; ns_rules_check "$2"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  [ "$output" = "unexpected nesting" ]
}

@test "the view answers the same with neither jq nor python3 on PATH" {
  p="$(new_project pref-no-parser)"
  cp "$TEMPLATE" "$p/.nightshift/rules.json"
  jq '.report.progressMode = "either" | .handoff.sections = ["what failed"]' \
    "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  with="$(resolve_table "$p")"

  bin="$p/bin"
  mkdir -p "$bin"
  for tool in bash sed grep awk tr cat sort head mkdir rm cut date env dirname basename ls mv cp find wc printf; do
    src="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$src" "$bin/$tool"
  done
  run env PATH="$bin" "$SH" --project "$p" resolve --table
  [ "$status" -eq 0 ]
  [ "$output" = "$with" ]
  printf '%s\n' "$output" | grep -qxF 'report.progressMode=either (rules, permanent)'
  printf '%s\n' "$output" | grep -qxF 'handoff.sections=["what failed"] (rules, permanent)'
}

@test "reading the resolved view never needs write access to the owner's file" {
  p="$(new_project pref-readonly)"
  cp "$TEMPLATE" "$p/.nightshift/rules.json"
  before="$(cksum <"$p/.nightshift/rules.json")"
  chmod 444 "$p/.nightshift/rules.json"
  run resolve_table "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'report.enabled=true (rules, permanent)'
  chmod 644 "$p/.nightshift/rules.json"
  [ "$(cksum <"$p/.nightshift/rules.json")" = "$before" ]

  # And it still answers while the shift is armed, when writing it is refused.
  : >"$p/.nightshift/.shift-armed"
  run resolve_table "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'report.enabled=true (rules, permanent)'
}

@test "the shipped skills name rows the view actually prints" {
  skill="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/SKILL.md"
  p="$(new_project pref-named)"
  cp "$TEMPLATE" "$p/.nightshift/rules.json"
  table="$(resolve_table "$p")"
  grep -qF 'report.enabled=false' "$skill"
  grep -qF 'handoff.enabled=false' "$skill"
  grep -qF 'handoff.templatePath' "$skill"
  for name in report.enabled handoff.enabled handoff.templatePath; do
    printf '%s\n' "$table" | grep -q "^$name=" || { echo "$name is not a row"; return 1; }
  done
}

@test "Windows resolves the same preferences to the same bytes" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  p="$(new_project pref-parity)"
  cp "$TEMPLATE" "$p/.nightshift/rules.json"
  jq '.report.progressMode = "either" | .report.enabled = false | .handoff.view = "engineer"
      | .handoff.sections = ["what changed"] | .archive.root = "history" | .shift.hours = 6' \
    "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  module="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"

  run pwsh -NoProfile -NonInteractive -Command \
    "Import-Module '$module' -Force -DisableNameChecking; Resolve-NSPolicy -Workspace '$p' -Table"
  [ "$status" -eq 0 ]
  [ "$output" = "$(resolve_table "$p")" ]

  run pwsh -NoProfile -NonInteractive -Command \
    "Import-Module '$module' -Force -DisableNameChecking; Resolve-NSPolicy -Workspace '$p'"
  [ "$status" -eq 0 ]
  [ "$output" = "$("$SH" --project "$p" resolve)" ]
}
