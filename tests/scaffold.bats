#!/usr/bin/env bats
# Copying a file does not require reading its text.
#
# Setup pointed the model at seven template files so it could write them out — seven files loaded
# to reproduce seven files. The helper copies them, which costs no context and cannot paraphrase.
# What it must never do is overwrite something the owner has: a name already in `.nightshift/` is
# theirs, whatever it now contains.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
SCAFFOLD="$ROOT/plugins/nightshift/runtime/scaffold.sh"
PS_SCAFFOLD="$ROOT/plugins/nightshift/runtime/windows/scaffold.ps1"
TEMPLATES="$ROOT/plugins/nightshift/skills/nightshift/references/templates"

ps_ready() {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
}

bare() { # a workspace with no state files at all
  local p
  p="$(new_project "$1")"
  rm -f "$p/.nightshift"/*.md
  printf '%s' "$p"
}

@test "--list names every template without touching a workspace" {
  run bash "$SCAFFOLD" --list
  [ "$status" -eq 0 ]
  for t in punch-list drafting-table parking-lot snag-log product-research opportunity-map work-orders; do
    printf '%s\n' "$output" | grep -qxF "$t.md" || { echo "not listed: $t.md"; return 1; }
  done
}

@test "a bare workspace gets every template, reported one per line" {
  p="$(bare scaffold-bare)"
  run bash "$SCAFFOLD" --project "$p"
  [ "$status" -eq 0 ]
  for f in "$TEMPLATES"/*.md; do
    name="${f##*/}"
    [ -f "$p/.nightshift/$name" ] || { echo "not written: $name"; return 1; }
    printf '%s\n' "$output" | grep -qxF "wrote $name" || { echo "not reported: $name"; return 1; }
  done
}

@test "a file the owner already has is kept, whatever it now contains" {
  p="$(bare scaffold-keep)"
  bash "$SCAFFOLD" --project "$p" >/dev/null
  printf 'my own list, nothing like the template\n' >"$p/.nightshift/punch-list.md"

  run bash "$SCAFFOLD" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'kept punch-list.md'
  ! printf '%s\n' "$output" | grep -q '^wrote '
  grep -qxF 'my own list, nothing like the template' "$p/.nightshift/punch-list.md"
}

@test "a symlink where a state file belongs is the owner's too, and is never followed" {
  p="$(bare scaffold-symlink)"
  target="$p/elsewhere.md"
  printf 'somewhere else entirely\n' >"$target"
  ln -s "$target" "$p/.nightshift/punch-list.md"

  run bash "$SCAFFOLD" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'kept punch-list.md'
  # The link is intact and what it points at is untouched.
  [ -L "$p/.nightshift/punch-list.md" ]
  grep -qxF 'somewhere else entirely' "$target"
}

@test "the copy resolves the paths a person would have to paste" {
  p="$(bare scaffold-resolved)"
  bash "$SCAFFOLD" --project "$p" >/dev/null
  ns="$(cd -P "$p" && pwd)/.nightshift"

  # The template says `$NS/STOP` because it has to speak generically; the owner's copy says where.
  grep -qF "$ns" "$p/.nightshift/punch-list.md"
  ! grep -q '\$NS' "$p/.nightshift/punch-list.md"
  # And the shipped template is exactly as it shipped.
  grep -q '\$NS' "$TEMPLATES/punch-list.md"
}

@test "running twice is a safe repair" {
  p="$(bare scaffold-twice)"
  bash "$SCAFFOLD" --project "$p" >/dev/null
  before="$(find "$p/.nightshift" -type f -exec cksum {} + | sort)"
  run bash "$SCAFFOLD" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(find "$p/.nightshift" -type f -exec cksum {} + | sort)" = "$before" ]
}

@test "a workspace link is followed, and an invalid one refuses rather than guessing" {
  real="$(bare scaffold-link-real)"
  host="$BATS_TEST_TMPDIR/scaffold-link-host"
  mkdir -p "$host"
  printf '%s\n' "$real" >"$host/.nightshift-link"
  run bash "$SCAFFOLD" --project "$host"
  [ "$status" -eq 0 ]
  [ -f "$real/.nightshift/punch-list.md" ]

  printf 'not-absolute\n' >"$host/.nightshift-link"
  run bash "$SCAFFOLD" --project "$host"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'will not guess a workspace'
}

@test "both hosts write the same files with the same substitutions" {
  ps_ready
  p="$(bare scaffold-twin)"
  bash "$SCAFFOLD" --project "$p" >"$p/posix.txt"
  cp -R "$p/.nightshift" "$p/from-posix"
  rm -f "$p/.nightshift"/*.md

  pwsh -NoProfile -NonInteractive -File "$PS_SCAFFOLD" -Project "$p" >"$p/windows.txt" 2>&1
  diff -u "$p/posix.txt" "$p/windows.txt"

  # The two resolvers spell a symlinked path differently on this fixture — the POSIX one
  # canonicalises, so a macOS temp dir comes back as /private/var. That divergence is the
  # resolvers' and is recorded as such; what belongs to the scaffold is the substituted content,
  # so the workspace prefix is normalised out before comparing.
  real="$(cd -P "$p" && pwd)"
  for f in "$TEMPLATES"/*.md; do
    name="${f##*/}"
    sed "s|$real|WS|g" "$p/from-posix/$name" >"$p/a.md"
    sed "s|$real|WS|g;s|$p|WS|g" "$p/.nightshift/$name" >"$p/b.md"
    diff -u "$p/a.md" "$p/b.md"
  done
}
