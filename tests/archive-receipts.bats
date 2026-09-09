load helpers

ARCHIVE_SH="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/archive-receipts.sh"
LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
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
  grep -qE 'ns"? archive-receipts' "$ARCHIVE_SKILL"
  grep -qF 'Missing or empty receipts create no dated receipts folder' "$ARCHIVE_SKILL"
  grep -qF 'A receipts path that is not a usable directory is a refuse, not an empty skip' "$ARCHIVE_SKILL"
  grep -qF 'Filing is a copy' "$ARCHIVE_SKILL"
  grep -qF -e '--retire' "$ARCHIVE_SKILL"
  grep -qF 'Never call `ns archive-receipts`' "$ARCHIVE_SKILL"
  grep -qE 'ns"? archive-receipts' "$COMMANDS"
  grep -qF 'Missing or empty receipts create no dated receipts folder' "$COMMANDS"
  grep -qF 'ns.ps1 archive-receipts' "$COMMANDS"
  grep -qE 'ns"? archive-receipts' "$HOW"
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

@test "an archive root reached through a link anywhere along it is refused" {
  # The escape is not a link at the root: it is a link on the way to it. `linked/history` is an
  # ordinary directory name and would pass a check that only looked at its last component.
  p="$(new_project arch-intermediate)"
  arch_rules "$p" '.archive.root = "linked/history"'
  mkdir -p "$BATS_TEST_TMPDIR/outside-intermediate"
  ln -s "$BATS_TEST_TMPDIR/outside-intermediate" "$p/.nightshift/linked"
  mkdir -p "$p/.nightshift/receipts"
  printf 'one\n' >"$p/.nightshift/receipts/morning-2026-09-05-abc.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 2 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/outside-intermediate")" ]
  # And the source it refused to file is still where it was.
  [ -f "$p/.nightshift/receipts/morning-2026-09-05-abc.md" ]
}

@test "a dangling link, a file in the way and the live records are all refused as roots" {
  p="$(new_project arch-unsafe-roots)"
  mkdir -p "$p/.nightshift/receipts"
  ln -s "$BATS_TEST_TMPDIR/never-created" "$p/.nightshift/dangling"
  printf 'not a directory\n' >"$p/.nightshift/afile"
  for bad in "dangling/history" "afile" "afile/history" "receipts" ".hidden"; do
    arch_rules "$p" ".archive.root = \"$bad\""
    run bash -c '. "$1"; ns_archive_root "$2"' _ "$LIB" "$p"
    [ "$status" -eq 2 ] || { echo "$bad resolved to $output"; return 1; }
  done
  # A sibling whose name merely starts the same way is an ordinary directory and is allowed.
  arch_rules "$p" '.archive.root = "archive-old"'
  run bash -c '. "$1"; ns_archive_root "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ "$output" = "$p/.nightshift/archive-old" ]
}

@test "a link where a record is about to land is refused before anything is written" {
  p="$(new_project arch-leaf-link)"
  target="$BATS_TEST_TMPDIR/leaf-target.md"
  printf 'original\n' >"$target"
  run bash -c '. "$1"; ns_archive_dest "$2"' _ "$LIB" "$p/.nightshift/fresh.md"
  [ "$status" -eq 0 ]
  ln -s "$target" "$p/.nightshift/planted.md"
  run bash -c '. "$1"; ns_archive_dest "$2"' _ "$LIB" "$p/.nightshift/planted.md"
  [ "$status" -eq 2 ]
  [ "$(cat "$target")" = original ]
  mkdir -p "$p/.nightshift/adir"
  run bash -c '. "$1"; ns_archive_dest "$2"' _ "$LIB" "$p/.nightshift/adir"
  [ "$status" -eq 2 ]
}

