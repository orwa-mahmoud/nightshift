load helpers

RECEIPT="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/morning-receipt.sh"

# A project whose punch list names two gate commands and whose boxes are all ticked.
gated_project() { # <name>
  local p
  p="$(new_project "$1")"
  cat >"$p/.nightshift/punch-list.md" <<'MD'
# Punch list

## Gates

- Item gate: `npm test` and `npm run lint`

## Items

- [x] Tidy the changelog
MD
  printf '%s' "$p"
}

# write_shift_policy <project> <verificationLevel>
write_shift_policy() {
  printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z","source":"composition","deadlineEpoch":null,"verificationLevel":"%s","toolingPolicy":"existing-tools"}\n' \
    "$2" >"$1/.nightshift/shift-policy.json"
}

@test "a shift with no policy names the punch-list gates as its gate" {
  p="$(gated_project receipt-no-policy)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *'- Gates: npm run lint, npm test (punch list)'* ]]
}

@test "a shift with no policy reports why nothing was verified" {
  p="$(gated_project receipt-no-policy-verified)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *'- Policy record: absent — the shift wrote no policy'* ]]
  [[ "$output" == *'- Verified: none — no shift policy was written'* ]]
}

@test "a shift with no policy credits the owner with disabling nothing" {
  p="$(gated_project receipt-no-policy-disabled)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *'- Disabled by owner: none'* ]]
}

@test "a policy that chose verification none names the gates it disabled" {
  p="$(gated_project receipt-level-none)"
  write_shift_policy "$p" none
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *'- Policy record: accepted'* ]]
  [[ "$output" == *'- Verified: none — verification level none (owner)'* ]]
  [[ "$output" == *'- Disabled by owner: npm run lint, npm test'* ]]
  [[ "$output" != *'- Gates:'* ]]
}

@test "a policy that kept verification on disables nothing" {
  p="$(gated_project receipt-level-final)"
  write_shift_policy "$p" final
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *'- Verified: none — verification level final (owner)'* ]]
  [[ "$output" == *'- Disabled by owner: none'* ]]
}

@test "a shift with no policy and no gates states the same reason without a gate line" {
  p="$(new_project receipt-no-gates)"
  printf '# Punch list\n\n## Items\n\n- [x] Tidy the changelog\n' >"$p/.nightshift/punch-list.md"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" != *'- Gates:'* ]]
  [[ "$output" == *'- Verified: none — no shift policy was written'* ]]
  [[ "$output" == *'- Disabled by owner: none'* ]]
}

# The morning page is the one artefact an owner reads without being asked, so the two renderers
# have to agree on it byte for byte. They did not: the Windows reader read the opportunity map's
# commented-out example as a live `building` entry and printed the template's own placeholders,
# and it named the workspace as the work target where the POSIX renderer, unable to resolve one,
# said nothing.
@test "both renderers write the same morning page" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
  local posix win a b
  posix="$(gated_project receipt-parity-posix)"
  win="$(gated_project receipt-parity-win)"
  for p in "$posix" "$win"; do
    # The map as Setup scaffolds it: every entry shape lives inside one HTML comment, and the
    # example the comment carries is `Status: building`.
    cp "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/templates/opportunity-map.md" \
      "$p/.nightshift/opportunity-map.md"
    write_shift_policy "$p" none
  done

  run bash "$RECEIPT" --project "$posix" --out "$posix/m.md"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  run pwsh -NoProfile -NonInteractive -File \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/morning-receipt.ps1" \
    -Project "$win" -Out "$win/m.md"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }

  # Each page names its own workspace and its own repository's commits; everything else has to
  # match.
  a="$(sed -e "s|$posix|WS|g" -e "s|$(git -C "$posix" log --format=%h -n1)|HASH|g" "$posix/m.md")"
  b="$(sed -e "s|$win|WS|g" -e "s|$(git -C "$win" log --format=%h -n1)|HASH|g" "$win/m.md")"
  diff -u <(printf '%s\n' "$a") <(printf '%s\n' "$b")

  # And neither leaks the template it read past.
  ! printf '%s' "$a" | grep -qF '<title>'
  ! printf '%s' "$b" | grep -qF '<title>'
}

FIX="$BATS_TEST_DIRNAME/fixtures/morning-receipt"
RECEIPTS_LINE='Receipts:
- [index](./README.md)
- Policy record: '
ITEM_LINE='- 2. Make the packed Node-only build reproducible. — ticked'

