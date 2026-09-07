load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
RETAIN="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/retain-history.sh"
ARCHIVE_RECEIPTS="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/archive-receipts.sh"
ARCHIVE="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/archive/SKILL.md"
START="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/start/SKILL.md"
STATUS="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/status/SKILL.md"
DOCTOR="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"
ROOT="$BATS_TEST_DIRNAME/../plugins/nightshift"

set_retention() {
  python3 -c '
import json,sys
p=sys.argv[1]; log=int(sys.argv[2]); arch=int(sys.argv[3])
with open(p) as f: d=json.load(f)
d["retention"]={"runtimeLogDays":log,"archiveDays":arch}
with open(p,"w") as f: json.dump(d,f)
' "$1/.nightshift/rules.json" "$2" "$3"
}

age_file() {
  touch -t 202001010101 "$1"
}

@test "zero defaults keep everything even when files are old" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  printf 'old log\n' >"$p/.nightshift/scheduled.log"
  mkdir -p "$p/.nightshift/archive/2020-01-01"
  printf 'shipped\n' >"$p/.nightshift/archive/2020-01-01/shipped.md"
  age_file "$p/.nightshift/scheduled.log"
  age_file "$p/.nightshift/archive/2020-01-01"
  run bash "$RETAIN" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Eligible: none'
  printf '%s' "$output" | grep -q 'Both rules are 0'
  [ -f "$p/.nightshift/scheduled.log" ]
  [ -d "$p/.nightshift/archive/2020-01-01" ]
  run bash "$RETAIN" --project "$p" --apply
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/scheduled.log" ]
  [ -d "$p/.nightshift/archive/2020-01-01" ]
}

@test "preview lists eligible paths and apply deletes only those" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  set_retention "$p" 7 30
  printf 'old log\n' >"$p/.nightshift/scheduled.log"
  mkdir -p "$p/.nightshift/archive/2020-01-01" "$p/.nightshift/archive/2026-08-01"
  printf '%s\n' '- [x] done' >"$p/.nightshift/archive/2020-01-01/shipped.md"
  printf '%s\n' '- [x] recent' >"$p/.nightshift/archive/2026-08-01/shipped.md"
  printf 'live\n' >"$p/.nightshift/punch-list.md"
  printf 'owner\n' >"$p/.nightshift/notes-from-owner.md"
  age_file "$p/.nightshift/scheduled.log"
  age_file "$p/.nightshift/archive/2020-01-01"
  run bash "$RETAIN" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'scheduled.log'
  printf '%s' "$output" | grep -q 'archive/2020-01-01'
  if printf '%s' "$output" | grep -q 'archive/2026-08-01'; then
    return 1
  fi
  if printf '%s' "$output" | grep -q 'punch-list.md'; then
    return 1
  fi
  if printf '%s' "$output" | grep -q 'notes-from-owner'; then
    return 1
  fi
  printf '%s' "$output" | grep -q 'Dry run'
  [ -f "$p/.nightshift/scheduled.log" ]
  [ -d "$p/.nightshift/archive/2020-01-01" ]

  run bash "$RETAIN" --project "$p" --apply
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/scheduled.log" ]
  [ ! -e "$p/.nightshift/archive/2020-01-01" ]
  [ -d "$p/.nightshift/archive/2026-08-01" ]
  [ -f "$p/.nightshift/punch-list.md" ]
  [ -f "$p/.nightshift/notes-from-owner.md" ]
  [ -f "$p/.nightshift/rules.json" ]
}

@test "armed workspaces preview but refuse deletion" {
  p="$(new_project)"
  : >"$p/.nightshift/.shift-armed"
  set_retention "$p" 1 1
  printf 'old log\n' >"$p/.nightshift/scheduled.log"
  age_file "$p/.nightshift/scheduled.log"
  run bash "$RETAIN" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Armed:          yes'
  printf '%s' "$output" | grep -q 'scheduled.log'
  run bash "$RETAIN" --project "$p" --apply
  [ "$status" -eq 2 ]
  [ -f "$p/.nightshift/scheduled.log" ]
}

@test "symlinks, traversal, and open-work archives are refused" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  set_retention "$p" 1 1
  printf 'secret\n' >"$BATS_TEST_TMPDIR/outside.log"
  ln -s "$BATS_TEST_TMPDIR/outside.log" "$p/.nightshift/scheduled.log"
  mkdir -p "$p/.nightshift/archive/2020-01-01"
  printf '## Items\n- [ ] still open\n' >"$p/.nightshift/archive/2020-01-01/punch-list.md"
  age_file "$p/.nightshift/archive/2020-01-01"
  mkdir -p "$p/.nightshift/archive/2019-01-01"
  printf '%s\n' '- [x] done' >"$p/.nightshift/archive/2019-01-01/shipped.md"
  ln -s /tmp "$p/.nightshift/archive/2018-01-01"
  run bash -c '. "$1"; ns_under_nightshift "$2" "../outside.log"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run bash "$RETAIN" --project "$p"
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -q 'scheduled.log'; then
    return 1
  fi
  if printf '%s' "$output" | grep -q 'archive/2020-01-01'; then
    return 1
  fi
  if printf '%s' "$output" | grep -q 'archive/2018-01-01'; then
    return 1
  fi
  run bash "$RETAIN" --project "$p" --apply
  [ "$status" -eq 0 ]
  [ -L "$p/.nightshift/scheduled.log" ]
  [ -f "$p/.nightshift/archive/2020-01-01/punch-list.md" ]
  [ -L "$p/.nightshift/archive/2018-01-01" ]
  [ -f "$BATS_TEST_TMPDIR/outside.log" ]
}