@test "a planted link at a record's archived name keeps the source and files nothing through it" {
  p="$(new_project arch-planted-leaf)"
  mkdir -p "$p/.nightshift/receipts" "$p/.nightshift/archive/2026-09-05/receipts"
  printf 'the real record\n' >"$p/.nightshift/receipts/morning-2026-09-05-abc.md"
  # A link whose target already holds the same bytes: following it would read back as a faithful
  # copy and the live record would be retired into a file outside the archive.
  outside="$BATS_TEST_TMPDIR/planted-target.md"
  printf 'the real record\n' >"$outside"
  ln -s "$outside" "$p/.nightshift/archive/2026-09-05/receipts/morning-2026-09-05-abc.md"
  closed "$p"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'in the way of its archived copy'
  [ -f "$p/.nightshift/receipts/morning-2026-09-05-abc.md" ]
  [ -L "$p/.nightshift/archive/2026-09-05/receipts/morning-2026-09-05-abc.md" ]
  [ "$(cat "$outside")" = 'the real record' ]
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

# Both twins archive the ledger; both have to say where it went. The Windows one was written as
# `exit (Invoke-NSEvidenceArchive ...)`, which made the path part of the expression's value, so it
# archived correctly and printed nothing at all.
@test "both twins name the archived ledger" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
  posix="$(new_project arch-twin-posix)"
  win="$(new_project arch-twin-win)"
  for p in "$posix" "$win"; do
    rm -f "$p/.nightshift/.shift-armed"
    bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/evidence.sh" --project "$p" init >/dev/null
    printf '{"schemaVersion":1}\n' >>"$p/.nightshift/evidence/findings.jsonl"
  done

  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/evidence-archive.sh" \
    --project "$posix" --shift-id 9f2c40ab77e51d63
  [ "$status" -eq 0 ]
  a="$(printf '%s\n' "$output" | tail -1)"

  run pwsh -NoProfile -NonInteractive -File \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/evidence-archive.ps1" \
    -Project "$win" -ShiftId 9f2c40ab77e51d63
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  b="$(printf '%s\n' "$output" | tail -1)"

  # Same name, each under its own workspace, and neither is empty.
  [ -n "$a" ] && [ -n "$b" ]
  [ "${a##*/}" = "${b##*/}" ]
  [ -f "$a" ] && [ -f "$b" ]
  # The live ledger is emptied on both, which is the other half of archiving it.
  [ ! -s "$posix/.nightshift/evidence/findings.jsonl" ]
  [ ! -s "$win/.nightshift/evidence/findings.jsonl" ]
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

@test "a closed shift retires the records it was told are closed, and only those" {
  p="$(new_project rot-closed)"
  mkdir -p "$p/.nightshift/receipts"
  printf 'morning\n' >"$p/.nightshift/receipts/morning-2026-09-05-abc.md"
  printf 'item\n' >"$p/.nightshift/receipts/2026-09-05-an-item.md"
  printf '# Shift report\n\n## P01\n\ndone.\n' >"$p/.nightshift/shift-report.md"
  closed "$p"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 \
    --retire morning-2026-09-05-abc.md --retire 2026-09-05-an-item.md --retire shift-report.md
  [ "$status" -eq 0 ]
  d="$p/.nightshift/archive/2026-09-05"
  [ -f "$d/receipts/morning-2026-09-05-abc.md" ]
  [ -f "$d/receipts/2026-09-05-an-item.md" ]
  [ -f "$d/shift-report.md" ]
  # The archived copies are what the live ones were.
  [ "$(cat "$d/receipts/2026-09-05-an-item.md")" = item ]
  [ "$(head -1 "$d/shift-report.md")" = '# Shift report' ]
  # And live storage is clear for the next shift.
  [ ! -f "$p/.nightshift/receipts/morning-2026-09-05-abc.md" ]
  [ ! -f "$p/.nightshift/receipts/2026-09-05-an-item.md" ]
  [ ! -f "$p/.nightshift/shift-report.md" ]
}

@test "an ended shift still holding open work keeps what that work needs" {
  # STOP and the deadline both end a shift with work still open, so a terminal marker is not
  # evidence that any particular record is finished with.
  p="$(new_project rot-open-work)"
  mkdir -p "$p/.nightshift/receipts"
  printf '## Items\n- [x] **P01 done.**\n- [ ] **P02 open, and its baseline is receipts/baseline.md.**\n' \
    >"$p/.nightshift/punch-list.md"
  printf 'the P02 baseline\n' >"$p/.nightshift/receipts/baseline.md"
  printf 'morning\n' >"$p/.nightshift/receipts/morning-2026-09-05-abc.md"
  printf '# Shift report\n' >"$p/.nightshift/shift-report.md"
  closed "$p"

  # Told nothing, it retires nothing: every record is still where the open item can reach it.
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/receipts/baseline.md" ]
  [ -f "$p/.nightshift/receipts/morning-2026-09-05-abc.md" ]
  [ -f "$p/.nightshift/shift-report.md" ]
  [ -f "$p/.nightshift/archive/2026-09-05/receipts/baseline.md" ]

  # Told which record is closed, it retires that one and leaves the open item's baseline alone.
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire morning-2026-09-05-abc.md
  [ "$status" -eq 0 ]
  [ ! -f "$p/.nightshift/receipts/morning-2026-09-05-abc.md" ]
  [ -f "$p/.nightshift/receipts/baseline.md" ]
  [ "$(cat "$p/.nightshift/receipts/baseline.md")" = 'the P02 baseline' ]
}

@test "a name this run did not file is refused rather than passed over" {
  p="$(new_project rot-unmatched)"
  mkdir -p "$p/.nightshift/receipts"
  printf 'item\n' >"$p/.nightshift/receipts/2026-09-05-an-item.md"
  closed "$p"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire 2026-09-05-never-existed.md
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'this run filed no such record'
  printf '%s\n' "$output" | grep -qF '2026-09-05-never-existed.md'
  [ -f "$p/.nightshift/receipts/2026-09-05-an-item.md" ]
}

@test "retiring is refused outright while the shift is armed or has not ended" {
  p="$(new_project rot-not-ended)"
  mkdir -p "$p/.nightshift/receipts"
  printf 'item\n' >"$p/.nightshift/receipts/2026-09-05-an-item.md"
  # new_project leaves the shift armed, the way Start does.
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire 2026-09-05-an-item.md
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'while the shift is armed'
  [ -f "$p/.nightshift/receipts/2026-09-05-an-item.md" ]

  # Disarmed but never ended: the shift is not over, so nothing of it is closed either.
  rm -f "$p/.nightshift/.shift-armed"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire 2026-09-05-an-item.md
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'before the shift has ended'
  [ -f "$p/.nightshift/receipts/2026-09-05-an-item.md" ]
}

@test "--retire takes a record name, never a path out of the archive" {
  p="$(new_project rot-badname)"
  mkdir -p "$p/.nightshift/receipts"
  closed "$p"
  for bad in "../escape.md" "sub/x.md" ".hidden.md" ""; do
    run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire "$bad"
    [ "$status" -eq 1 ] || { echo "$bad was accepted"; return 1; }
  done
}

@test "the archived report still reaches the records that stayed live" {
  p="$(new_project rot-links)"
  mkdir -p "$p/.nightshift/receipts"
  printf 'the baseline\n' >"$p/.nightshift/receipts/baseline.md"
  printf '# Parking\n\n## A live decision\n' >"$p/.nightshift/parking-lot.md"
  printf '# Snag\n\n- a finding\n' >"$p/.nightshift/snag-log.md"
  # A real project deliverable beside the state directory, the way a workspace holds its repo.
  mkdir -p "$p/claude-nightshift"
  printf '# The deliverable\n' >"$p/claude-nightshift/README.md"
  cat >"$p/.nightshift/shift-report.md" <<'REPORT'
# Shift report

The baseline is [here](receipts/baseline.md) and the decision is in
[parking-lot.md](parking-lot.md#a-live-decision), with the finding in [snag-log.md](snag-log.md).
The deliverable itself: [the README](../claude-nightshift/README.md).
Unrelated: [the docs](https://example.invalid/x), [an output](../out/build.log), [root](/etc/hosts).

```
[not a link](parking-lot.md)
```

[ref]: ../claude-nightshift/README.md "the same deliverable, by reference"
REPORT
  closed "$p"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire baseline.md
  [ "$status" -eq 0 ]

  d="$p/.nightshift/archive/2026-09-05"
  # Every link in the archived page resolves from where that page now sits.
  ( cd "$d" && [ -f receipts/baseline.md ] ) || { echo "the travelled record moved out of reach"; return 1; }
  ( cd "$d" && [ -f ../../parking-lot.md ] ) || { echo "the live decision is unreachable"; return 1; }
  ( cd "$d" && [ -f ../../snag-log.md ] ) || { echo "the live snag log is unreachable"; return 1; }
  grep -qF '(../../parking-lot.md#a-live-decision)' "$d/shift-report.md"
  grep -qF '(receipts/baseline.md)' "$d/shift-report.md"
  # Nothing else is touched: an external link, a path outside the state area, an absolute path,
  # and a fenced block all read exactly as written.
  grep -qF '(https://example.invalid/x)' "$d/shift-report.md"
  grep -qF '(/etc/hosts)' "$d/shift-report.md"
  grep -qF '[not a link](parking-lot.md)' "$d/shift-report.md"
  # A link that already climbed out of the state area climbed from the report's own directory,
  # and the report is two levels deeper now. The project deliverable it names still resolves.
  ( cd "$d" && [ -f ../../../claude-nightshift/README.md ] ) \
    || { echo "the project deliverable is unreachable from the archived report"; return 1; }
  grep -qF '(../../../claude-nightshift/README.md)' "$d/shift-report.md"
  grep -qF ': ../../../claude-nightshift/README.md "the same deliverable, by reference"' "$d/shift-report.md"
  grep -qF '(../../../out/build.log)' "$d/shift-report.md"

  # Rewriting changed bytes, so the untouched original is preserved beside the relocated page.
  [ -f "$d/shift-report.original.md" ]
  cmp -s "$d/shift-report.original.md" <(sed 's/^$//' "$d/shift-report.original.md")
  grep -qF '(parking-lot.md#a-live-decision)' "$d/shift-report.original.md"
}

@test "a report whose links all travelled is filed unchanged, with no second copy" {
  p="$(new_project rot-links-nochange)"
  mkdir -p "$p/.nightshift/receipts"
  printf 'the baseline\n' >"$p/.nightshift/receipts/baseline.md"
  printf '# Shift report\n\nOnly [the baseline](receipts/baseline.md) is linked.\n' \
    >"$p/.nightshift/shift-report.md"
  before="$(cksum <"$p/.nightshift/shift-report.md")"
  closed "$p"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire baseline.md
  [ "$status" -eq 0 ]
  d="$p/.nightshift/archive/2026-09-05"
  [ "$(cksum <"$d/shift-report.md")" = "$before" ]
  [ ! -e "$d/shift-report.original.md" ]
}

@test "filing a relocated report twice neither duplicates it nor calls it a clash" {
  p="$(new_project rot-links-repeat)"
  mkdir -p "$p/.nightshift/receipts"
  printf '# Parking\n' >"$p/.nightshift/parking-lot.md"
  printf '# Shift report\n\n[the decision](parking-lot.md)\n' >"$p/.nightshift/shift-report.md"
  closed "$p"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  d="$p/.nightshift/archive/2026-09-05"
  relocated="$(cksum <"$d/shift-report.md")"

  # The archived page differs from the live one by design, so a second run must recognise it
  # rather than report two different records under one name.
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qvF 'a different record is already filed'
  [ "$(cksum <"$d/shift-report.md")" = "$relocated" ]
  [ -f "$p/.nightshift/shift-report.md" ]

  # And it is the preserved original that establishes the report is the same one, so naming it
  # closed still retires the live copy.
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire shift-report.md
  [ "$status" -eq 0 ]
  [ ! -f "$p/.nightshift/shift-report.md" ]
  [ "$(cksum <"$d/shift-report.md")" = "$relocated" ]
}

@test "Windows files to the same place, retires the same record and relocates the same links" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  build() { # <project>
    mkdir -p "$1/.nightshift/receipts"
    cp "$RULES_TEMPLATE" "$1/.nightshift/rules.json"
    jq '.archive.root = "history" | .archive.layout = "date"' "$1/.nightshift/rules.json" >"$1/r.json"
    mv "$1/r.json" "$1/.nightshift/rules.json"
    printf 'the baseline\n' >"$1/.nightshift/receipts/baseline.md"
    printf 'morning\n' >"$1/.nightshift/receipts/morning-2026-09-05-abc.md"
    printf '# Parking\n' >"$1/.nightshift/parking-lot.md"
    printf '# Report\n\n[base](receipts/baseline.md) and [decision](parking-lot.md#x)\n' \
      >"$1/.nightshift/shift-report.md"
    : >"$1/.nightshift/.ended"
  }
  posix="$BATS_TEST_TMPDIR/parity-posix"
  windows="$BATS_TEST_TMPDIR/parity-windows"
  build "$posix"
  build "$windows"

  run bash "$ARCHIVE_SH" --project "$posix" --date 2026-09-05 --retire morning-2026-09-05-abc.md
  [ "$status" -eq 0 ]
  run pwsh -NoProfile -NonInteractive -File "$ARCHIVE_PS1" \
    -Project "$windows" -Date 2026-09-05 -Retire morning-2026-09-05-abc.md
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  # The configured root is honoured on both, so neither writes under the hardcoded archive/.
  [ -d "$posix/.nightshift/history/2026-09-05" ]
  [ -d "$windows/.nightshift/history/2026-09-05" ]
  [ ! -e "$windows/.nightshift/archive" ]
  run diff -r "$posix/.nightshift/history" "$windows/.nightshift/history"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # And both retired the named record while leaving the other alone.
  [ ! -f "$windows/.nightshift/receipts/morning-2026-09-05-abc.md" ]
  [ -f "$windows/.nightshift/receipts/baseline.md" ]
}

@test "Windows refuses to retire before the shift ends, and a name it did not file" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  p="$BATS_TEST_TMPDIR/win-retire"
  mkdir -p "$p/.nightshift/receipts"
  cp "$RULES_TEMPLATE" "$p/.nightshift/rules.json"
  printf 'item\n' >"$p/.nightshift/receipts/an-item.md"

  run pwsh -NoProfile -NonInteractive -File "$ARCHIVE_PS1" -Project "$p" -Date 2026-09-05 -Retire an-item.md
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'before the shift has ended'
  [ -f "$p/.nightshift/receipts/an-item.md" ]

  : >"$p/.nightshift/.ended"
  run pwsh -NoProfile -NonInteractive -File "$ARCHIVE_PS1" -Project "$p" -Date 2026-09-05 -Retire never-existed.md
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'this run filed no such record'
  [ -f "$p/.nightshift/receipts/an-item.md" ]

  for bad in "../escape.md" "sub/x.md" ".hidden.md"; do
    run pwsh -NoProfile -NonInteractive -File "$ARCHIVE_PS1" -Project "$p" -Date 2026-09-05 -Retire "$bad"
    [ "$status" -eq 1 ] || { echo "$bad was accepted"; return 1; }
  done
}

# Clock-out archives the live policy, so a later Archive has no policy to read a shift id or an
# archive destination from. These run the whole sequence — gate first, filing afterwards — rather
# than calling the archiver while the policy is still there to answer.

# clock_out <project> — the real gate, on a shift with every box ticked.
clock_out() {
  jq -nc '{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:""}' |
    env CLAUDE_PROJECT_DIR="$1" bash "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/clock-out-gate.sh"
}

# composed <project> <shift-id> — a workspace whose shift was composed and is ready to end.
composed() {
  local sh="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/shift-policy.sh"
  mkdir -p "$1/.nightshift/receipts"
  rm -f "$1/.nightshift/.shift-armed"
  jq -nc --arg id "$2" '{schemaVersion:1,shiftId:$id,createdAt:"2026-09-02T00:00:00Z",
    source:"composition",deadlineEpoch:null,verificationLevel:"none",toolingPolicy:"existing-tools"}' |
    "$sh" --project "$1" set --from-json - >/dev/null
  printf '## Items\n- [x] **1. done.**\n' >"$1/.nightshift/punch-list.md"
  : >"$1/.nightshift/.shift-armed"
}

