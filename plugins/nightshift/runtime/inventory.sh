#!/usr/bin/env bash
# inventory.sh — what the work target declares, one table per package.
#
#   inventory.sh --project <work-target> [--json]
#
# Walks the work target — `git ls-files` when it is a repository, so .gitignore is
# honoured, otherwise `find` with the usual build and vendor directories pruned —
# and reports one package per manifest it finds: package.json, Cargo.toml, go.mod,
# pyproject.toml, setup.cfg or requirements.txt. Monorepos fall out of that walk,
# and a workspace declaration (npm/pnpm/yarn `workspaces`, `pnpm-workspace.yaml`,
# a Cargo `[workspace]`) is reported as its own field.
#
# Per package: the package manager and the lockfile behind it, the scripts declared
# for test, lint, typecheck, build and format, the config files present, and each
# named tool as `runnable` (a bin under node_modules/.bin or the tool on PATH),
# `declared` (the package names it, no bin found) or `absent`. Those three words are
# the whole verdict — the report never says a project is set up wrongly.
#
# Read-only. Writes nothing, caches nothing, installs nothing, asks nothing.
# Scripts come from package.json; other manifests report `-` for them.
#
# Exit: 0 inventory · 1 usage · 3 unavailable
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"
# The awk and jq programs beside lib.sh, resolved from this script's own path.
PROGRAMS="$_here/../lib"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
MODE=md

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'inventory: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --json)
      MODE=json
      shift
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'inventory: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

unavail() {
  printf 'unavailable inventory: %s\n' "$1"
  exit 3
}

TARGET="$(cd -P "$PROJECT" 2>/dev/null && pwd)" ||
  unavail 'the work target is not a readable directory'

TMPD=""
# shellcheck disable=SC2317,SC2329 # trap EXIT invokes this
_cleanup() { [ -z "$TMPD" ] || rm -rf -- "$TMPD"; }
trap _cleanup EXIT
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/nightshift-inventory.XXXXXX")" ||
  unavail 'no writable temporary directory'

# The fixed vocabularies. Every package reports every row, so two inventories of the
# same tree line up column for column even when a package carries none of them.
ROLES="build format lint test typecheck"
TOOLS="biome clippy eslint golangci-lint mypy prettier pytest ruff tsc"

MANIFESTS="package.json Cargo.toml go.mod pyproject.toml setup.cfg requirements.txt"
CI_FILES=".gitlab-ci.yml azure-pipelines.yml Jenkinsfile .travis.yml
bitbucket-pipelines.yml .circleci/config.yml"

# ------------------------------------------------------------------ the walk

