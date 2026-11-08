#!/usr/bin/env bats
# Discovery reads what the catalog holds, not every contract in it. The entries are the registry:
# a file added today is offered today, and nothing has to be kept in step by hand.

bats_require_minimum_version 1.5.0

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
INDEX="$PLUGIN/runtime/catalog-index.sh"
INDEX_PS1="$PLUGIN/runtime/windows/catalog-index.ps1"
SHIFTS="$PLUGIN/skills/nightshift/references/compose/shifts"
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
  grep -qE 'ns"? catalog-index' "$HUNT"
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

# --- one model for every catalog -------------------------------------------------------------

REGISTRY="$PLUGIN/lib/catalogs.tsv"
NEW="$PLUGIN/runtime/catalog-new.sh"
NEW_PS1="$PLUGIN/runtime/windows/catalog-new.ps1"

catalog_names() { awk -F '\t' '!/^#/ && NF >= 9 { print $1 }' "$REGISTRY"; }

owner_project() { # <name> — a v2 workspace whose user folder is empty
  local p
  p="$(new_project "$1")"
  printf '2\n' >"$p/.nightshift/state-version"
  mkdir -p "$BATS_TEST_TMPDIR/xdg-$1"
  printf '%s' "$p"
}

@test "the registry names every catalog once, and each row is complete" {
  [ "$(catalog_names | tr '\n' ' ')" = "shifts evidence gates edge-cases " ]
  while IFS=$'\t' read -r name shipped template order rule _; do
    [ -d "$PLUGIN/$shipped" ] || { echo "$name: no shipped folder $shipped"; return 1; }
    [ -f "$PLUGIN/$template" ] || { echo "$name: no template $template"; return 1; }
    case "$order" in alpha | match) ;; *) echo "$name: order $order"; return 1 ;; esac
    case "$rule" in - | shift | match | fence:*) ;; *) echo "$name: rule $rule"; return 1 ;; esac
  done < <(awk -F '\t' '!/^#/ && NF >= 9' "$REGISTRY")
  # Neither runtime's helper names a catalog: the registry is the only place one is named.
  for helper in "$PLUGIN/lib/catalog-sources.sh" "$PLUGIN/lib/catalog-sources.ps1"; do
    for name in $(catalog_names) kinds stacks packs; do
      if grep -qiE "(^|[^a-z-])$name([^a-z-]|$)" "$helper"; then
        echo "$helper names $name"
        return 1
      fi
    done
  done
}

@test "every shipped entry of every catalog passes its template, on both runtimes" {
  for name in $(catalog_names); do
    while IFS=$'\t' read -r key _; do
      file="$(bash "$INDEX" --catalog "$name" --path "$key")"
      run bash "$INDEX" --catalog "$name" --check-draft "$file"
      [ "$status" -eq 0 ] || { echo "$name/$key: $output"; return 1; }
    done < <(bash "$INDEX" --catalog "$name")
  done
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  for name in $(catalog_names); do
    run bash -c 'diff <(bash "$1" --catalog "$3") <(pwsh -NoProfile -File "$2" --catalog "$3")' _ "$INDEX" "$INDEX_PS1" "$name"
    [ "$status" -eq 0 ] || { echo "$name: $output"; return 1; }
  done
}