@test "a shift filed after clock-out is filed under its own name, not a date bucket" {
  p="$(new_project ident-shift-layout)"
  arch_rules "$p" '.archive.layout = "shift" | .archive.root = "history"'
  composed "$p" 9f2c40ab77e51d63
  printf 'a receipt\n' >"$p/.nightshift/receipts/2026-09-05-an-item.md"

  run clock_out "$p"
  [ -f "$p/.nightshift/.ended" ]
  # The live policy is gone, exactly as it is for any later Archive.
  [ ! -f "$p/.nightshift/shift-policy.json" ]

  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire 2026-09-05-an-item.md
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/history/shift-9f2c40ab77e51d63/receipts/2026-09-05-an-item.md" ] \
    || { echo "filed to: $(find "$p/.nightshift/history" -type d | tr '\n' ' ')"; return 1; }
  [ ! -d "$p/.nightshift/history/2026-09-05" ]
}

@test "an owner edit between clock-out and Archive does not move where the shift files" {
  p="$(new_project ident-frozen-dest)"
  arch_rules "$p" '.archive.layout = "shift" | .archive.root = "history"'
  composed "$p" 9f2c40ab77e51d63
  printf 'a receipt\n' >"$p/.nightshift/receipts/2026-09-05-an-item.md"
  run clock_out "$p"

  # The owner changes their mind after the night is over. The night still files where it decided.
  arch_rules "$p" '.archive.layout = "date" | .archive.root = "elsewhere"'
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/history/shift-9f2c40ab77e51d63/receipts/2026-09-05-an-item.md" ]
  [ ! -d "$p/.nightshift/elsewhere" ]
}

