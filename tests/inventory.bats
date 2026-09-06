#!/usr/bin/env bats
# inventory reports what the work target declares — one table per package, three words per
# tool, and no judgement anywhere. Every run here goes through a controlled PATH so the
# answers depend on the fixture and not on the machine running the suite.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
SH="$PLUGIN/runtime/inventory.sh"
PS1_TWIN="$PLUGIN/runtime/windows/inventory.ps1"
LOGIC="$BATS_TEST_DIRNAME/windows/inventory-logic.ps1"
RUN_PS1="$BATS_TEST_DIRNAME/windows/run.ps1"
FIX="$BATS_TEST_DIRNAME/fixtures/inventory"
PWSH_BIN="$(command -v pwsh 2>/dev/null || true)"

# The tools inventory itself reaches for. Nothing else is on PATH, so a tool reads
# `runnable` only when a test puts it there.
BASE_TOOLSET="bash sh awk sort sed grep mktemp rm mv cp ln cat find printf test dirname \
basename env uname date true false head tail wc cut tr chmod git jq"

# prepare <fixture> <name> [git] — copy a fixture into the test's own tree. The fixture
# carries `gitignore` because this repository cannot hold a live ignore file inside a
# fixture; the copy gets the real name.
prepare() {
  local src="$FIX/$1" dst="$BATS_TEST_TMPDIR/$2"
  cp -R "$src" "$dst"
  [ ! -f "$dst/gitignore" ] || mv "$dst/gitignore" "$dst/.gitignore"
  if [ "${3:-}" = git ]; then
    git -C "$dst" init -q
    git -C "$dst" config user.email dev@example.com
    git -C "$dst" config user.name tester
  fi
  printf '%s' "$dst"
}

# inventory <bin> <args...> — run the helper on a controlled PATH.
inventory() {
  local bin="$1"
  shift
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" /bin/bash "$SH" "$@"
}

# row <label> — the value cell for one field row of the current output.
row() {
  printf '%s\n' "$output" | sed -n "s/^| $1 | \(.*\) |\$/\1/p" | head -1
}

setup() {
  # shellcheck disable=SC2086
  BIN="$(build_toolset_bin inventory-bin $BASE_TOOLSET)"
}

@test "a single npm repository reports its manager, lockfile, scripts and configs" {
  p="$(prepare npm-single npm git)"
  inventory "$BIN" --project "$p"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | head -1 | grep -qE '^inventory: 1 package in .+ \(git\)$'
  printf '%s\n' "$output" | sed -n '2p' | grep -qx 'ci: .github/workflows/ci.yml'
  printf '%s\n' "$output" | grep -qx '## . (node)'
  [ "$(row manager)" = npm ]
  [ "$(row lockfile)" = package-lock.json ]
  [ "$(row workspaces)" = no ]
  [ "$(row 'script test')" = test ]
  [ "$(row 'script lint')" = lint ]
  [ "$(row 'script build')" = build ]
  [ "$(row 'script format')" = fmt ]
  [ "$(row 'script typecheck')" = - ]
  [ "$(row 'config eslint')" = .eslintrc.json ]
  [ "$(row 'config prettier')" = .prettierrc ]
  [ "$(row 'config tsconfig')" = tsconfig.json ]
  [ "$(row 'config editorconfig')" = .editorconfig ]
  [ "$(row 'config ruff')" = - ]
}

@test "a gitignored package is not part of the inventory" {
  p="$(prepare npm-single npm git)"
  [ -f "$p/ignored/package.json" ]
  inventory "$BIN" --project "$p"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q 'ignored'
  printf '%s\n' "$output" | grep -c '^## ' | grep -qx 1
}

