load helpers

ARCHIVE_SH="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/archive-receipts.sh"
ARCHIVE_PS1="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/archive-receipts.ps1"
ARCHIVE_LOGIC="$BATS_TEST_DIRNAME/windows/archive-receipts-logic.ps1"
ARCHIVE_SKILL="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/archive/SKILL.md"
COMMANDS="$BATS_TEST_DIRNAME/../docs/commands.md"
HOW="$BATS_TEST_DIRNAME/../docs/how-it-works.md"

new_artifact() {
  local p="$BATS_TEST_TMPDIR/${1:-artifact}"
  mkdir -p "$p/.nightshift" "$p/out"
  cp "$RULES_TEMPLATE" "$p/.nightshift/rules.json"
  : >"$p/.nightshift/.shift-armed"
  printf 'artifact\n' >"$p/.nightshift/work-mode"
  printf '%s\n' "$(cd -P "$p" && pwd)" >"$p/.nightshift/work-target"
  printf '%s' "$p"
}

@test "archive-receipts copies regular receipts and leaves live copies" {
  p="$(new_artifact copy)"
  mkdir -p "$p/.nightshift/receipts"
  printf 'one\n' >"$p/.nightshift/receipts/20260101T000000Z-one.md"
  printf 'two\n' >"$p/.nightshift/receipts/20260101T000001Z-two.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-08-28
  [ "$status" -eq 0 ]
  dest="$output"
  case "$dest" in */.nightshift/archive/2026-08-28/receipts) ;; *) echo "dest=$dest"; return 1 ;; esac
  [ -f "$p/.nightshift/receipts/20260101T000000Z-one.md" ]
  [ -f "$p/.nightshift/receipts/20260101T000001Z-two.md" ]
  [ -f "$dest/20260101T000000Z-one.md" ]
  [ -f "$dest/20260101T000001Z-two.md" ]
  grep -qF 'one' "$dest/20260101T000000Z-one.md"
}

@test "archive-receipts skips files nested under receipts/" {
  p="$(new_artifact nested)"
  mkdir -p "$p/.nightshift/receipts/nested"
  printf 'real\n' >"$p/.nightshift/receipts/20260101T000000Z-real.md"
  printf 'nested\n' >"$p/.nightshift/receipts/nested/20260101T000000Z-nested.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-08-28
  [ "$status" -eq 0 ]
  dest="$p/.nightshift/archive/2026-08-28/receipts"
  [ -f "$dest/20260101T000000Z-real.md" ]
  [ ! -e "$dest/20260101T000000Z-nested.md" ]
  grep -qF 'find "$src" -maxdepth 1 -type f' "$ARCHIVE_SH"
}

@test "archive-receipts skips hidden files and does not follow symlink receipts" {
  p="$(new_artifact hidden)"
  mkdir -p "$p/.nightshift/receipts"
  printf 'real\n' >"$p/.nightshift/receipts/20260101T000000Z-real.md"
  printf 'dot\n' >"$p/.nightshift/receipts/.not-a-receipt"
  ln -s "$p/.nightshift/receipts/20260101T000000Z-real.md" \
    "$p/.nightshift/receipts/20260101T000000Z-link.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-08-28
  [ "$status" -eq 0 ]
  dest="$p/.nightshift/archive/2026-08-28/receipts"
  [ -f "$dest/20260101T000000Z-real.md" ]
  [ ! -e "$dest/.not-a-receipt" ]
  [ ! -e "$dest/20260101T000000Z-link.md" ]
}

@test "archive-receipts is success when no receipts exist" {
  p="$(new_artifact empty)"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-08-28
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -d "$p/.nightshift/archive/2026-08-28/receipts" ]
}

@test "archive-receipts creates no dest when receipts exist but nothing copies" {
  p="$(new_artifact empty-dir)"
  mkdir -p "$p/.nightshift/receipts"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-08-28
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -d "$p/.nightshift/archive/2026-08-28/receipts" ]

  printf 'dot\n' >"$p/.nightshift/receipts/.not-a-receipt"
  mkdir -p "$p/.nightshift/receipts/nested"
  printf 'nested\n' >"$p/.nightshift/receipts/nested/20260101T000000Z-nested.md"
  ln -s "$p/.nightshift/receipts/nested/20260101T000000Z-nested.md" \
    "$p/.nightshift/receipts/20260101T000000Z-link.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-08-28
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -d "$p/.nightshift/archive/2026-08-28/receipts" ]
}

@test "archive-receipts refuses a malformed date and a missing project" {
  p="$(new_artifact bad-date)"
  run bash "$ARCHIVE_SH" --project "$p" --date not-a-date
  [ "$status" -eq 1 ]
  run bash "$ARCHIVE_SH" --project /no/such/nightshift-project
  [ "$status" -eq 1 ]
}