policy_fixture_project() { # <name> <policy-file-or-absent>
  local p
  p="$(new_project "$1")"
  cp "$FIX/punch-list.md" "$p/.nightshift/punch-list.md"
  case "$2" in
    absent) ;;
    *) cp "$FIX/$2" "$p/.nightshift/shift-policy.json" ;;
  esac
  printf '%s' "$p"
}

@test "an accepted policy is named on the page and every item has its line" {
  p="$(policy_fixture_project receipt-policy-accepted shift-policy-valid.json)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *"$RECEIPTS_LINE"* ]]
  [[ "$output" == *"$ITEM_LINE"* ]]
  [[ "$output" == *'- Policy record: accepted'* ]]
  [[ "$output" == *'- Shift: 9f2c40ab77e51d63'* ]]
  [[ "$output" == *'- Started: 2026-09-02T02:30:00Z'* ]]
  [[ "$output" != *'no shift policy was written'* ]]
}

@test "an absent policy is named as absent and still lists every item" {
  p="$(policy_fixture_project receipt-policy-absent absent)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *"$RECEIPTS_LINE"* ]]
  [[ "$output" == *"$ITEM_LINE"* ]]
  [[ "$output" == *'- Policy record: absent — the shift wrote no policy'* ]]
  [[ "$output" == *'- Verified: none — no shift policy was written'* ]]
  [[ "$output" != *'- Shift: 9f2c40ab77e51d63'* ]]
}

@test "unreadable and schema-failing policies are named as malformed and still render the page" {
  local kind
  for kind in shift-policy-malformed.json shift-policy-schema-fail.json; do
    p="$(policy_fixture_project "receipt-policy-$kind" "$kind")"
    run bash "$RECEIPT" --project "$p" --view owner
    [ "$status" -eq 0 ]
    [[ "$output" == *"$RECEIPTS_LINE"* ]]
    [[ "$output" == *"$ITEM_LINE"* ]]
    [[ "$output" == *'- Policy record: malformed — the policy file is present but unreadable or fails the schema'* ]]
    [[ "$output" == *'- Verified: none — the policy file is present but unreadable or fails the schema'* ]]
    [[ "$output" != *'no shift policy was written'* ]]
    [[ "$output" != *'- Shift: 9f2c40ab77e51d63'* ]]
    [[ "$output" == *'- Items: 1 ticked, 1 open'* ]]
  done
}