@test "a monorepo reports every workspace package and the lockfile above it" {
  p="$(prepare pnpm-monorepo mono)"
  inventory "$BIN" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | head -1 | grep -qE '^inventory: 3 packages in .+ \(none\)$'
  printf '%s\n' "$output" | grep -qx '## . (node)'
  printf '%s\n' "$output" | grep -qx '## packages/api (node)'
  printf '%s\n' "$output" | grep -qx '## packages/web (node)'

  inventory "$BIN" --project "$p" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    (.packages | length) == 3
    and (.packages[0] | .path == "." and .manager == "pnpm" and .workspaces == "yes")
    and (.packages[1] | .path == "packages/api" and .lockfile == "pnpm-lock.yaml"
         and .manager == "pnpm" and .workspaces == "no" and .scripts.lint == "lint")
    and (.packages[2] | .path == "packages/web" and .scripts.typecheck == "type-check"
         and .configs.tsconfig == "tsconfig.json")
  ' >/dev/null
}

# `npm run "lint all"` is one script. A key list joined by spaces reports it as two
# scripts that do not exist, and one of them answers to a role it never fills.
@test "a script name with a space stays one script name" {
  p="$(prepare spaced-scripts spaced)"
  inventory "$BIN" --project "$p"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ "$(row 'script test')" = test ]
  [ "$(row 'script lint')" = - ]
  [ "$(row 'script typecheck')" = - ]
  [ "$(row 'script build')" = - ]

  inventory "$BIN" --project "$p" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .packages[0].scripts == { build: "-", format: "-", lint: "-", test: "test", typecheck: "-" }
  ' >/dev/null
}

# A dependency on `ruff-lsp` is not a dependency on `ruff`, and `eslint-config-airbnb`
# is not eslint. A name only counts when it stands alone.
@test "a package name that merely starts with a tool is not that tool" {
  p="$(prepare near-names near)"
  inventory "$BIN" --project "$p" --json
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s' "$output" | jq -e '
    (.packages[0].tools | .ruff == "absent" and .mypy == "absent" and .eslint == "absent"
     and .prettier == "absent" and .pytest == "declared")
  ' >/dev/null
}

@test "a build directory is not mistaken for a package" {
  p="$(prepare pnpm-monorepo mono)"
  [ -f "$p/dist/package.json" ]
  inventory "$BIN" --project "$p"
  ! printf '%s\n' "$output" | grep -q '^## dist'
}

@test "a Python project reports the sections its manifests open" {
  p="$(prepare python-project py)"
  inventory "$BIN" --project "$p" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    (.packages | length) == 1
    and (.packages[0] | .kind == "python" and .manager == "pip" and .lockfile == "-"
         and .workspaces == "-"
         and .configs.ruff == "pyproject.toml" and .configs.mypy == "pyproject.toml"
         and .configs.pytest == "pyproject.toml"
         and .tools.ruff == "declared" and .tools.mypy == "declared"
         and .tools.pytest == "declared"
         and (.scripts | to_entries | all(.value == "-")))
  ' >/dev/null
}

@test "a Go module reports its checksum file and linter config" {
  p="$(prepare go-module go)"
  inventory "$BIN" --project "$p" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    (.packages | length) == 1
    and (.packages[0] | .kind == "go" and .manager == "go" and .lockfile == "go.sum"
         and .configs.golangci == ".golangci.yml"
         and .tools["golangci-lint"] == "declared" and .tools.eslint == "absent")
  ' >/dev/null
}

@test "a folder with no manifest is an inventory of nothing, not a failure" {
  p="$(prepare empty none)"
  inventory "$BIN" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | head -1 | grep -qE '^inventory: 0 packages in .+ \(none\)$'
  printf '%s\n' "$output" | sed -n '2p' | grep -qx 'ci: none'
  ! printf '%s\n' "$output" | grep -q '^## '

  inventory "$BIN" --project "$p" --json
  printf '%s' "$output" | jq -e '.packages == [] and .ci == [] and .vcs == "none"' >/dev/null
}

@test "a bin under node_modules/.bin makes a tool runnable for the package and its children" {
  p="$(prepare pnpm-monorepo mono)"
  mkdir -p "$p/node_modules/.bin"
  printf '#!/bin/sh\nexit 0\n' >"$p/node_modules/.bin/tsc"
  mkdir -p "$p/packages/api/node_modules/.bin"
  printf '#!/bin/sh\nexit 0\n' >"$p/packages/api/node_modules/.bin/biome"
  inventory "$BIN" --project "$p" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    (.packages[0].tools.tsc == "runnable")
    and (.packages[1].tools.biome == "runnable" and .packages[1].tools.tsc == "runnable")
    and (.packages[2].tools.tsc == "runnable" and .packages[2].tools.biome == "absent")
  ' >/dev/null
}