VCS=none
if [ "$(git -C "$TARGET" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
  VCS=git
fi

# A path no inventory should describe: an installed dependency, a build output, or a
# cache. Pruned in both walks, so a repository that tracks its vendor tree reads the
# same as one that ignores it.
_noise() {
  case "/$1/" in
    */node_modules/* | */.git/* | */.venv/* | */venv/* | */__pycache__/* | */vendor/* \
      | */dist/* | */build/* | */.next/* | */.tox/* | */target/debug/* | */target/release/*)
      return 0
      ;;
  esac
  return 1
}

if [ "$VCS" = git ]; then
  git -C "$TARGET" ls-files --cached --others --exclude-standard >"$TMPD/all" 2>/dev/null ||
    : >"$TMPD/all"
else
  (cd "$TARGET" && find . \
    \( -name node_modules -o -name .git -o -name .venv -o -name venv \
    -o -name __pycache__ -o -name vendor -o -name dist -o -name build \
    -o -name .next -o -name .tox \) -prune -o -type f -print) >"$TMPD/all" 2>/dev/null ||
    : >"$TMPD/all"
  sed -e 's#^\./##' "$TMPD/all" >"$TMPD/all.clean"
  mv "$TMPD/all.clean" "$TMPD/all"
fi

# Package directories: one per manifest, relative to the work target, root as ".".
: >"$TMPD/dirs"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  _noise "$rel" && continue
  base="${rel##*/}"
  for m in $MANIFESTS; do
    [ "$base" = "$m" ] || continue
    dir="${rel%/*}"
    [ "$dir" != "$rel" ] || dir=.
    printf '%s\n' "$dir" >>"$TMPD/dirs"
    break
  done
done <"$TMPD/all"
LC_ALL=C sort -u "$TMPD/dirs" >"$TMPD/pkgdirs"

# CI definitions the work target carries, by name and by workflow directory.
: >"$TMPD/ci"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  _noise "$rel" && continue
  case "$rel" in
    .github/workflows/*.yml | .github/workflows/*.yaml)
      printf '%s\n' "$rel" >>"$TMPD/ci"
      continue
      ;;
  esac
  for c in $CI_FILES; do
    [ "$rel" = "$c" ] && printf '%s\n' "$rel" >>"$TMPD/ci"
  done
done <"$TMPD/all"
LC_ALL=C sort -u "$TMPD/ci" >"$TMPD/cifiles"

# ------------------------------------------------------------------ per package

# _first DIR NAME... -> FOUND, the first of NAME that exists under DIR, else "-".
_first() {
  local dir="$1" name
  shift
  for name in "$@"; do
    if [ -f "$TARGET/$dir/$name" ]; then
      FOUND="$name"
      return 0
    fi
  done
  FOUND=-
  return 0
}

# _section DIR FILE PATTERN -> 0 when FILE under DIR opens that section.
_section() {
  [ -f "$TARGET/$1/$2" ] || return 1
  LC_ALL=C grep -q "$3" "$TARGET/$1/$2"
}

# The token has to stand alone: a dependency on `ruff-lsp` is not a dependency on
# `ruff`, so a neighbouring name character rules the hit out and only a delimiter — an
# end of line, a version operator, an extras bracket, a quote or a comma — lets it
# through. Status 0 when the file names the token that way.

# _mentions DIR NAME -> 0 when a manifest in DIR names NAME as a package of its own.
_mentions() {
  local dir="$1" mention="$2" f
  for f in package.json Cargo.toml go.mod pyproject.toml setup.cfg requirements.txt tox.ini; do
    [ -f "$TARGET/$dir/$f" ] || continue
    LC_ALL=C awk -v tok="$mention" -f "$PROGRAMS/inventory-mentions.awk" "$TARGET/$dir/$f" && return 0
  done
  return 1
}

# _bin DIR NAME -> 0 when NAME is reachable: a bin file under this package's
# node_modules/.bin or any ancestor's up to the work target, or NAME on PATH.
_bin() {
  local dir="$1" name="$2" probe
  probe="$dir"
  while :; do
    if [ "$probe" = . ]; then
      [ -f "$TARGET/node_modules/.bin/$name" ] && return 0
      break
    fi
    [ -f "$TARGET/$probe/node_modules/.bin/$name" ] && return 0
    case "$probe" in
      */*) probe="${probe%/*}" ;;
      *) probe=. ;;
    esac
  done
  command -v "$name" >/dev/null 2>&1
}