@test "the template is the schema: an owner template's headings are what a draft needs" {
  p="$(owner_project owner-template)"
  printf '# Mine — my own template\n\n## Purpose\n\n## Steps\n\n- one\n' >"$p/my-template.md"
  jq '.catalogs."edge-cases".template = "my-template.md"' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run bash "$INDEX" --catalog edge-cases --project "$p" --template
  [ "$output" = "$p/my-template.md" ]
  printf '# Draft — fits\n\n## Purpose\n\nWhy.\n' >"$p/draft.md"
  run bash "$INDEX" --catalog edge-cases --project "$p" --check-draft "$p/draft.md"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'missing section Steps'
  printf '\n## Steps\n\n- do it\n' >>"$p/draft.md"
  run bash "$INDEX" --catalog edge-cases --project "$p" --check-draft "$p/draft.md"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "an owner shift is listed, replaces nothing by accident, and its file is found by key" {
  p="$(owner_project owner-shift)"
  mkdir -p "$p/.nightshift/catalogs/shifts"
  cat >"$p/.nightshift/catalogs/shifts/nightly-docs.md" <<'ENTRY'
# Nightly docs — finite — keep the docs in step with the code

## When to use

Use when the docs drift.

## Item

```text
- [ ] **Nightly docs — bring the docs back in step.**
  - Ends when every page matches.
  - Verify: run the docs build.
```
ENTRY
  printf '# Broken — finite — no item\n\n## When to use\n\nNo item block.\n' \
    >"$p/.nightshift/catalogs/shifts/broken.md"
  run env XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-owner-shift" bash "$INDEX" --catalog shifts --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "$(printf 'nightly-docs\tfinite\tNightly docs\tkeep the docs in step with the code')"
  printf '%s\n' "$output" | grep -qF 'the Item section has no pasteable box'
  if printf '%s\n' "$output" | grep -q "^broken$(printf '\t')"; then
    return 1
  fi
  run env XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-owner-shift" bash "$INDEX" --catalog shifts --project "$p" --path nightly-docs
  [ "$output" = "$p/.nightshift/catalogs/shifts/nightly-docs.md" ]
  run bash "$INDEX" --catalog shifts --path no-such-shift
  [ "$status" -eq 2 ]
}

@test "the new folder and key win over the ones an earlier version read, which still work" {
  p="$(owner_project owner-legacy)"
  folder="$BATS_TEST_TMPDIR/legacy-packs"
  mkdir -p "$folder" "$p/.nightshift/edge-cases/packs" "$p/.nightshift/catalogs/edge-cases"
  pack() { # <file> <title>
    printf '# %s — test pack\n\n## When it applies\n\nAlways.\n\n## Cases\n\n- **One** — a case.\n\n## Example lines\n\n- WHEN x THEN y\n' "$2" >"$1"
  }
  pack "$folder/legacy-folder.md" "Legacy folder"
  pack "$p/.nightshift/edge-cases/packs/input.md" "Legacy project input"
  pack "$p/.nightshift/catalogs/edge-cases/input.md" "New project input"
  jq --arg f "$folder" '.edgeCases.packsPaths = [$f]' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run env XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-owner-legacy" bash "$INDEX" --catalog edge-cases --project "$p"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' '$1 == "input" { print $2 }')" = "New project input" ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' '$1 == "legacy-folder" { print $4 }')" = "$folder" ]
  # The new key, once set, is what is read.
  other="$BATS_TEST_TMPDIR/new-packs"
  mkdir -p "$other"
  pack "$other/new-folder.md" "New folder"
  jq --arg f "$other" '.catalogs."edge-cases".paths = [$f]' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run env XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-owner-legacy" bash "$INDEX" --catalog edge-cases --project "$p"
  printf '%s\n' "$output" | awk -F'\t' '$1 == "new-folder" { found = 1 } END { exit found ? 0 : 1 }'
  if printf '%s\n' "$output" | awk -F'\t' '$1 == "legacy-folder" { found = 1 } END { exit found ? 0 : 1 }'; then
    return 1
  fi
  # Doctor names where the legacy setting and folder live now.
  run bash "$PLUGIN/runtime/doctor.sh" --project "$p"
  printf '%s\n' "$output" | grep -qF 'edgeCases.packsPaths is read as catalogs.edge-cases.paths'
  printf '%s\n' "$output" | grep -qF "is read as the edge-cases catalog's project folder"
}

@test "catalog-new starts an entry from the template in force, and never overwrites" {
  p="$(owner_project owner-new)"
  run env XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-owner-new" bash "$NEW" --catalog gates --key elixir --project "$p"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ "$output" = "$p/.nightshift/catalogs/gates/elixir.md" ]
  cmp "$output" "$PLUGIN/skills/nightshift/references/templates/gates-stack.md"
  run env XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-owner-new" bash "$NEW" --catalog gates --key elixir --project "$p"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'already exists'
  run env XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-owner-new" bash "$NEW" --catalog shifts --key nightly --user
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/xdg-owner-new/nightshift/catalogs/shifts/nightly.md" ]
  run bash "$NEW" --catalog gates --key 'Not A Key' --project "$p"
  [ "$status" -eq 2 ]
  run bash "$NEW" --catalog widgets --key x --project "$p"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'one of: shifts evidence gates edge-cases'
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  run env APPDATA="$BATS_TEST_TMPDIR/appdata" pwsh -NoProfile -File "$NEW_PS1" -Catalog evidence -Key screens -Project "$p"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ -f "$p/.nightshift/catalogs/evidence/screens.md" ]
  run env APPDATA="$BATS_TEST_TMPDIR/appdata" pwsh -NoProfile -File "$NEW_PS1" -Catalog evidence -Key screens -Project "$p"
  [ "$status" -eq 2 ]
}
