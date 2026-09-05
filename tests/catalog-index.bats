#!/usr/bin/env bats
# Discovery reads what the catalog holds, not every contract in it. The entries are the registry:
# a file added today is offered today, and nothing has to be kept in step by hand.

bats_require_minimum_version 1.5.0

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
INDEX="$PLUGIN/runtime/catalog-index.sh"
INDEX_PS1="$PLUGIN/runtime/windows/catalog-index.ps1"
SHIFTS="$PLUGIN/skills/nightshift/references/shifts"
HUNT="$PLUGIN/skills/hunt/SKILL.md"

@test "every catalog entry is listed with its ending and its purpose" {
  run bash "$INDEX"
  [ "$status" -eq 0 ]
  # One line per entry file, and nothing else.
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" \
    -eq "$(find "$SHIFTS" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" ]
  # Four cells, all filled: a blank ending or purpose would make the offer useless.
  while IFS= read -r line; do
    [ "$(printf '%s' "$line" | awk -F'\t' '{print NF}')" -eq 4 ] \
      || { echo "not four cells: $line"; return 1; }
    printf '%s' "$line" | awk -F'\t' '
      $1 == "" { exit 1 } $2 == "" { exit 1 } $3 == "" { exit 1 } $4 == "" { exit 1 }' \
      || { echo "an empty cell: $line"; return 1; }
    case "$(printf '%s' "$line" | cut -f2)" in
      finite | open-ended) ;;
      *) echo "not an ending: $line"; return 1 ;;
    esac
  done < <(printf '%s\n' "$output")
}

@test "an entry added today is discovered today" {
  extra="$SHIFTS/zz-temporary-discovery-probe.md"
  cat >"$extra" <<'ENTRY'
# Temporary discovery probe — finite — proves a new entry is offered without a registry edit

A throwaway entry used by the catalog-index test. It is created and removed inside the test.
ENTRY
  run bash "$INDEX"
  rm -f "$extra"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'zz-temporary-discovery-probe' \
    || { echo "a new entry was not discovered"; return 1; }
  printf '%s\n' "$output" | grep -qF 'proves a new entry is offered without a registry edit'

  # And it stops being offered the moment the file is gone.
  run bash "$INDEX"
  [ "$status" -eq 0 ]
  if printf '%s\n' "$output" | grep -qF 'zz-temporary-discovery-probe'; then
    echo "a removed entry is still offered"
    return 1
  fi
}

@test "discovery costs a fraction of reading every contract" {
  # The point of the helper: the offer is cheap, and the contracts are read when they are chosen.
  index_bytes="$(bash "$INDEX" | wc -c | tr -d ' ')"
  all_bytes="$(cat "$SHIFTS"/*.md | wc -c | tr -d ' ')"
  [ "$index_bytes" -lt "$((all_bytes / 10))" ] \
    || { echo "the index is not meaningfully smaller: $index_bytes vs $all_bytes"; return 1; }
}

@test "the helper reads, and does nothing else" {
  before="$(find "$SHIFTS" -type f | LC_ALL=C sort | xargs cksum | cksum)"
  run bash "$INDEX"
  [ "$status" -eq 0 ]
  [ "$(find "$SHIFTS" -type f | LC_ALL=C sort | xargs cksum | cksum)" = "$before" ]
  # It ranks nothing: entries come back in the order the catalog holds them.
  [ "$(printf '%s\n' "$output" | cut -f1)" = "$(printf '%s\n' "$output" | cut -f1 | LC_ALL=C sort)" ]
}

@test "a missing catalog is named rather than guessed at" {
  run bash "$INDEX" --plugin-root "$BATS_TEST_TMPDIR/nowhere"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'no catalog at'
}

@test "Hunt discovers before it reads, and still reads what it composes" {
  grep -qF 'runtime/catalog-index.sh' "$HUNT"
  grep -qF 'Then read in full only the entries you are actually going to use' "$HUNT"
  # The old instruction to read all thirty is gone.
  if grep -qF 'read every file in it' "$HUNT"; then
    echo "Hunt still reads every contract up front"
    return 1
  fi
  # Falling back to reading the directory is still there for a host without the helper.
  grep -qF 'list the directory and read the entries yourself' "$HUNT"
}

@test "both hosts list the catalog identically" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  run bash -c 'diff <(bash "$1") <(pwsh -NoProfile -File "$2")' _ "$INDEX" "$INDEX_PS1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}