@test "archive-receipts refuses a symlink archive path" {
  p="$(new_artifact symlink-archive)"
  mkdir -p "$p/.nightshift/receipts" "$p/outside"
  printf 'real\n' >"$p/.nightshift/receipts/20260101T000000Z-real.md"
  ln -s "$p/outside" "$p/.nightshift/archive"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-08-28
  [ "$status" -eq 2 ]
  [ ! -e "$p/outside/receipts/20260101T000000Z-real.md" ]
}

@test "archive-receipts refuses a symlink receipts directory" {
  p="$(new_artifact symlink-recv-src)"
  mkdir -p "$p/outside"
  printf 'real\n' >"$p/outside/20260101T000000Z-real.md"
  ln -s "$p/outside" "$p/.nightshift/receipts"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-08-28
  [ "$status" -eq 2 ]
  [ ! -d "$p/.nightshift/archive/2026-08-28/receipts" ]
}

@test "archive-receipts refuses a non-directory receipts path" {
  p="$(new_artifact receipts-file-src)"
  printf 'not-a-dir\n' >"$p/.nightshift/receipts"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-08-28
  [ "$status" -eq 2 ]
  [ -f "$p/.nightshift/receipts" ]
  grep -qF 'not-a-dir' "$p/.nightshift/receipts"
  [ ! -d "$p/.nightshift/archive/2026-08-28/receipts" ]
}

@test "archive-receipts refuses a non-directory archive dest" {
  p="$(new_artifact dest-file)"
  mkdir -p "$p/.nightshift/receipts" "$p/.nightshift/archive/2026-08-28"
  printf 'real\n' >"$p/.nightshift/receipts/20260101T000000Z-real.md"
  printf 'not-a-dir\n' >"$p/.nightshift/archive/2026-08-28/receipts"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-08-28
  [ "$status" -eq 2 ]
  grep -qF 'not-a-dir' "$p/.nightshift/archive/2026-08-28/receipts"
}

@test "Archive skill names the receipts helper on POSIX and Windows" {
  grep -qF 'runtime/archive-receipts.sh' "$ARCHIVE_SKILL"
  grep -qF 'runtime\windows\archive-receipts.ps1' "$ARCHIVE_SKILL"
  grep -qF 'leave the live copies' "$ARCHIVE_SKILL"
  grep -qF 'Missing or empty receipts create no dated receipts folder' "$ARCHIVE_SKILL"
  grep -qF 'A receipts path that is not a usable directory is a refuse, not an empty skip' "$ARCHIVE_SKILL"
  grep -qF 'Never delete live receipts' "$ARCHIVE_SKILL"
  grep -qF 'Never call `archive-receipts.sh`' "$ARCHIVE_SKILL"
  grep -qF 'runtime/archive-receipts.sh' "$COMMANDS"
  grep -qF 'Missing or empty receipts create no dated receipts folder' "$COMMANDS"
  grep -qF 'runtime\windows\archive-receipts.ps1' "$COMMANDS"
  grep -qF 'runtime/archive-receipts.sh' "$HOW"
  grep -qF 'Missing or empty receipts create no dated receipts folder' "$HOW"
  [ -f "$ARCHIVE_PS1" ]
  grep -qF 'Get-NSReceiptsDir' "$ARCHIVE_PS1"
  grep -qF "StartsWith('.')" "$ARCHIVE_PS1"
  grep -qF 'symlink receipts path' "$ARCHIVE_SH"
  grep -qF 'symlink receipts path' "$ARCHIVE_PS1"
  grep -qF 'receipts path is not a directory' "$ARCHIVE_SH"
  grep -qF 'receipts path is not a directory' "$ARCHIVE_PS1"
  grep -qF 'non-directory archive path' "$ARCHIVE_SH"
  grep -qF 'non-directory archive path' "$ARCHIVE_PS1"
}

