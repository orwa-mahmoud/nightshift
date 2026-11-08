#!/usr/bin/env bash
# lint-shell.sh — shellcheck every tracked shell file on its own, in parallel.
# Each file is checked once, library files included, without following what it sources: following
# made every script re-analyse the whole library. SC1091 is the note that a source was not followed.
# A variable one file sets for a library it sources carries a directive naming that reader.
set -euo pipefail
cd "$(dirname "$0")/.."

jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
git ls-files -z '*.sh' | xargs -0 -n 1 -P "$jobs" shellcheck -e SC1091