# _lockfile DIR -> LOCK relative to the work target and MANAGER, taking the nearest
# ancestor's lockfile when the package has none of its own — which is what a
# workspace looks like from inside one of its packages.
_lockfile() {
  local dir="$1" probe pick
  probe="$dir"
  while :; do
    for pick in pnpm-lock.yaml yarn.lock package-lock.json npm-shrinkwrap.json bun.lockb \
      Cargo.lock go.sum uv.lock poetry.lock Pipfile.lock; do
      if [ "$probe" = . ]; then
        [ -f "$TARGET/$pick" ] || continue
        LOCK="$pick"
      else
        [ -f "$TARGET/$probe/$pick" ] || continue
        LOCK="$probe/$pick"
      fi
      case "$pick" in
        pnpm-lock.yaml) MANAGER=pnpm ;;
        yarn.lock) MANAGER=yarn ;;
        package-lock.json | npm-shrinkwrap.json) MANAGER=npm ;;
        bun.lockb) MANAGER=bun ;;
        Cargo.lock) MANAGER=cargo ;;
        go.sum) MANAGER=go ;;
        uv.lock) MANAGER=uv ;;
        poetry.lock) MANAGER=poetry ;;
        Pipfile.lock) MANAGER=pipenv ;;
      esac
      return 0
    done
    [ "$probe" != . ] || break
    case "$probe" in
      */*) probe="${probe%/*}" ;;
      *) probe=. ;;
    esac
  done
  LOCK=-
  MANAGER=-
  return 0
}

# One script name per line, because a name may hold spaces: `npm run "lint all"` is
# one script, and a list joined by spaces would report it as two that do not exist.

STREAM="$TMPD/stream"
: >"$STREAM"
printf 'target\t%s\n' "$TARGET" >>"$STREAM"
printf 'vcs\t%s\n' "$VCS" >>"$STREAM"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  printf 'ci\t%s\n' "$rel" >>"$STREAM"
done <"$TMPD/cifiles"

while IFS= read -r dir; do
  [ -n "$dir" ] || continue

  KIND=other
  [ -f "$TARGET/$dir/requirements.txt" ] && KIND=python
  [ -f "$TARGET/$dir/setup.cfg" ] && KIND=python
  [ -f "$TARGET/$dir/pyproject.toml" ] && KIND=python
  [ -f "$TARGET/$dir/go.mod" ] && KIND=go
  [ -f "$TARGET/$dir/Cargo.toml" ] && KIND=cargo
  [ -f "$TARGET/$dir/package.json" ] && KIND=node

  : >"$TMPD/scriptkeys"
  WORKSPACES=-
  if [ -f "$TARGET/$dir/package.json" ]; then
    command -v jq >/dev/null 2>&1 ||
      unavail 'jq is required to read package.json and is not on PATH'
    jq -r -f "$(ns_native_display_path "$PROGRAMS/inventory-package.jq")" <"$TARGET/$dir/package.json" >"$TMPD/pkg" 2>/dev/null ||
      unavail "$dir/package.json is not readable JSON"
    LC_ALL=C awk -F'\t' '$1 == "script-key" { print $2 }' <"$TMPD/pkg" >"$TMPD/scriptkeys"
    WORKSPACES="$(LC_ALL=C awk -F'\t' '$1 == "workspaces" { print $2; exit }' <"$TMPD/pkg")"
    if [ "$WORKSPACES" = no ] && [ -f "$TARGET/$dir/pnpm-workspace.yaml" ]; then
      WORKSPACES=yes
    fi
  elif [ -f "$TARGET/$dir/Cargo.toml" ]; then
    if _section "$dir" Cargo.toml '^\[workspace\]'; then WORKSPACES=yes; else WORKSPACES=no; fi
  fi

  _lockfile "$dir"
  if [ "$MANAGER" = - ]; then
    case "$KIND" in
      go) MANAGER=go ;;
      cargo) MANAGER=cargo ;;
      python) MANAGER=pip ;;
    esac
  fi

  {
    printf 'pkg\t%s\t%s\n' "$dir" "$KIND"
    printf 'field\t%s\tmanager\t%s\n' "$dir" "$MANAGER"
    printf 'field\t%s\tlockfile\t%s\n' "$dir" "$LOCK"
    printf 'field\t%s\tworkspaces\t%s\n' "$dir" "$WORKSPACES"
  } >>"$STREAM"

  for role in $ROLES; do
    case "$role" in
      typecheck) candidates="typecheck type-check types tsc" ;;
      format) candidates="format fmt" ;;
      *) candidates="$role" ;;
    esac
    value=-
    for candidate in $candidates; do
      while IFS= read -r key; do
        if [ "$key" = "$candidate" ]; then
          value="$candidate"
          break
        fi
      done <"$TMPD/scriptkeys"
      [ "$value" = - ] || break
    done
    printf 'script\t%s\t%s\t%s\n' "$dir" "$role" "$value" >>"$STREAM"
  done

  _config() { printf 'config\t%s\t%s\t%s\n' "$dir" "$1" "$2" >>"$STREAM"; }

  _first "$dir" biome.json biome.jsonc
  CFG_BIOME="$FOUND"
  _config biome "$CFG_BIOME"

  _first "$dir" clippy.toml .clippy.toml
  CFG_CLIPPY="$FOUND"
  _config clippy "$CFG_CLIPPY"

  _first "$dir" .editorconfig
  CFG_EDITORCONFIG="$FOUND"
  _config editorconfig "$CFG_EDITORCONFIG"

  _first "$dir" eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts \
    .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc.yml .eslintrc.yaml
  CFG_ESLINT="$FOUND"
  _config eslint "$CFG_ESLINT"

  _first "$dir" .golangci.yml .golangci.yaml .golangci.toml .golangci.json
  CFG_GOLANGCI="$FOUND"
  _config golangci "$CFG_GOLANGCI"

  _first "$dir" mypy.ini .mypy.ini
  if [ "$FOUND" = - ] && _section "$dir" pyproject.toml '^\[tool\.mypy'; then
    FOUND=pyproject.toml
  fi
  if [ "$FOUND" = - ] && _section "$dir" setup.cfg '^\[mypy\]'; then
    FOUND=setup.cfg
  fi
  CFG_MYPY="$FOUND"
  _config mypy "$CFG_MYPY"

  _first "$dir" .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml \
    .prettierrc.js .prettierrc.cjs prettier.config.js prettier.config.cjs prettier.config.mjs
  CFG_PRETTIER="$FOUND"
  _config prettier "$CFG_PRETTIER"

  _first "$dir" pytest.ini
  if [ "$FOUND" = - ] && _section "$dir" pyproject.toml '^\[tool\.pytest'; then
    FOUND=pyproject.toml
  fi
  if [ "$FOUND" = - ] && _section "$dir" setup.cfg '^\[tool:pytest\]'; then
    FOUND=setup.cfg
  fi
  if [ "$FOUND" = - ] && _section "$dir" tox.ini '^\[pytest\]'; then
    FOUND=tox.ini
  fi
  CFG_PYTEST="$FOUND"
  _config pytest "$CFG_PYTEST"

  _first "$dir" ruff.toml .ruff.toml
  if [ "$FOUND" = - ] && _section "$dir" pyproject.toml '^\[tool\.ruff'; then
    FOUND=pyproject.toml
  fi
  CFG_RUFF="$FOUND"
  _config ruff "$CFG_RUFF"

  _first "$dir" tsconfig.json
  CFG_TSCONFIG="$FOUND"
  _config tsconfig "$CFG_TSCONFIG"

  for name in $TOOLS; do
    case "$name" in
      biome) cfg="$CFG_BIOME"; bin=biome; mention=biome ;;
      clippy) cfg="$CFG_CLIPPY"; bin=cargo-clippy; mention=clippy ;;
      eslint) cfg="$CFG_ESLINT"; bin=eslint; mention=eslint ;;
      golangci-lint) cfg="$CFG_GOLANGCI"; bin=golangci-lint; mention=golangci-lint ;;
      mypy) cfg="$CFG_MYPY"; bin=mypy; mention=mypy ;;
      prettier) cfg="$CFG_PRETTIER"; bin=prettier; mention=prettier ;;
      pytest) cfg="$CFG_PYTEST"; bin=pytest; mention=pytest ;;
      ruff) cfg="$CFG_RUFF"; bin=ruff; mention=ruff ;;
      tsc) cfg="$CFG_TSCONFIG"; bin=tsc; mention=typescript ;;
    esac
    if _bin "$dir" "$bin"; then
      state=runnable
    elif [ "$cfg" != - ] || _mentions "$dir" "$mention"; then
      state=declared
    else
      state=absent
    fi
    printf 'tool\t%s\t%s\t%s\n' "$dir" "$name" "$state" >>"$STREAM"
  done
done <"$TMPD/pkgdirs"

# ------------------------------------------------------------------ rendering


LC_ALL=C awk -v MODE="$MODE" -f "$PROGRAMS/inventory-render.awk" "$STREAM"
exit 0