@test "a tool on PATH is runnable, and one only named is declared" {
  p="$(prepare npm-single npm git)"
  inventory "$BIN" --project "$p" --json
  printf '%s' "$output" | jq -e '.packages[0].tools.eslint == "declared"' >/dev/null

  printf '#!/bin/sh\nexit 0\n' >"$BIN/eslint"
  chmod +x "$BIN/eslint"
  inventory "$BIN" --project "$p" --json
  printf '%s' "$output" | jq -e '.packages[0].tools.eslint == "runnable"' >/dev/null
}

@test "a tool is only ever declared, runnable or absent" {
  for fixture in npm-single pnpm-monorepo python-project go-module spaced-scripts near-names; do
    p="$(prepare "$fixture" "state-$fixture")"
    inventory "$BIN" --project "$p" --json
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '
      .packages | all(.tools | to_entries
        | all(.value == "declared" or .value == "runnable" or .value == "absent"))
    ' >/dev/null || { echo "$fixture reported a state outside the three words"; return 1; }
  done
}

@test "--json is one canonical object with sorted keys" {
  p="$(prepare pnpm-monorepo mono)"
  inventory "$BIN" --project "$p" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  printf '%s' "$output" | jq -e '
    .version == 1 and keys == (keys | sort)
    and (.packages | all(keys == (keys | sort)))
    and (.packages | all(.configs | keys == (keys | sort)))
    and (.packages | all(.scripts | keys == (keys | sort)))
    and (.packages | all(.tools | keys == (keys | sort)))
  ' >/dev/null
}

@test "an unreadable target and a bad argument are told apart" {
  inventory "$BIN" --project "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 3 ]
  [ "$output" = "unavailable inventory: the work target is not a readable directory" ]

  p="$(prepare go-module go)"
  inventory "$BIN" --project "$p" --deep
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'unknown argument: --deep'

  inventory "$BIN" --project
  [ "$status" -eq 1 ]
}

