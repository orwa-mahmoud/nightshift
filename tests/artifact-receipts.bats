load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
STATE="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/state.sh"
WRITE="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/write-receipt.sh"
WRITE_PS1="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/write-receipt.ps1"
WRITE_LOGIC="$BATS_TEST_DIRNAME/windows/write-receipt-logic.ps1"
DOCTOR="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"
DOCTOR_PS1="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/doctor.ps1"
PSM1="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"
GATE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/clock-out-gate.sh"
CODEX_GATE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/codex/clock-out-gate.sh"
WIN_GATE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/clock-out-gate.ps1"
CORE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/gate-core.sh"
SKILLS="$BATS_TEST_DIRNAME/../plugins/nightshift/skills"
NIGHTSHIFT="$SKILLS/nightshift/SKILL.md"
START="$SKILLS/start/SKILL.md"
SETUP="$SKILLS/setup/SKILL.md"
STATUS="$SKILLS/status/SKILL.md"
DOCTOR_SKILL="$SKILLS/doctor/SKILL.md"
ARCHIVE="$SKILLS/archive/SKILL.md"
TEMPLATE="$SKILLS/nightshift/references/punch-list-template.md"
DRAFT_TEMPLATE="$SKILLS/nightshift/references/drafting-table-template.md"
DOC="$BATS_TEST_DIRNAME/../docs/how-it-works.md"
VOCAB="$BATS_TEST_DIRNAME/../docs/vocabulary.md"
COMMANDS="$BATS_TEST_DIRNAME/../docs/commands.md"
WINDOC="$BATS_TEST_DIRNAME/../docs/windows.md"
README="$BATS_TEST_DIRNAME/../README.md"
CODEX_PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift/.codex-plugin/plugin.json"

new_artifact() {
  local p="$BATS_TEST_TMPDIR/${1:-artifact}"
  mkdir -p "$p/.nightshift" "$p/out"
  cp "$RULES_TEMPLATE" "$p/.nightshift/rules.json"
  : >"$p/.nightshift/.shift-armed"
  printf 'artifact\n' >"$p/.nightshift/work-mode"
  printf '%s\n' "$(cd -P "$p" && pwd)" >"$p/.nightshift/work-target"
  printf '%s' "$p"
}

