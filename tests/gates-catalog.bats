#!/usr/bin/env bats
# The gates catalog is one file per stack. This file globs the directory, so a new stack is
# covered the moment it lands.

bats_require_minimum_version 1.5.0

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
INDEX="$PLUGIN/runtime/catalog-index.sh"
INDEX_PS1="$PLUGIN/runtime/windows/catalog-index.ps1"
GATES="$PLUGIN/skills/nightshift/references/compose/gates"
TEMPLATE="$PLUGIN/skills/nightshift/references/templates/gates-stack.md"
CAT="$PLUGIN/skills/nightshift/references/compose/gates-catalog.md"
SOURCES="$PLUGIN/lib/catalog-sources.sh"
SOURCES_PS1="$PLUGIN/lib/catalog-sources.ps1"
PURGE="$PLUGIN/runtime/purge-workspace.sh"
RESET="$PLUGIN/runtime/reset-shift.sh"
PURGE_PS1="$PLUGIN/runtime/windows/purge-workspace.ps1"
RESET_PS1="$PLUGIN/runtime/windows/reset-shift.ps1"
PATH_SH="$PLUGIN/runtime/path.sh"
SETUP="$PLUGIN/skills/setup/SKILL.md"
QUALITY="$PLUGIN/skills/quality/SKILL.md"

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/no-owner"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/no-owner"
  export APPDATA="$XDG_CONFIG_HOME"
}