# verdict_project <name> — a shift with usage marks and pauses, a history of commits, a wrapped
# parking-lot entry, snags, and a shift log that records interruptions and a handover.
VERDICT_NOW=1790000000
verdict_project() {
  local p ns i
  p="$(new_project "$1")"
  ns="$p/.nightshift"
  rm -f "$ns/.shift-armed"
  mkdir -p "$ns/receipts" "$ns/usage"
  cat >"$ns/punch-list.md" <<'MD'
# Punch list

## Gates

- Item gate: `npm test`

## Items

- [x] **1. Add the parser.** <!-- id: a1b2 -->
- [x] **2. Wire the parser into the CLI.** <!-- id: c3d4 -->
- [ ] **3. Document the flags.** <!-- id: e5f6 -->
MD
  printf '# 1. Add the parser.\n' >"$ns/receipts/a1b2-add-the-parser.md"
  cat >"$ns/parking-lot.md" <<'MD'
# Parking Lot

---

- Ship the parser behind a flag because the CLI cannot complete anywhere but a
  POSIX shell today, and Windows users would see a broken command.
  - Default: flag off until the Windows path lands
  - Rollback: delete the flag
- [notice] 2026-09-24 03:00 — the shift session died and the watchman revived it.
- An answered question · answered 2026-09-24

**The schema promises a replay check that nothing implements.** Start never refuses a
reused id. Default chosen: not built in this shift.
MD
  cat >"$ns/snag-log.md" <<'MD'
# Snag Log

---

- Old finding · evidence · rejected-because noisy · 2020-01-01
- Parser drops a trailing comma · tests/parse.bats · fixed in abc123 · 2026-09-24
- CLI help is stale for --flag · docs/cli.md · accepted-tradeoff the flag is renamed in item 3 · 2026-09-24
- Windows path untested · no pwsh on the runner
  still open after the shift · 2026-09-24
MD
  cat >"$ns/shift-log.md" <<'MD'
# Shift Log
2026-09-21 10:00:00 · watchman: site dead quiet mid-shift — resume attempt 1 (resume)
2026-09-21T14:12:20Z shift started — 3 items
2026-09-21 18:01:00 · watchman: site dead quiet mid-shift — resume attempt 1 (resume)
2026-09-21T18:05:00Z · item 1 done — install the parser
2026-09-21 18:30:00 · stall warning — session active, no durable checkpoint since the last 3 stop attempts, 1/3 done; keeping shift open
2026-09-21T19:00:00Z · handover — item 3 half done; next: write the flags table
2026-09-21 19:10:00 · stopped by owner
MD
  printf '%s\tarm\t\n' "$VERDICT_NOW" >"$ns/usage/marks.tsv"
  printf '%s\t1. Add the parser.\tinput=100,output=50\ttick\n' "$((VERDICT_NOW + 600))" >>"$ns/usage/marks.tsv"
  printf '%s\t2. Wire the parser into the CLI.\tinput=300,output=90\ttick\n' "$((VERDICT_NOW + 1800))" >>"$ns/usage/marks.tsv"
  printf '%s\t3. Document the flags.\tinput=400,output=120\tpause\n' "$((VERDICT_NOW + 3000))" >>"$ns/usage/marks.tsv"
  printf '%s\towner pressed Esc\n' "$((VERDICT_NOW + 700))" >"$ns/usage/pauses.tsv"
  printf '%s\tthe session ended and the shift was revived\n' "$((VERDICT_NOW + 1000))" >>"$ns/usage/pauses.tsv"
  printf '%s\towner pressed Esc\n' "$((VERDICT_NOW + 2000))" >>"$ns/usage/pauses.tsv"
  printf 'claude-t1\tclaude\tclaude-opus-5-5\ttranscript-incremental\t10\tinput=0,output=0\tinput=400,cache_read=12000,output=120\t\n' \
    >"$ns/usage/segments.tsv"
  printf 'shiftId=9f2c40ab77e51d63\n' >"$ns/.ended"
  TZ=UTC touch -t 202609211510.05 "$ns/.ended"
  printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-21T14:12:20Z","source":"composition","deadlineEpoch":null,"verificationLevel":"final","toolingPolicy":"existing-tools"}\n' \
    >"$ns/shift-policy.json"
  # A history that predates the shift, then two commits in item 1's span, one in item 2's, and a
  # larger one after the last mark.
  rm -rf "$p/.git"
  git -C "$p" init -q
  git -C "$p" config user.email dev@example.com
  git -C "$p" config user.name tester
  git -C "$p" config commit.gpgsign false
  _verdict_commit "$p" "$((VERDICT_NOW - 100000))" base.txt 1 'chore: base'
  _verdict_commit "$p" "$((VERDICT_NOW + 100))" parser.js 40 'feat: add the parser'
  _verdict_commit "$p" "$((VERDICT_NOW + 500))" parser.test.js 30 'test: cover the parser'
  _verdict_commit "$p" "$((VERDICT_NOW + 1200))" cli.js 5 'feat: wire the parser'
  _verdict_commit "$p" "$((VERDICT_NOW + 3500))" notes.md 200 'docs: late notes'
  printf '%s' "$p"
}

_verdict_commit() { # <project> <epoch> <file> <lines> <subject>
  local i
  for i in $(seq 1 "$4"); do printf 'line %s\n' "$i"; done >>"$1/$3"
  git -C "$1" add "$3"
  GIT_COMMITTER_DATE="@$2 +0000" GIT_AUTHOR_DATE="@$2 +0000" git -C "$1" commit -qm "$5"
}

@test "the verdict names both ends of the shift in UTC with the zone" {
  p="$(verdict_project verdict-times)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *$'## How it ended\n'* ]]
  # The arming mark, not the policy's earlier createdAt.
  [[ "$output" == *'- Started: 2026-09-21T14:13:20Z'* ]]
  [[ "$output" == *'- Ended: 2026-09-21T15:10:05Z'* ]]
}

@test "time and tokens split the pauses by reason, and the reasons sum to the total" {
  p="$(verdict_project verdict-usage)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *'- Span: 2026-09-21T14:13:20Z → 2026-09-21T15:10:05Z'* ]]
  # Esc gaps 1100s and 1000s, the revival 800s: 2900s paused inside a 3405s wall.
  [[ "$output" == *$'- Working: 8m 25s\n- Paused: 48m 20s\n  - owner pressed Esc: 35m 0s\n  - the session ended and the shift was revived: 13m 20s\n- Wall: 56m 45s'* ]]
  [[ "$output" == *'| input | 400 |'* ]]
  [[ "$output" == *'| cache write | unavailable |'* ]]
  [[ "$output" == *'| cache read | 12.0k |'* ]]
  [[ "$output" == *'| reasoning | unavailable |'* ]]
  [[ "$output" == *'claude claude-opus-5-5 · 1 segment. Cache reads and cache writes are separate from the input figure; reasoning is inside output.'* ]]
}