@test "write-receipt records a durable artifact receipt" {
  p="$(new_artifact ok)"
  printf 'research notes\n' >"$p/out/topic.md"
  run bash "$WRITE" --project "$p" --item 'Write the brief' --verify 'file exists' \
    --source 'https://example.com/doc' --output "$p/out/topic.md"
  [ "$status" -eq 0 ]
  dest="$output"
  [ -f "$dest" ]
  case "$dest" in */.nightshift/receipts/*.md) ;; *) echo "dest=$dest"; return 1 ;; esac
  grep -qF '# Nightshift artifact receipt' "$dest"
  grep -qF 'item: Write the brief' "$dest"
  grep -qF 'verification: file exists' "$dest"
  grep -qF 'mode: artifact' "$dest"
  grep -qF 'https://example.com/doc' "$dest"
  grep -qF 'sha256:' "$dest"
  grep -qF 'bytes:' "$dest"
  grep -qF 'mtime:' "$dest"
  run bash -c '. "$1"; ns_receipts_count "$2"' _ "$LIB" "$p"
  [ "$output" = 1 ]
}

@test "write-receipt refuses a symlink work-mode" {
  p="$(new_artifact mode-link)"
  mv "$p/.nightshift/work-mode" "$p/.nightshift/mode-plant"
  ln -s mode-plant "$p/.nightshift/work-mode"
  printf 'ok\n' >"$p/out/topic.md"
  run bash "$WRITE" --project "$p" --item 'x' --verify 'ok' --output "$p/out/topic.md"
  [ "$status" -eq 3 ]
  printf '%s' "$output$stderr" | grep -qF 'write-receipt: work-mode is malformed'
  [ ! -d "$p/.nightshift/receipts" ]
}

@test "write-receipt refuses repository mode" {
  p="$(new_project receipt-repo)"
  printf 'ok\n' >"$p/out.md"
  run bash "$WRITE" --project "$p" --item 'x' --verify 'ok' --output "$p/out.md"
  [ "$status" -eq 3 ]
  [ ! -d "$p/.nightshift/receipts" ]
}

@test "write-receipt rejects a missing output" {
  p="$(new_artifact missing)"
  run bash "$WRITE" --project "$p" --item 'x' --verify 'ok' --output "$p/out/nope.md"
  [ "$status" -eq 2 ]
  [ ! -d "$p/.nightshift/receipts" ]
}

@test "write-receipt rejects an empty output" {
  p="$(new_artifact empty)"
  : >"$p/out/blank.md"
  run bash "$WRITE" --project "$p" --item 'x' --verify 'ok' --output "$p/out/blank.md"
  [ "$status" -eq 2 ]
  [ ! -d "$p/.nightshift/receipts" ]
}

@test "write-receipt rejects a symlink output" {
  p="$(new_artifact link)"
  printf 'ok\n' >"$p/out/real.md"
  ln -s "$p/out/real.md" "$p/out/alias.md"
  run bash "$WRITE" --project "$p" --item 'x' --verify 'ok' --output "$p/out/alias.md"
  [ "$status" -eq 2 ]
  [ ! -d "$p/.nightshift/receipts" ]
}

@test "write-receipt omits secret lines" {
  p="$(new_artifact secret)"
  printf 'ok\n' >"$p/out/topic.md"
  run bash "$WRITE" --project "$p" --item 'x' --verify 'ok' \
    --decision 'password=supersecret' --output "$p/out/topic.md"
  [ "$status" -eq 0 ]
  if grep -qF 'supersecret' "$output"; then
    return 1
  fi
  grep -qF 'decision: (redacted)' "$output"
}

@test "Doctor reports artifact receipts only in artifact mode" {
  empty="$(new_artifact doctor-empty)"
  run bash "$DOCTOR" --project "$empty"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'work mode artifact'
  printf '%s' "$output" | grep -qF 'artifact receipts 0'
  if printf '%s' "$output" | grep -qF 'latest artifact receipt'; then
    return 1
  fi

  a="$(new_artifact doctor)"
  printf 'ok\n' >"$a/out/topic.md"
  bash "$WRITE" --project "$a" --item 'x' --verify 'ok' --output "$a/out/topic.md" >/dev/null
  name="$(find "$a/.nightshift/receipts" -type f ! -name '.*' -print | awk -F/ '{print $NF}')"
  [ -n "$name" ]
  run bash "$DOCTOR" --project "$a"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'work mode artifact'
  printf '%s' "$output" | grep -qF 'artifact receipts 1'
  printf '%s' "$output" | grep -qF "latest artifact receipt $name"
  line="$(printf '%s' "$output" | grep 'latest artifact receipt')"
  if printf '%s' "$line" | grep -q '/'; then
    return 1
  fi

  r="$(new_project receipt-doctor-repo)"
  run bash "$DOCTOR" --project "$r"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'work mode repository'
  if printf '%s' "$output" | grep -qF 'artifact receipts'; then
    return 1
  fi
  if printf '%s' "$output" | grep -qF 'latest artifact receipt'; then
    return 1
  fi
}

@test "Doctor names the newest artifact receipt filename" {
  a="$(new_artifact doctor-latest)"
  mkdir -p "$a/.nightshift/receipts"
  printf 'old\n' >"$a/.nightshift/receipts/20260101T000000Z-old.md"
  printf 'new\n' >"$a/.nightshift/receipts/20261231T235959Z-new.md"
  run bash "$DOCTOR" --project "$a"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'artifact receipts 2'
  printf '%s' "$output" | grep -qF 'latest artifact receipt 20261231T235959Z-new.md'
  if printf '%s' "$output" | grep -qF 'latest artifact receipt 20260101T000000Z-old.md'; then
    return 1
  fi
}

@test "latest receipt prefers uniqueness suffix over C-locale name order" {
  a="$(new_artifact latest-suffix)"
  mkdir -p "$a/.nightshift/receipts"
  printf 'first\n' >"$a/.nightshift/receipts/20260101T000000Z-item.md"
  printf 'second\n' >"$a/.nightshift/receipts/20260101T000000Z-item-1.md"
  touch -r "$a/.nightshift/receipts/20260101T000000Z-item.md" \
    "$a/.nightshift/receipts/20260101T000000Z-item-1.md"
  latest="$(bash -c '. "$1"; ns_latest_receipt "$2"' _ "$LIB" "$a")"
  [ "$(basename "$latest")" = '20260101T000000Z-item-1.md' ]
  run bash "$DOCTOR" --project "$a"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'latest artifact receipt 20260101T000000Z-item-1.md'
  if printf '%s' "$output" | grep -qF 'latest artifact receipt 20260101T000000Z-item.md'; then
    return 1
  fi
}

@test "latest receipt prefers mtime over a later-looking stamp" {
  a="$(new_artifact latest-mtime)"
  mkdir -p "$a/.nightshift/receipts"
  printf 'stale name\n' >"$a/.nightshift/receipts/20261231T235959Z-new.md"
  sleep 1
  printf 'written later\n' >"$a/.nightshift/receipts/20260101T000000Z-old.md"
  latest="$(bash -c '. "$1"; ns_latest_receipt "$2"' _ "$LIB" "$a")"
  [ "$(basename "$latest")" = '20260101T000000Z-old.md' ]
}

@test "latest receipt ignores hidden files in the receipts directory" {
  a="$(new_artifact latest-hidden)"
  mkdir -p "$a/.nightshift/receipts"
  printf 'dot\n' >"$a/.nightshift/receipts/.not-a-receipt"
  printf 'ok\n' >"$a/.nightshift/receipts/20260101T000000Z-real.md"
  latest="$(bash -c '. "$1"; ns_latest_receipt "$2"' _ "$LIB" "$a")"
  [ "$(basename "$latest")" = '20260101T000000Z-real.md' ]
  [ "$(bash -c '. "$1"; ns_receipts_count "$2"' _ "$LIB" "$a")" = 1 ]
  run bash "$DOCTOR" --project "$a"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'artifact receipts 1'
  printf '%s' "$output" | grep -qF 'latest artifact receipt 20260101T000000Z-real.md'
}

@test "receipts helpers ignore symlink receipts" {
  a="$(new_artifact symlink-receipts)"
  mkdir -p "$a/.nightshift/receipts"
  printf 'ok\n' >"$a/.nightshift/receipts/20260101T000000Z-real.md"
  ln -s "$a/.nightshift/receipts/20260101T000000Z-real.md" \
    "$a/.nightshift/receipts/20260101T000000Z-link.md"
  latest="$(bash -c '. "$1"; ns_latest_receipt "$2"' _ "$LIB" "$a")"
  [ "$(basename "$latest")" = '20260101T000000Z-real.md' ]
  [ "$(bash -c '. "$1"; ns_receipts_count "$2"' _ "$LIB" "$a")" = 1 ]
  run bash "$DOCTOR" --project "$a"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'artifact receipts 1'
  printf '%s' "$output" | grep -qF 'latest artifact receipt 20260101T000000Z-real.md'
}

@test "receipts helpers ignore a symlink receipts directory" {
  a="$(new_artifact symlink-recv-dir)"
  mkdir -p "$a/outside"
  printf 'ok\n' >"$a/outside/20260101T000000Z-outside.md"
  ln -s "$a/outside" "$a/.nightshift/receipts"
  if bash -c '. "$1"; ns_latest_receipt "$2"' _ "$LIB" "$a"; then
    return 1
  fi
  [ "$(bash -c '. "$1"; ns_receipts_count "$2"' _ "$LIB" "$a")" = 0 ]
  [ "$(bash -c '. "$1"; ns_receipts_fingerprint "$2"' _ "$LIB" "$a")" = none ]
  run bash "$DOCTOR" --project "$a"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'artifact receipts 0'
  printf '%s' "$output" | grep -qF 'artifact receipts path is not a usable directory'
  printf '%s' "$output" | grep -qF 'so write-receipt can land'
  if printf '%s' "$output" | grep -qF 'complete ticked items with'; then
    return 1
  fi
}

@test "write-receipt refuses a symlink receipts directory" {
  p="$(new_artifact write-symlink-recv)"
  printf 'ok\n' >"$p/out/topic.md"
  mkdir -p "$p/outside"
  ln -s "$p/outside" "$p/.nightshift/receipts"
  run bash "$WRITE" --project "$p" --item 'x' --verify 'ok' --output "$p/out/topic.md"
  [ "$status" -eq 2 ]
  n="$(find "$p/outside" -type f ! -name '.*' | wc -l | tr -d ' ')"
  [ "$n" = 0 ]
}

@test "write-receipt refuses a non-directory receipts path" {
  p="$(new_artifact write-receipts-file)"
  printf 'ok\n' >"$p/out/topic.md"
  printf 'not-a-dir\n' >"$p/.nightshift/receipts"
  run bash "$WRITE" --project "$p" --item 'x' --verify 'ok' --output "$p/out/topic.md"
  [ "$status" -eq 2 ]
  [ -f "$p/.nightshift/receipts" ]
  grep -qF 'not-a-dir' "$p/.nightshift/receipts"
}

@test "Doctor warns when the receipts path is not a usable directory" {
  a="$(new_artifact doctor-recv-file)"
  printf 'not-a-dir\n' >"$a/.nightshift/receipts"
  run bash "$DOCTOR" --project "$a"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'artifact receipts 0'
  printf '%s' "$output" | grep -qF 'artifact receipts path is not a usable directory'
  printf '%s' "$output" | grep -qF 'so write-receipt can land'
  if printf '%s' "$output" | grep -qF 'complete ticked items with'; then
    return 1
  fi
  if printf '%s' "$output" | grep -qF 'artifact mode has ticked items but no receipts'; then
    return 1
  fi
}

@test "Doctor does not offer write-receipt when ticks sit on an unusable receipts path" {
  a="$(new_artifact doctor-unusable-ticks)"
  punch_open "$a"
  printf 'not-a-dir\n' >"$a/.nightshift/receipts"
  run bash "$DOCTOR" --project "$a"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'punch list open=1 ticked=1'
  printf '%s' "$output" | grep -qF 'artifact receipts path is not a usable directory'
  printf '%s' "$output" | grep -qF 'so write-receipt can land'
  if printf '%s' "$output" | grep -qF 'artifact mode has ticked items but no receipts'; then
    return 1
  fi
  if printf '%s' "$output" | grep -qF 'complete ticked items with'; then
    return 1
  fi
}

@test "receipts helpers ignore files nested under receipts/" {
  a="$(new_artifact nested-receipts)"
  mkdir -p "$a/.nightshift/receipts/nested"
  printf 'nested\n' >"$a/.nightshift/receipts/nested/20260101T000000Z-nested.md"
  printf 'ok\n' >"$a/.nightshift/receipts/20260101T000000Z-real.md"
  latest="$(bash -c '. "$1"; ns_latest_receipt "$2"' _ "$LIB" "$a")"
  [ "$(basename "$latest")" = '20260101T000000Z-real.md' ]
  [ "$(bash -c '. "$1"; ns_receipts_count "$2"' _ "$LIB" "$a")" = 1 ]
  run bash "$DOCTOR" --project "$a"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'artifact receipts 1'
  printf '%s' "$output" | grep -qF 'latest artifact receipt 20260101T000000Z-real.md'
  grep -qF 'find "$dir" -maxdepth 1 -type f' "$STATE"
}

@test "latest receipt is absent when only hidden files exist" {
  a="$(new_artifact latest-hidden-only)"
  mkdir -p "$a/.nightshift/receipts"
  printf 'dot\n' >"$a/.nightshift/receipts/.not-a-receipt"
  if bash -c '. "$1"; ns_latest_receipt "$2"' _ "$LIB" "$a"; then
    false
  fi
  [ "$(bash -c '. "$1"; ns_receipts_count "$2"' _ "$LIB" "$a")" = 0 ]
  run bash "$DOCTOR" --project "$a"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'artifact receipts 0'
  if printf '%s' "$output" | grep -qF 'latest artifact receipt'; then
    return 1
  fi
}

@test "Doctor warns when artifact ticks have no receipts" {
  a="$(new_artifact ticks-no-receipts)"
  punch_open "$a"
  run bash "$DOCTOR" --project "$a"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'artifact mode has ticked items but no receipts'
  printf '%s' "$output" | grep -qF 'write-receipt.sh'

  printf 'ok\n' >"$a/out/topic.md"
  bash "$WRITE" --project "$a" --item 'x' --verify 'ok' --output "$a/out/topic.md" >/dev/null
  run bash "$DOCTOR" --project "$a"
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -qF 'artifact mode has ticked items but no receipts'; then
    return 1
  fi

  r="$(new_project ticks-repo)"
  punch_open "$r"
  run bash "$DOCTOR" --project "$r"
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -qF 'artifact mode has ticked items but no receipts'; then
    return 1
  fi
}

# Writing about the work is not doing it. A record the shift produced about itself — a receipt, a
# report section, a usage line, a rendered morning page — must not read as progress, or a shift
# that only ever describes itself would never look stuck.

# stall_site <name> — an artifact site whose stall warning is far enough away to watch the
# counter climb, and whose punch list has room for a tick to change something.
stall_site() {
  local p
  p="$(new_artifact "$1")"
  jq '.stallWarnEvery = 20' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  printf '## Items\n- [ ] **1. first.**\n- [ ] **2. second.**\n- [x] **3. done.**\n' \
    >"$p/.nightshift/punch-list.md"
  printf '%s' "$p"
}

stall_count() { sed -n '2p' "$1/.nightshift/.stall"; }

@test "a record the shift wrote about itself is not stall progress" {
  p="$(stall_site stall)"
  run gate "$p"
  run gate "$p"
  [ "$(stall_count "$p")" = "2" ]
  # A completion receipt, and a report section about the work: both are the shift describing
  # itself, and neither is the work moving.
  printf 'ok\n' >"$p/out/topic.md"
  run bash "$WRITE" --project "$p" --item 'x' --verify 'ok' --output "$p/out/topic.md"
  [ "$status" -eq 0 ]
  printf '# Shift report\n\n## item 1\n\nstill going.\n' >"$p/.nightshift/shift-report.md"
  run gate "$p"
  is_block "$output"
  [ "$(stall_count "$p")" = "3" ]
  # And again, with only the report changing.
  printf '# Shift report\n\n## item 1\n\nstill going, more words.\n' >"$p/.nightshift/shift-report.md"
  run gate "$p"
  is_block "$output"
  [ "$(stall_count "$p")" = "4" ]
}

@test "a tick is stall progress in artifact mode" {
  p="$(stall_site stall-tick)"
  run gate "$p"
  run gate "$p"
  [ "$(stall_count "$p")" = "2" ]
  # The item is finished, which is what a tick claims.
  printf '## Items\n- [x] **1. first.**\n- [ ] **2. second.**\n- [x] **3. done.**\n' \
    >"$p/.nightshift/punch-list.md"
  run gate "$p"
  is_block "$output"
  [ "$(stall_count "$p")" = "1" ]
}

@test "a substantive checkpoint is stall progress in artifact mode" {
  p="$(stall_site stall-checkpoint)"
  run gate "$p"
  run gate "$p"
  [ "$(stall_count "$p")" = "2" ]
  bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/evidence.sh" --project "$p" init >/dev/null
  bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/evidence.sh" --project "$p" append \
    --record "$(jq -nc '{
      schemaVersion: 1, id: "c1", domain: "checkpoint", sourceClass: "migration",
      source: "codemod", scope: "src/", severity: "info", confidence: "high",
      impact: "developer", status: "open", ladder: "measured", locator: "src/",
      digest: "dc1", firstSeen: "2026-09-02T00:00:00Z", lastChecked: "2026-09-02T00:00:00Z",
      action: "", host: "claude", workTarget: "/repo"
    }')" >/dev/null
  run gate "$p"
  is_block "$output"
  [ "$(stall_count "$p")" = "1" ]
}

@test "repository mode still treats a commit as stall progress" {
  grep -qF 'a commit resets the stall counter' "$BATS_TEST_DIRNAME/clock-out-gate.bats"
  p="$(new_project receipt-commit-stall)"
  punch_open "$p"
  run gate "$p"
  run gate "$p"
  git -C "$p" commit -q --allow-empty -m progress
  run gate "$p"
  is_block "$output"
  [ "$(sed -n '2p' "$p/.nightshift/.stall")" = "1" ]
}

@test "archive copies receipts, and removing one is a separate decision" {
  grep -qF 'archive/<YYYY-MM-DD>/receipts/' "$ARCHIVE"
  grep -qF 'Filing is a copy' "$ARCHIVE"
  grep -qE 'ns"? archive-receipts' "$ARCHIVE"
}

@test "skills and docs name artifact receipts" {
  grep -qE 'ns"? write-receipt' "$NIGHTSHIFT"
  grep -qF '$NS/receipts/' "$NIGHTSHIFT"
  # Start hands artifact completion to the main skill, which owns the item loop.
  grep -qF '$NS/receipts/' "$NIGHTSHIFT"
  grep -qF 'exists but is not a usable directory' "$SETUP"
  grep -qF 'do not `git init` the notes folder' "$NIGHTSHIFT"
  grep -qF 'when Git is installed' "$NIGHTSHIFT"
  grep -qE 'ns"? write-receipt' "$START"
  grep -qE 'ns"? write-receipt' "$SETUP"
  grep -qF '$NS/receipts/' "$SETUP"
  grep -qF 'do not treat artifact setup as complete' "$SETUP"
  grep -qF 'fact "artifact receipts"' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
  grep -qF 'latest artifact receipt' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
  grep -qF 'ns_latest_receipt' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
  grep -qF 'ticked items with no receipts are not reviewable completion' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
  grep -qF 'the artifact receipts path is not a usable directory' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
  grep -qF 'the empty-ticks warning is not also raised' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
  grep -qF 'archive/<YYYY-MM-DD>/receipts/' "$ARCHIVE"
  grep -qF 'do not replace the live files Status reports' "$ARCHIVE"
  grep -qF 'Missing or empty receipts create no dated receipts folder' "$ARCHIVE"
  grep -qF 'artifact receipts N' "$DOCTOR_SKILL"
  grep -qF 'latest artifact receipt' "$DOCTOR_SKILL"
  grep -qF 'most recently written' "$DOCTOR_SKILL"
  grep -qF 'artifact mode has ticked items but no receipts' "$DOCTOR_SKILL"
  grep -qF 'artifact receipts path is not a usable directory' "$DOCTOR_SKILL"
  grep -qF 'so write-receipt can land' "$DOCTOR_SKILL"
  grep -qF 'does not also warn empty ticks' "$DOCTOR_SKILL"
  grep -qF 'archive/<YYYY-MM-DD>/receipts/' "$DOCTOR_SKILL"
  grep -qF 'do not replace the live files Doctor counts' "$DOCTOR_SKILL"
  grep -qF 'Missing or empty receipts create no dated receipts folder' "$DOCTOR_SKILL"
  grep -qF 'artifact receipt' "$TEMPLATE"
  grep -qF '$NS/receipts/' "$TEMPLATE"
  grep -qF '$NS/receipts/' "$DRAFT_TEMPLATE"
  grep -qF 'runtime/write-receipt.sh' "$DOC"
  grep -qF 'runtime/archive-receipts.sh' "$DOC"
  grep -qF 'latest artifact receipt' "$DOC"
  grep -qF 'most recently written' "$DOC"
  grep -qF 'ticked items have no receipts' "$DOC"
  grep -qF 'artifact receipts path is not a usable directory' "$DOC"
  grep -qF 'replace it rather than write-receipt' "$DOC"
  grep -qF 'cannot land receipts' "$DOC"
  grep -qF '**artifact receipt**' "$VOCAB"
  grep -qF 'A path that is not a usable directory is a refuse, not an empty night' "$VOCAB"
  grep -qF '**archive**' "$VOCAB"
  grep -qF 'Filing is a copy' "$VOCAB"
  grep -qF 'Missing or empty receipts create no dated receipts folder' "$VOCAB"
  grep -qF 'runtime/write-receipt.sh' "$COMMANDS"
  grep -qF 'artifact mode has ticked items but no receipts' "$COMMANDS"
  grep -qF 'artifact receipts path is not a usable directory' "$COMMANDS"
  grep -qF 'replace it rather than write-receipt' "$COMMANDS"
  grep -qF 'cannot land receipts' "$COMMANDS"
  grep -qF 'latest artifact receipt' "$COMMANDS"
  grep -qF 'most recently written' "$COMMANDS"
  grep -qF 'local commits or artifact receipts' "$COMMANDS"
  grep -qF 'runtime\windows\write-receipt.ps1' "$COMMANDS"
  grep -qF 'runtime\windows\write-receipt.ps1' "$WINDOC"
  grep -qF 'runtime\windows\archive-receipts.ps1' "$WINDOC"
  grep -qF 'Missing or empty receipts create no dated receipts folder' "$WINDOC"
  grep -qF 'persistent folder' "$WINDOC"
  grep -qF 'latest artifact receipt' "$WINDOC"
  grep -qF 'most recently written' "$WINDOC"
  grep -qF 'artifact mode has ticked items but no receipts' "$WINDOC"
  grep -qF 'artifact receipts path is not a usable directory' "$WINDOC"
  grep -qF 'replace it rather than write-receipt' "$WINDOC"
  grep -qF 'cannot land receipts' "$WINDOC"
  grep -qF 'The GitHub issue hunt is skipped in artifact mode' "$WINDOC"
  grep -qF 'The defect hunt is skipped in artifact mode' "$WINDOC"
  grep -qF 'Documentation drift is skipped in artifact mode' "$WINDOC"
  grep -qF 'TODO and FIXME debt is skipped in artifact mode' "$WINDOC"
  grep -qF 'Coverage hunt is skipped in artifact mode' "$WINDOC"
  grep -qF 'Tooling quality-debt entries are skipped in artifact mode' "$WINDOC"
  grep -qF 'Do not `git init` a notes folder' "$WINDOC"
  grep -qF 'artifact receipts' "$README"
  grep -qF 'Doctor names the most recently written file' "$README"
  grep -qF 'artifact receipts path is not a usable directory' "$README"
  grep -qF 'cannot land receipts' "$README"
  grep -qF 'reviewable commits or artifact receipts' "$CODEX_PLUGIN"
  grep -qF 'Git repository or a local folder' "$CODEX_PLUGIN"
}

@test "Windows helpers pair the same receipt and stall token" {
  grep -qF 'function Get-NSReceiptsDir' "$PSM1"
  grep -qF 'function Test-NSUsableReceiptsDir' "$PSM1"
  grep -qF 'ns_receipts_usable_dir' "$STATE"
  grep -qF 'function Get-NSReceiptsCount' "$PSM1"
  grep -qF 'function Get-NSLatestReceipt' "$PSM1"
  grep -qF 'LastWriteTimeUtc.Ticks' "$PSM1"
  grep -qF '${path%.md}-0.md' "$STATE"
  grep -qF 'function Get-NSReceiptsFingerprint' "$PSM1"
  grep -qF 'function Get-NSProgressToken' "$PSM1"
  grep -qF 'Get-NSReceiptsCount' "$DOCTOR_PS1"
  grep -qF 'Get-NSLatestReceipt' "$DOCTOR_PS1"
  grep -qF 'artifact receipts' "$DOCTOR_PS1"
  grep -qF 'latest artifact receipt' "$DOCTOR_PS1"
  grep -qF 'artifact mode has ticked items but no receipts' "$DOCTOR_PS1"
  grep -qF 'artifact receipts path is not a usable directory' "$DOCTOR_PS1"
  grep -qF 'so write-receipt can land' "$DOCTOR_PS1"
  grep -qF 'unusableRecv' "$DOCTOR_PS1"
  grep -qF 'so write-receipt can land' "$DOCTOR"
  grep -qF 'UNUSABLE_RECV' "$DOCTOR"
  grep -qF "Join-Path \$here 'write-receipt.ps1'" "$DOCTOR_PS1"
  grep -qF 'Get-NSProgressToken' "$WIN_GATE"
  grep -qF 'ns_gate_progress_token' "$CORE"
  grep -qF 'ns_gate_progress_token' "$GATE"
  grep -qF 'ns_gate_progress_token' "$CODEX_GATE"
  [ -f "$WRITE_PS1" ]
  grep -qF 'Get-NSWorkMode' "$WRITE_PS1"
  grep -qF 'exit 3' "$WRITE_PS1"
  grep -qF 'exit 2' "$WRITE_PS1"
  grep -qF 'symlink receipts path' "$WRITE"
  grep -qF 'symlink receipts path' "$WRITE_PS1"
  grep -qF 'receipts path is not a directory' "$WRITE"
  grep -qF 'receipts path is not a directory' "$WRITE_PS1"
}

@test "Windows write-receipt logic passes when pwsh is present" {
  [ -f "$WRITE_LOGIC" ]
  grep -qF 'write-receipt-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  grep -qF 'Get-NSLatestReceipt' "$WRITE_LOGIC"
  grep -qF 'latest ignores a hidden sibling' "$WRITE_LOGIC"
  grep -qF 'symlink receipt is not counted' "$WRITE_LOGIC"
  grep -qF 'symlink receipt is not latest' "$WRITE_LOGIC"
  grep -qF 'nested receipt is not counted' "$WRITE_LOGIC"
  grep -qF 'nested receipt is not latest' "$WRITE_LOGIC"
  grep -qF 'does not write through a reparse receipts path' "$WRITE_LOGIC"
  grep -qF 'symlink work-mode is malformed' "$WRITE_LOGIC"
  grep -qF 'does not create receipts for a symlink work-mode' "$WRITE_LOGIC"
  grep -qF 'does not replace a file receipts path' "$WRITE_LOGIC"
  grep -qF 'Doctor warns when receipts path is not a usable directory' "$WRITE_LOGIC"
  grep -qF 'symlink output is missing' "$WRITE_LOGIC"
  grep -qF 'does not create receipts for a symlink output' "$WRITE_LOGIC"
  grep -qF 'Doctor offers a replace-path action when receipts path is unusable' "$WRITE_LOGIC"
  grep -qF 'Doctor does not offer write-receipt on an unusable receipts path' "$WRITE_LOGIC"
  grep -qF 'Doctor does not warn empty ticks when receipts path is unusable' "$WRITE_LOGIC"
  grep -qF 'artifact mode has ticked items but no receipts' "$WRITE_LOGIC"
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$WRITE_LOGIC"
  [ "$status" -eq 0 ]
}