@test "Windows archive-receipts logic passes when pwsh is present" {
  [ -f "$ARCHIVE_LOGIC" ]
  grep -qF 'archive-receipts-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  grep -qF 'skip-only receipts create no archive folder' "$ARCHIVE_LOGIC"
  grep -qF 'leaves the first live receipt' "$ARCHIVE_LOGIC"
  grep -qF 'does not copy a nested receipt' "$ARCHIVE_LOGIC"
  grep -qF 'does not copy a hidden file' "$ARCHIVE_LOGIC"
  grep -qF 'does not copy a symlink receipt' "$ARCHIVE_LOGIC"
  grep -qF 'does not write through a reparse archive path' "$ARCHIVE_LOGIC"
  grep -qF 'does not copy through a reparse receipts path' "$ARCHIVE_LOGIC"
  grep -qF 'does not replace a file receipts path' "$ARCHIVE_LOGIC"
  grep -qF 'does not replace a file archive dest' "$ARCHIVE_LOGIC"
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$ARCHIVE_LOGIC"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------
# Where a shift is filed is the owner's; that it stays inside the state area is not. The shift id
# names the files either way, so nothing collides and an old default-path history stays findable.

arch_rules() { # <project> <jq-expression>
  jq "$2" "$1/.nightshift/rules.json" >"$1/r.json"
  mv "$1/r.json" "$1/.nightshift/rules.json"
}

@test "a custom archive root is honoured and stays inside the state area" {
  p="$(new_project arch-root)"
  arch_rules "$p" '.archive.root = "history"'
  mkdir -p "$p/.nightshift/receipts"
  printf 'one\n' >"$p/.nightshift/receipts/morning-2026-09-05-abc.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/history/2026-09-05/receipts/morning-2026-09-05-abc.md" ]
  [ ! -d "$p/.nightshift/archive/2026-09-05" ]
  # The live copy stays where progress and recovery still look for it.
  [ -f "$p/.nightshift/receipts/morning-2026-09-05-abc.md" ]
}

@test "the shift layout gives each shift its own directory" {
  p="$(new_project arch-layout)"
  arch_rules "$p" '.archive.layout = "shift"'
  printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T00:00:00Z","source":"composition","verificationLevel":"none","toolingPolicy":"existing-tools"}\n' \
    >"$p/.nightshift/shift-policy.json"
  mkdir -p "$p/.nightshift/receipts"
  printf 'one\n' >"$p/.nightshift/receipts/morning-2026-09-05-9f2c40ab77e51d63.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  [ -d "$p/.nightshift/archive/shift-9f2c40ab77e51d63/receipts" ]
  [ ! -d "$p/.nightshift/archive/2026-09-05" ]
}

@test "a root that would leave the state area is refused, not followed" {
  for bad in "../escape" "/tmp/elsewhere" "sub/../../out"; do
    p="$(new_project "arch-escape-$(printf '%s' "$bad" | tr -c 'a-z' -)")"
    arch_rules "$p" ".archive.root = \"$bad\""
    mkdir -p "$p/.nightshift/receipts"
    printf 'one\n' >"$p/.nightshift/receipts/morning-2026-09-05-abc.md"
    run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
    [ "$status" -eq 2 ] || { echo "$bad was not refused"; return 1; }
    printf '%s\n' "$output" | grep -qF 'inside .nightshift/'
  done
}

@test "a symlinked archive root is refused" {
  p="$(new_project arch-symlink)"
  arch_rules "$p" '.archive.root = "linked"'
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  ln -s "$BATS_TEST_TMPDIR/outside" "$p/.nightshift/linked"
  mkdir -p "$p/.nightshift/receipts"
  printf 'one\n' >"$p/.nightshift/receipts/morning-2026-09-05-abc.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 2 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/outside")" ]
}

@test "filing the same day twice adds nothing twice and overwrites no earlier record" {
  p="$(new_project arch-twice)"
  mkdir -p "$p/.nightshift/receipts"
  printf 'first\n' >"$p/.nightshift/receipts/morning-2026-09-05-aaa.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  # A second shift the same day files beside the first, not over it.
  printf 'second\n' >"$p/.nightshift/receipts/morning-2026-09-05-bbb.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  d="$p/.nightshift/archive/2026-09-05/receipts"
  [ "$(cat "$d/morning-2026-09-05-aaa.md")" = first ]
  [ "$(cat "$d/morning-2026-09-05-bbb.md")" = second ]
  [ "$(find "$d" -name 'morning-*' | wc -l | tr -d ' ')" -eq 2 ]
}

@test "a history filed under the default root is still there after the root changes" {
  p="$(new_project arch-both)"
  mkdir -p "$p/.nightshift/receipts"
  printf 'old\n' >"$p/.nightshift/receipts/morning-2026-09-04-old.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-04
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/archive/2026-09-04/receipts/morning-2026-09-04-old.md" ]
  # The owner moves the root; nothing already filed is touched or lost.
  arch_rules "$p" '.archive.root = "history"'
  printf 'new\n' >"$p/.nightshift/receipts/morning-2026-09-05-new.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/history/2026-09-05/receipts/morning-2026-09-05-new.md" ]
  [ -f "$p/.nightshift/archive/2026-09-04/receipts/morning-2026-09-04-old.md" ]
}

@test "the ledger and the policy are filed where the receipts are" {
  p="$(new_project arch-together)"
  arch_rules "$p" '.archive.root = "history"'
  rm -f "$p/.nightshift/.shift-armed"
  printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T00:00:00Z","source":"composition","verificationLevel":"none","toolingPolicy":"existing-tools"}\n' \
    >"$p/.nightshift/shift-policy.json"
  bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/evidence.sh" --project "$p" init >/dev/null
  printf '{"schemaVersion":1}\n' >>"$p/.nightshift/evidence/findings.jsonl"
  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/evidence-archive.sh" \
    --project "$p" --shift-id 9f2c40ab77e51d63
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF '/.nightshift/history/'
  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/shift-policy.sh" --project "$p" archive
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF '/.nightshift/history/'
}