@test "two shifts on one date keep their records apart" {
  p="$(new_project ident-two-shifts)"
  arch_rules "$p" '.archive.layout = "shift" | .archive.root = "history"'

  composed "$p" 1111111111111111
  printf 'the first night\n' >"$p/.nightshift/receipts/2026-09-05-an-item.md"
  run clock_out "$p"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire 2026-09-05-an-item.md
  [ "$status" -eq 0 ]

  # The same day, a second shift, and a record that happens to share the first one's name.
  rm -f "$p/.nightshift/.ended"
  composed "$p" 2222222222222222
  printf 'the second night\n' >"$p/.nightshift/receipts/2026-09-05-an-item.md"
  run clock_out "$p"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire 2026-09-05-an-item.md
  [ "$status" -eq 0 ]

  [ "$(cat "$p/.nightshift/history/shift-1111111111111111/receipts/2026-09-05-an-item.md")" = 'the first night' ]
  [ "$(cat "$p/.nightshift/history/shift-2222222222222222/receipts/2026-09-05-an-item.md")" = 'the second night' ]
}

@test "an unfinished item keeps its evidence through the whole sequence" {
  p="$(new_project ident-open-work)"
  arch_rules "$p" '.archive.layout = "shift" | .archive.root = "history"'
  composed "$p" 9f2c40ab77e51d63
  printf 'the P02 baseline\n' >"$p/.nightshift/receipts/baseline.md"
  printf 'morning\n' >"$p/.nightshift/receipts/morning-2026-09-05-abc.md"
  # The shift is stopped with work still open, which is what STOP and the deadline both do.
  printf '## Items\n- [x] **1. done.**\n- [ ] **2. open, and it needs receipts/baseline.md.**\n' \
    >"$p/.nightshift/punch-list.md"
  printf 'owner said stop\n' >"$p/.nightshift/STOP"
  run clock_out "$p"
  [ -f "$p/.nightshift/.ended" ]

  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire morning-2026-09-05-abc.md
  [ "$status" -eq 0 ]
  # The closed record is retired; the one the open item needs is exactly where it was.
  [ ! -f "$p/.nightshift/receipts/morning-2026-09-05-abc.md" ]
  [ "$(cat "$p/.nightshift/receipts/baseline.md")" = 'the P02 baseline' ]
  [ -f "$p/.nightshift/history/shift-9f2c40ab77e51d63/receipts/baseline.md" ]
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
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire 2026-09-05-an-item.md
  [ "$status" -eq 0 ]
  [ ! -f "$p/.nightshift/receipts/2026-09-05-an-item.md" ]
  before="$(cksum <"$p/.nightshift/archive/2026-09-05/receipts/2026-09-05-an-item.md")"
  # Nothing left to file, and the archived record is untouched.
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-05 --retire 2026-09-05-an-item.md
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

review_ended() { # <project> <shift-id> <layout>
  printf 'shiftId=%s\narchiveRoot=archive\narchiveLayout=%s\n' "$2" "$3" >"$1/.nightshift/.ended"
}

@test "archive files handled snag entries only and writes one pointer" {
  p="$(new_project review-snag-only)"
  review_ended "$p" aaaa1111bbbb2222 date
  printf '# Snag Log\n\n- leak · tests/x.bats · fixed · 2026-09-09\n- still open · looking\n' \
    >"$p/.nightshift/snag-log.md"
  printf '# Parking Lot\n\n- wait for the owner\n' >"$p/.nightshift/parking-lot.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-09
  [ "$status" -eq 0 ]
  dest="$p/.nightshift/archive/2026-09-09/aaaa1111bbbb2222/snag-log.md"
  [ -f "$dest" ]
  grep -qF 'leak · tests/x.bats · fixed · 2026-09-09' "$dest"
  ! grep -qF 'still open' "$dest"
  [ ! -e "$p/.nightshift/archive/2026-09-09/aaaa1111bbbb2222/parking-lot.md" ]
  grep -qF 'Filed: [2026-09-09](archive/2026-09-09/aaaa1111bbbb2222/snag-log.md)' \
    "$p/.nightshift/snag-log.md"
  grep -qF 'still open · looking' "$p/.nightshift/snag-log.md"
  ! grep -qF 'leak ·' "$p/.nightshift/snag-log.md"
  ! grep -qF 'Filed:' "$p/.nightshift/parking-lot.md"
}

@test "filing nothing adds no pointer and creates no empty archive file" {
  p="$(new_project review-noop)"
  review_ended "$p" aaaa1111bbbb2222 date
  printf '# Snag Log\n\n- still open · looking\n' >"$p/.nightshift/snag-log.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-09
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/archive/2026-09-09/aaaa1111bbbb2222/snag-log.md" ]
  ! grep -qF 'Filed:' "$p/.nightshift/snag-log.md"
}

@test "a second archive run does not duplicate the pointer or the filed entry" {
  p="$(new_project review-retry)"
  review_ended "$p" aaaa1111bbbb2222 date
  printf '# Snag Log\n\n- leak · tests/x.bats · fixed · 2026-09-09\n' >"$p/.nightshift/snag-log.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-09
  [ "$status" -eq 0 ]
  dest="$p/.nightshift/archive/2026-09-09/aaaa1111bbbb2222/snag-log.md"
  before="$(cksum <"$dest")"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-09
  [ "$status" -eq 0 ]
  [ "$(cksum <"$dest")" = "$before" ]
  [ "$(grep -c '^Filed:' "$p/.nightshift/snag-log.md")" -eq 1 ]
}

@test "a custom archive.root is the pointer destination" {
  p="$(new_project review-root)"
  jq '.archive.root = "history"' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.next"
  mv "$p/.nightshift/rules.next" "$p/.nightshift/rules.json"
  printf 'shiftId=aaaa1111bbbb2222\narchiveRoot=history\narchiveLayout=date\n' \
    >"$p/.nightshift/.ended"
  printf '# Parking Lot\n\n- ship it · answered · 2026-09-09\n' >"$p/.nightshift/parking-lot.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-09
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/history/2026-09-09/aaaa1111bbbb2222/parking-lot.md" ]
  grep -qF 'Filed: [2026-09-09](history/2026-09-09/aaaa1111bbbb2222/parking-lot.md)' \
    "$p/.nightshift/parking-lot.md"
}

@test "shift layout names the pointer with the shift id" {
  p="$(new_project review-shift)"
  jq '.archive.layout = "shift"' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.next"
  mv "$p/.nightshift/rules.next" "$p/.nightshift/rules.json"
  review_ended "$p" aaaa1111bbbb2222 shift
  printf '# Snag Log\n\n- leak · tests/x.bats · fixed · 2026-09-09\n' >"$p/.nightshift/snag-log.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-09
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/archive/shift-aaaa1111bbbb2222/snag-log.md" ]
  grep -qF 'Filed: [aaaa1111bbbb2222](archive/shift-aaaa1111bbbb2222/snag-log.md)' \
    "$p/.nightshift/snag-log.md"
}

@test "two shifts on one date keep distinct destinations" {
  p="$(new_project review-two)"
  review_ended "$p" aaaa1111bbbb2222 date
  printf '# Snag Log\n\n- first · x · fixed · 2026-09-09\n' >"$p/.nightshift/snag-log.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-09
  [ "$status" -eq 0 ]
  review_ended "$p" cccc3333dddd4444 date
  printf '# Snag Log\n\n- second · y · answered · 2026-09-09\n\nFiled: [2026-09-09](archive/2026-09-09/aaaa1111bbbb2222/snag-log.md)\n' \
    >"$p/.nightshift/snag-log.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-09
  [ "$status" -eq 0 ]
  grep -qF 'first · x · fixed' "$p/.nightshift/archive/2026-09-09/aaaa1111bbbb2222/snag-log.md"
  grep -qF 'second · y · answered' "$p/.nightshift/archive/2026-09-09/cccc3333dddd4444/snag-log.md"
  ! grep -qF 'second' "$p/.nightshift/archive/2026-09-09/aaaa1111bbbb2222/snag-log.md"
  [ "$(grep -c '^Filed:' "$p/.nightshift/snag-log.md")" -eq 2 ]
}

@test "a broken Filed pointer is reported in the snag log" {
  p="$(new_project review-broken)"
  review_ended "$p" aaaa1111bbbb2222 date
  printf '# Snag Log\n\nFiled: [2026-09-09](archive/missing/snag-log.md)\n' \
    >"$p/.nightshift/snag-log.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-09
  [ "$status" -eq 0 ]
  grep -qF 'broken archive pointer · archive/missing/snag-log.md is not a readable file' \
    "$p/.nightshift/snag-log.md"
  run bash "$ARCHIVE_SH" --project "$p" --date 2026-09-09
  [ "$status" -eq 0 ]
  [ "$(grep -c 'broken archive pointer' "$p/.nightshift/snag-log.md")" -eq 1 ]
}
