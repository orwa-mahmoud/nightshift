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

  # Each page names its own workspace; everything else has to match.
  a="$(sed "s|$posix|WS|g" "$posix/m.md")"
  b="$(sed "s|$win|WS|g" "$win/m.md")"
  diff -u <(printf '%s\n' "$a") <(printf '%s\n' "$b")

  # And neither leaks the template it read past.
  ! printf '%s' "$a" | grep -qF '<title>'
  ! printf '%s' "$b" | grep -qF '<title>'
}