@test "a symlink punch-list in an archive does not count as open work" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  set_retention "$p" 1 1
  printf '## Items\n- [ ] live open\n' >"$p/.nightshift/punch-list.md"
  mkdir -p "$p/.nightshift/archive/2017-01-01"
  printf '%s\n' '- [x] done' >"$p/.nightshift/archive/2017-01-01/shipped.md"
  ln -s "$p/.nightshift/punch-list.md" "$p/.nightshift/archive/2017-01-01/punch-list.md"
  age_file "$p/.nightshift/archive/2017-01-01"
  run bash "$RETAIN" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'archive/2017-01-01'
  run bash "$RETAIN" --project "$p" --apply
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/archive/2017-01-01" ]
  [ -f "$p/.nightshift/punch-list.md" ]
  grep -qF 'live open' "$p/.nightshift/punch-list.md"
}

@test "an archived shift policy is swept with its dated directory like any other receipt" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  set_retention "$p" 1 1
  mkdir -p "$p/.nightshift/archive/2017-06-01"
  printf '%s\n' '- [x] done' >"$p/.nightshift/archive/2017-06-01/shipped.md"
  printf '{ }\n' >"$p/.nightshift/archive/2017-06-01/shift-policy-deadbeefdeadbeefdeadbeefdeadbeef.json"
  age_file "$p/.nightshift/archive/2017-06-01"
  run bash "$RETAIN" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'archive/2017-06-01'
  run bash "$RETAIN" --project "$p" --apply
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/archive/2017-06-01" ]
}

@test "the morning receipt archives with the night's other receipts and is swept with them" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  set_retention "$p" 1 1
  mkdir -p "$p/.nightshift/receipts"
  printf 'item\n' >"$p/.nightshift/receipts/20260101T000000Z-one.md"
  printf '# Shift\n' >"$p/.nightshift/receipts/morning-2026-09-02-9f2c40ab77e51d63.md"

  run bash "$ARCHIVE_RECEIPTS" --project "$p" --date 2017-07-01
  [ "$status" -eq 0 ]
  dest="$p/.nightshift/archive/2017-07-01/receipts"
  [ -f "$dest/20260101T000000Z-one.md" ]
  [ -f "$dest/morning-2026-09-02-9f2c40ab77e51d63.md" ]
  # The live copy stays where the owner reads it.
  [ -f "$p/.nightshift/receipts/morning-2026-09-02-9f2c40ab77e51d63.md" ]

  printf '%s\n' '- [x] done' >"$p/.nightshift/archive/2017-07-01/shipped.md"
  age_file "$p/.nightshift/archive/2017-07-01"
  run bash "$RETAIN" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'archive/2017-07-01'
  run bash "$RETAIN" --project "$p" --apply
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/archive/2017-07-01" ]
  [ -f "$p/.nightshift/receipts/morning-2026-09-02-9f2c40ab77e51d63.md" ]
}

@test "hooks start status and Doctor never prune history" {
  if grep -RIn 'retain-history\|ns_retention_apply' \
    "$ROOT/hooks" \
    "$ROOT/runtime/claude" \
    "$ROOT/runtime/codex" \
    "$ROOT/runtime/doctor.sh" \
    "$ROOT/runtime/schedule.sh" \
    "$ROOT/runtime/migrate-state.sh" \
    "$START" "$STATUS"; then
    return 1
  fi
  if grep -n 'ns_retention_apply\|retain-history.sh --apply' "$DOCTOR"; then
    return 1
  fi
  if grep -n 'retain-history' "$ROOT/runtime/windows/doctor.ps1"; then
    return 1
  fi
  grep -qE 'ns"? retain-history' "$ARCHIVE"
  grep -qF 'explicit confirmation' "$ARCHIVE" || grep -qF 'owner confirms' "$ARCHIVE"
  # The rule that matters: nothing on the armed path may call it.
  grep -qF 'Never call `ns retain-history`' "$ARCHIVE"
  grep -qF 'from start, hooks, status, Doctor, or recovery' "$ARCHIVE"
}

LOGIC="$BATS_TEST_DIRNAME/windows/retain-history-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"

@test "Windows CI runs the portable retain-history apply suite" {
  [ -f "$LOGIC" ]
  grep -qF 'retain-history-logic.ps1' "$RUN"
  grep -qF 'Deleted the eligible allowlisted paths' "$LOGIC"
  grep -qF 'open-work archive is not eligible' "$LOGIC"
  grep -qF 'symlink punch-list is not open work' "$LOGIC"
  grep -qF 'refuse to delete while the shift is armed' "$LOGIC"
  grep -qF 'if [ ! -d "$ns/$rel" ] || [ -L "$ns/$rel" ]; then' "$ROOT/lib/state.sh"
  awk '/function Get-NSRetentionEligible/,/^function Invoke-NSRetentionApply/' \
    "$ROOT/lib/Nightshift.psm1" | grep -qF 'ReparsePoint'
}

@test "Windows retain-history apply logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}

@test "archive skill and schema describe the nested retention knobs" {
  grep -qF 'retention.runtimeLogDays' "$ARCHIVE"
  grep -qF 'retention.archiveDays' "$ARCHIVE"
  jq -e '.properties.retention.properties.runtimeLogDays.minimum == 0' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/nightshift-rules.schema.json" >/dev/null
  jq -e '.retention.runtimeLogDays == 0 and .retention.archiveDays == 0' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json" >/dev/null
}