write_stack() { # <path> <title>
  mkdir -p "${1%/*}"
  cat >"$1" <<EOF
# $2 — owner stack for this test

## Detect

\`marker.toml\`, per top-level package directory.

Match: stack

## Item gate

\`owner-check\`

## Site inspection

—

## Notes

The command needs nothing this test does not already have.
EOF
}

@test "plugin detection sits after language stacks and before the Makefile fallback" {
  run bash "$INDEX" --catalog gates
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | awk -F '\t' '
    $1 == "typescript" { ts = NR }
    $1 == "plugin" { plugin = NR }
    $1 == "makefile" { make = NR }
    END {
      if (!(ts && plugin && make)) { print "missing row"; exit 1 }
      if (!(ts < plugin && plugin < make)) { print "order"; exit 1 }
    }
  '
}

@test "the index lists every shipped stack in match order" {
  run bash "$INDEX" --catalog gates
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk -F '\t' '{ print $1 }' | paste -sd ' ' -)" \
    = "go helm python rust typescript plugin makefile nothing" ]
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  run bash -c 'diff <(bash "$1" --catalog gates) <(pwsh -NoProfile -File "$2" --catalog gates)' _ "$INDEX" "$INDEX_PS1"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "an owner stack is listed with its source and replaces the shipped stack of the same key" {
  p="$(new_project owner-stacks)"
  printf '2\n' >"$p/.nightshift/state-version"
  folder_a="$BATS_TEST_TMPDIR/folder-a"
  mkdir -p "$folder_a"
  write_stack "$p/.nightshift/gates/stacks/typescript.md" "Project TypeScript"
  write_stack "$XDG_CONFIG_HOME/nightshift/gates/stacks/typescript.md" "User TypeScript"
  write_stack "$folder_a/typescript.md" "Folder TypeScript"
  write_stack "$folder_a/owner-only.md" "Folder only"
  jq --arg a "$folder_a" '.gates.stacksPaths = [$a]' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.next"
  mv "$p/.nightshift/rules.next" "$p/.nightshift/rules.json"

  run bash "$INDEX" --catalog gates --project "$p"
  [ "$status" -eq 0 ]
  row="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "typescript"')"
  [ "$(printf '%s' "$row" | cut -f2)" = "Project TypeScript" ]
  [ "$(printf '%s' "$row" | cut -f4)" = project ]
  [ "$(printf '%s' "$row" | cut -f5)" = "$folder_a, user, plugin" ] \
    || { printf 'typescript line: %s\n' "$row"; return 1; }
  [ "$(printf '%s\n' "$output" | awk -F '\t' '$1 == "owner-only" { print $4 }')" = "$folder_a" ]

  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  run bash -c 'diff <(bash "$1" --catalog gates --project "$3") <(pwsh -NoProfile -File "$2" --catalog gates --project "$3")' \
    _ "$INDEX" "$INDEX_PS1" "$p"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "an owner stack with an invalid Match line and a missing configured folder are reported and skipped" {
  p="$(new_project owner-stacks-bad)"
  printf '2\n' >"$p/.nightshift/state-version"
  missing="$BATS_TEST_TMPDIR/no-such-stacks"
  write_stack "$p/.nightshift/gates/stacks/typescript.md" "Project TypeScript"
  cat >"$p/.nightshift/gates/stacks/broken.md" <<'EOF'
# Broken — an unknown match value

## Detect

`marker.toml`

Match: sometimes

## Item gate

`owner-check`

## Site inspection

—
EOF
  printf '# Not a key\n' >"$p/.nightshift/gates/stacks/Not A Key.md"
  jq --arg m "$missing" '.gates.stacksPaths = [$m]' \
    "$p/.nightshift/rules.json" >"$p/.nightshift/rules.next"
  mv "$p/.nightshift/rules.next" "$p/.nightshift/rules.json"

  run bash "$INDEX" --catalog gates --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'invalid match'
  printf '%s\n' "$output" | grep -qF 'broken.md'
  printf '%s\n' "$output" | grep -qF 'malformed file name'
  printf '%s\n' "$output" | grep -qF "configured folder missing: $missing"
  if printf '%s\n' "$output" | awk -F '\t' '$1 == "broken" { found = 1 } END { exit found ? 0 : 1 }'; then
    echo "a malformed stack was listed"
    return 1
  fi

  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  run pwsh -NoProfile -File "$INDEX_PS1" --catalog gates --project "$p"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -qF 'invalid match'
  printf '%s\n' "$output" | grep -qF "configured folder missing: $missing"
}

@test "project gate stacks resolve, Purge removes them, and Reset keeps them and the user folder" {
  p="$(new_project owner-stacks-path)"
  printf '2\n' >"$p/.nightshift/state-version"
  run bash "$PATH_SH" --project "$p" gates-stacks
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd -P "$p" && pwd -P)/.nightshift/gates/stacks" ] \
    || { printf 'path: [%s]\n' "$output"; return 1; }
  grep -qF '| `catalogs/<catalog>/` |' "$PLUGIN/skills/nightshift/references/shift/state-map.md"
  grep -qF 'catalogs.<catalog>.paths' "$ROOT/docs/knobs.md"
  grep -qF 'gates.stacksPaths' "$ROOT/docs/knobs.md"

  write_stack "$p/.nightshift/gates/stacks/proj-only.md" "Project only"
  write_stack "$XDG_CONFIG_HOME/nightshift/gates/stacks/user-only.md" "User only"
  ns="$(cd -P "$p/.nightshift" && pwd -P)"
  run bash "$RESET" --project "$p"
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/gates/stacks/proj-only.md" ]
  [ -f "$XDG_CONFIG_HOME/nightshift/gates/stacks/user-only.md" ]

  run bash "$PURGE" --project "$p" --confirm-path "$ns"
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift" ]
  [ -f "$XDG_CONFIG_HOME/nightshift/gates/stacks/user-only.md" ]

  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  q="$(new_project owner-stacks-path-ps)"
  printf '2\n' >"$q/.nightshift/state-version"
  write_stack "$q/.nightshift/gates/stacks/proj-only.md" "Project only"
  user_file="$APPDATA/nightshift/gates/stacks/user-only.md"
  write_stack "$user_file" "User only"
  ns="$(pwsh -NoProfile -Command "Import-Module '${PLUGIN}/lib/Nightshift.psm1' -Force -DisableNameChecking; Resolve-NSCanonicalPath (Join-Path (Resolve-NSCanonicalPath '${q}') '.nightshift')")"
  run pwsh -NoProfile -File "$RESET_PS1" -Project "$q"
  [ "$status" -eq 0 ]
  [ -f "$q/.nightshift/gates/stacks/proj-only.md" ]
  [ -f "$user_file" ]
  run pwsh -NoProfile -File "$PURGE_PS1" -Project "$q" -ConfirmPath "$ns"
  [ "$status" -eq 0 ]
  [ ! -e "$q/.nightshift" ]
  [ -f "$user_file" ]
}