@test "a measurement the owner turned off reads off, not unavailable" {
  p="$(verdict_project verdict-off)"
  jq '.receipts.usage = "off" | .receipts.duration = "off"' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *$'## Time and tokens\n\n- Time: off\n- Tokens: off\n'* ]]
  [[ "$output" != *'| Tokens | Amount |'* ]]
}

@test "every item has one line, linked only to a receipt that exists" {
  p="$(verdict_project verdict-items)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *$'## Items\n\n- [1. Add the parser.](./a1b2-add-the-parser.md) — ticked\n- 2. Wire the parser into the CLI. — ticked\n- 3. Document the flags. — open\n'* ]]
  local link
  for link in $(printf '%s\n' "$output" | grep -o '](\./[^)]*\.md)' | sed 's/^](\.\///; s/)$//' | grep -v '^README.md$'); do
    [ -f "$p/.nightshift/receipts/$link" ] || { echo "dangling link: $link"; return 1; }
  done
}

@test "review first ranks changes by size and names the whole range" {
  p="$(verdict_project verdict-review)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  first="$(git -C "$p" log --format=%h -n1 HEAD~3)"
  last="$(git -C "$p" log --format=%h -n1)"
  late="$last"
  [[ "$output" == *"## Review first

- \`$late\` docs: late notes — 1 file, 200 lines (+200/-0), 1 commit
- [1. Add the parser.](./a1b2-add-the-parser.md) — 2 files, 70 lines (+70/-0), 2 commits
- 2. Wire the parser into the CLI. — 1 file, 5 lines (+5/-0), 1 commit
- Whole range: \`git log --stat $first^..$last\`"* ]]
}

@test "review first does not apply to an artifact shift" {
  p="$(verdict_project verdict-artifact)"
  printf 'artifact\n' >"$p/.nightshift/work-mode"
  run bash "$RECEIPT" --project "$p" --view artifact
  [ "$status" -eq 0 ]
  [[ "$output" == *$'## Review first\n\n- Does not apply: an artifact shift is reviewed through its receipts.\n'* ]]
  [[ "$output" != *'git log'* ]]
}

@test "interruptions come from the shift log, since the shift started" {
  p="$(verdict_project verdict-interruptions)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *'## Interruptions

- 2026-09-21 18:01:00 · watchman: site dead quiet mid-shift — resume attempt 1 (resume)
- 2026-09-21 18:30:00 · stall warning — session active, no durable checkpoint since the last 3 stop attempts, 1/3 done; keeping shift open
- 2026-09-21 19:10:00 · stopped by owner
'* ]]
  [[ "$output" != *'2026-09-21 10:00:00'* ]]
  [[ "$output" != *'install the parser'* ]]
}

@test "parked decisions render in full, with the default and the rollback" {
  p="$(verdict_project verdict-parked)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *'## Decisions for you

- Ship the parser behind a flag because the CLI cannot complete anywhere but a POSIX shell today, and Windows users would see a broken command.
  - Default: flag off until the Windows path lands
  - Rollback: delete the flag
- **The schema promises a replay check that nothing implements.** Start never refuses a reused id. Default chosen: not built in this shift.
'* ]]
  [[ "$output" != *'[notice]'* ]]
  [[ "$output" != *'An answered question'* ]]
}

@test "found but not fixed lists this shift's unfixed snags with their reason" {
  p="$(verdict_project verdict-snags)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *'## Found but not fixed

- CLI help is stale for --flag — accepted-tradeoff the flag is renamed in item 3
- Windows path untested — open
'* ]]
  [[ "$output" != *'Old finding'* ]]
  [[ "$output" != *'trailing comma'* ]]
}

@test "next step carries the open items and the handover line" {
  p="$(verdict_project verdict-next)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [[ "$output" == *'## Next step

- 3. Document the flags.
- Handover: 2026-09-21T19:00:00Z · handover — item 3 half done; next: write the flags table'* ]]
}

@test "the owner view orders every verdict section" {
  p="$(verdict_project verdict-order)"
  run bash "$RECEIPT" --project "$p" --view owner
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep '^## ' | tr '\n' '|')" = \
    '## How it ended|## Time and tokens|## Items|## Review first|## Interruptions|## Decisions for you|## Found but not fixed|## Next step|' ]
}

@test "both renderers write the same verdict in every view" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
  local view a b
  p="$(verdict_project verdict-parity)"
  for view in owner reviewer release artifact; do
    a="$(bash "$RECEIPT" --project "$p" --view "$view")"
    b="$(pwsh -NoProfile -NonInteractive -File \
      "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/morning-receipt.ps1" \
      -Project "$p" -View "$view")"
    diff -u <(printf '%s\n' "$a") <(printf '%s\n' "$b")
  done
}

# switch_project <name> <jq filter> — a shift with one ticked and one open item, a policy that names
# it, and the owner's receipts and handoff switches set by the filter.
switch_project() {
  local p
  p="$(new_project "$1")"
  printf '## Items\n- [x] **1. first.**\n- [ ] **2. done.**\n' >"$p/.nightshift/punch-list.md"
  write_shift_policy "$p" final
  jq "$2" "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  printf '%s' "$p"
}

# work_through <project> — the stop that finds item 1 ticked and holds for item 2, then the stop
# that finds every box ticked and clocks the shift out.
work_through() {
  run gate "$1"
  is_block "$output"
  printf '## Items\n- [x] **1. first.**\n- [x] **2. done.**\n' >"$1/.nightshift/punch-list.md"
  run gate "$1"
  is_release
}

@test "receipts off: the morning page is still written, with no item receipt or index beside it" {
  p="$(switch_project switch-receipts-off '.receipts.enabled = false')"
  work_through "$p"
  page="morning-$(date '+%Y-%m-%d')-9f2c40ab77e51d63.md"
  [ "$(ls "$p/.nightshift/receipts")" = "$page" ]
  grep -qxF -- '- 1. first. — ticked' "$p/.nightshift/receipts/$page"
  # Usage accounting belongs to the receipts, so the page has no time and tokens to report.
  [ ! -e "$p/.nightshift/usage/marks.tsv" ]
  ! grep -q '^## Time and tokens' "$p/.nightshift/receipts/$page"
  # With no item spans to charge them to, each commit stands on its own line.
  grep -qE '^- `[0-9a-f]+` init — ' "$p/.nightshift/receipts/$page"
}

@test "handoff off: the item receipts and their index stand, and no page is written" {
  p="$(switch_project switch-handoff-off '.handoff.enabled = false')"
  work_through "$p"
  r="$p/.nightshift/receipts"
  [ -f "$r/1-first.md" ]
  [ -f "$r/2-done.md" ]
  grep -qF '| 2. done. | ticked |' "$r/README.md"
  ! grep -q '^Shift summary:' "$r/README.md"
  [ -z "$(find "$r" -name 'morning-*')" ]
  grep -qF 'morning receipt disabled by the owner (handoff.enabled)' "$p/.nightshift/shift-log.md"
}

@test "both off: no page, no item receipt and no index, and every other record stands" {
  p="$(switch_project switch-both-off '.receipts.enabled = false | .handoff.enabled = false')"
  work_through "$p"
  [ -z "$(ls -A "$p/.nightshift/receipts" 2>/dev/null)" ]
  grep -qF 'morning receipt disabled by the owner (handoff.enabled)' "$p/.nightshift/shift-log.md"
  [ -f "$p/.nightshift/.ended" ]
  [ -f "$p/.nightshift/archive/$(date '+%Y-%m-%d')/shift-policy-9f2c40ab77e51d63.json" ]
}

@test "the reviewer and release views carry only their own sections" {
  p="$(verdict_project verdict-views)"
  run bash "$RECEIPT" --project "$p" --view reviewer
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep '^## ' | tr '\n' '|')" = '## Review first|' ]
  run bash "$RECEIPT" --project "$p" --view release
  [ "$status" -eq 0 ]
  # No ledger, so no comparison: the release reader sees how the shift ended.
  [ "$(printf '%s\n' "$output" | grep '^## ' | tr '\n' '|')" = '## How it ended|' ]
}

@test "an owner section list can pick the verdict sections" {
  p="$(verdict_project verdict-sections)"
  jq '.handoff.sections = ["next", "usage"]' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run bash "$RECEIPT" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep '^## ' | tr '\n' '|')" = '## Next step|## Time and tokens|' ]
}