@test "a package.json that will not parse is unavailable, never a blank package" {
  p="$(prepare npm-single npm git)"
  printf '{ "name": "single",\n' >"$p/package.json"
  inventory "$BIN" --project "$p"
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | grep -qF 'unavailable inventory: ./package.json is not readable JSON'
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "package.json needs jq; a manifest that is not JSON does not" {
  nojq="$(build_toolset_bin inventory-no-jq bash sh awk sort sed grep mktemp rm mv cp ln cat \
    find printf test dirname basename env uname date true false head tail wc cut tr chmod git)"
  [ ! -e "$nojq/jq" ]

  p="$(prepare npm-single npm git)"
  inventory "$nojq" --project "$p"
  [ "$status" -eq 3 ]
  [ "$output" = "unavailable inventory: jq is required to read package.json and is not on PATH" ]

  g="$(prepare go-module go)"
  inventory "$nojq" --project "$g"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx '| lockfile | go.sum |'
}

@test "the inventory reads the work target and writes nothing" {
  p="$(prepare npm-single npm git)"
  git -C "$p" add -A
  git -C "$p" -c user.name=t -c user.email=t@example.com commit -q -m fixture
  before="$(find "$p" | LC_ALL=C sort)"
  inventory "$BIN" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(git -C "$p" status --porcelain)" = "" ]
  [ "$(find "$p" | LC_ALL=C sort)" = "$before" ]
}

@test "the same tree always yields the same bytes" {
  p="$(prepare pnpm-monorepo mono)"
  inventory "$BIN" --project "$p" --json
  first="$output"
  inventory "$BIN" --project "$p" --json
  [ "$first" = "$output" ]
}

@test "both engines print the same bytes for every fixture" {
  if ! have_pwsh; then
    skip 'pwsh not installed'
  fi
  for fixture in npm-single pnpm-monorepo python-project go-module empty spaced-scripts \
    near-names; do
    p="$(prepare "$fixture" "parity-$fixture")"
    # Both engines are handed the physical path: bash resolves symlinks itself, PowerShell
    # 5.1 has no portable way to, and the platform's temp root is a symlink on macOS.
    p="$(cd "$p" && pwd -P)"
    for mode in md json; do
      shflag=""
      psflag=""
      if [ "$mode" = json ]; then
        shflag=--json
        psflag=-Json
      fi
      env -i PATH="$BIN" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        /bin/bash "$SH" --project "$p" $shflag >"$BATS_TEST_TMPDIR/sh.out" || true
      env -i PATH="$BIN:$(dirname "$PWSH_BIN")" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        "$PWSH_BIN" -NoProfile -NonInteractive -File "$PS1_TWIN" \
        -Project "$p" $psflag >"$BATS_TEST_TMPDIR/ps.out" || true
      cmp "$BATS_TEST_TMPDIR/sh.out" "$BATS_TEST_TMPDIR/ps.out" \
        || { echo "$fixture $mode differs between engines"; return 1; }
    done
  done
}

# `find` without -L descends no symlink and lists no symlinked file. A recursive walk that
# followed one would report a package outside the work target, and a cycle would never end.
@test "neither engine follows a link out of the work target" {
  p="$(prepare spaced-scripts linked)"
  mkdir -p "$BATS_TEST_TMPDIR/outside/pkg"
  cp "$FIX/go-module/go.mod" "$BATS_TEST_TMPDIR/outside/pkg/go.mod"
  ln -s "$BATS_TEST_TMPDIR/outside" "$p/outside"
  ln -s "$p/package.json" "$p/aliased.json"

  inventory "$BIN" --project "$p" --json
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s' "$output" | jq -e '[.packages[].path] == ["."]' >/dev/null \
    || { echo "the walk left the work target: $output"; return 1; }

  if have_pwsh; then
    physical="$(cd "$p" && pwd -P)"
    env -i PATH="$BIN" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
      /bin/bash "$SH" --project "$physical" --json >"$BATS_TEST_TMPDIR/sh.json"
    env -i PATH="$BIN:$(dirname "$PWSH_BIN")" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
      "$PWSH_BIN" -NoProfile -NonInteractive -File "$PS1_TWIN" \
      -Project "$physical" -Json >"$BATS_TEST_TMPDIR/ps.json"
    cmp "$BATS_TEST_TMPDIR/sh.json" "$BATS_TEST_TMPDIR/ps.json" \
      || { echo 'the engines disagree about a linked directory'; return 1; }
  fi
}

@test "the native Windows twin ships and is registered in the Windows suite" {
  [ -f "$PS1_TWIN" ]
  [ -f "$LOGIC" ]
  grep -qF 'inventory-logic.ps1' "$RUN_PS1"
}

@test "the Windows logic suite passes when pwsh is present" {
  if ! have_pwsh; then
    skip 'pwsh not installed'
  fi
  run "$PWSH_BIN" -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "Doctor offers the inventory without running it, and Status may show it" {
  DOCTOR="$PLUGIN/skills/doctor/SKILL.md"
  STATUS="$PLUGIN/skills/status/SKILL.md"
  grep -qE 'ns"? inventory' "$DOCTOR"
  grep -qF 'A senior may run the read-only project inventory' "$DOCTOR"
  grep -qF 'Doctor never runs it' "$DOCTOR"
  grep -qE 'ns"? inventory' "$STATUS"
}

@test "Hunt and Quality name the inventory only as optional, and Automatic never needs it" {
  for skill in hunt quality; do
    line="$(grep -nE 'ns"? inventory' "$PLUGIN/skills/$skill/SKILL.md" | head -1)"
    [ -n "$line" ] || { echo "$skill does not name the inventory"; return 1; }
    grep -qF 'if present, optional' "$PLUGIN/skills/$skill/SKILL.md" \
      || { echo "$skill does not mark the inventory optional"; return 1; }
  done
  # Automatic composes and works without it: no shift entry may require it.
  ! grep -rlE 'inventory\.sh|ns inventory' "$PLUGIN/skills/nightshift/references/compose/shifts" | grep -q .
  grep -qF 'runtime/inventory.sh' "$ROOT/docs/evidence-capabilities.md"
}