# ---------------------------------------------------------------------------------------------
# A record leaves live storage because its shift is closed and its archived copy verified — never
# because of what it is called, and never while the shift is still running.

closed() { # <project> — the shift ended
  rm -f "$1/.nightshift/.shift-armed"
  : >"$1/.nightshift/.ended"
}

@test "an armed shift keeps every live record" {
  p="$(new_project rot-armed)"
  mkdir -p "$p/.nightshift/receipts"
  printf 'morning\n' >"$p/.nightshift/receipts/morning-2026-09-05-abc.md"
  printf 'item\n' >"$p/.nightshift/receipts/2026-09-05-an-item.md"
  printf '# Shift report\n' >"$p/.nightshift/shift-report.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  # Filed, and still live: a running shift reads its own receipts.
  [ -f "$p/.nightshift/archive/2026-09-05/receipts/morning-2026-09-05-abc.md" ]
  [ -f "$p/.nightshift/receipts/morning-2026-09-05-abc.md" ]
  [ -f "$p/.nightshift/receipts/2026-09-05-an-item.md" ]
  [ -f "$p/.nightshift/shift-report.md" ]
}

@test "a closed shift retires its verified records, report and all" {
  p="$(new_project rot-closed)"
  mkdir -p "$p/.nightshift/receipts"
  printf 'morning\n' >"$p/.nightshift/receipts/morning-2026-09-05-abc.md"
  printf 'item\n' >"$p/.nightshift/receipts/2026-09-05-an-item.md"
  printf '# Shift report\n\n## P01\n\ndone.\n' >"$p/.nightshift/shift-report.md"
  closed "$p"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  d="$p/.nightshift/archive/2026-09-05"
  [ -f "$d/receipts/morning-2026-09-05-abc.md" ]
  [ -f "$d/receipts/2026-09-05-an-item.md" ]
  [ -f "$d/shift-report.md" ]
  # The archived copies are what the live ones were.
  [ "$(cat "$d/receipts/2026-09-05-an-item.md")" = item ]
  [ "$(cat "$d/shift-report.md" | head -1)" = '# Shift report' ]
  # And live storage is clear for the next shift.
  [ ! -f "$p/.nightshift/receipts/morning-2026-09-05-abc.md" ]
  [ ! -f "$p/.nightshift/receipts/2026-09-05-an-item.md" ]
  [ ! -f "$p/.nightshift/shift-report.md" ]
}

@test "a different record under a filed name is never overwritten and never removed" {
  p="$(new_project rot-clash)"
  mkdir -p "$p/.nightshift/receipts" "$p/.nightshift/archive/2026-09-05/receipts"
  printf 'live\n' >"$p/.nightshift/receipts/2026-09-05-same.md"
  printf 'already filed\n' >"$p/.nightshift/archive/2026-09-05/receipts/2026-09-05-same.md"
  closed "$p"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'a different record is already filed under that name'
  [ "$(cat "$p/.nightshift/archive/2026-09-05/receipts/2026-09-05-same.md")" = 'already filed' ]
  [ "$(cat "$p/.nightshift/receipts/2026-09-05-same.md")" = live ]
}

@test "filing a closed shift twice is safe" {
  p="$(new_project rot-repeat)"
  mkdir -p "$p/.nightshift/receipts"
  printf 'item\n' >"$p/.nightshift/receipts/2026-09-05-an-item.md"
  closed "$p"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  [ ! -f "$p/.nightshift/receipts/2026-09-05-an-item.md" ]
  before="$(cksum <"$p/.nightshift/archive/2026-09-05/receipts/2026-09-05-an-item.md")"
  # Nothing left to file, and the archived record is untouched.
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  [ "$(cksum <"$p/.nightshift/archive/2026-09-05/receipts/2026-09-05-an-item.md")" = "$before" ]
}

@test "a record whose archived copy does not match is kept live" {
  p="$(new_project rot-mismatch)"
  mkdir -p "$p/.nightshift/receipts" "$p/.nightshift/archive/2026-09-05/receipts"
  printf 'the real record\n' >"$p/.nightshift/receipts/2026-09-05-an-item.md"
  # A copy that was truncated by an interrupted earlier run.
  printf 'the real\n' >"$p/.nightshift/archive/2026-09-05/receipts/2026-09-05-an-item.md"
  closed "$p"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/receipts/2026-09-05-an-item.md" ]
  [ "$(cat "$p/.nightshift/receipts/2026-09-05-an-item.md")" = 'the real record' ]
}
