#!/usr/bin/env bash
# Line coverage for the shipped bash (plugins/nightshift/hooks + runtime + lib) — kcov over the bats suite.
# kcov's bash tracer is Linux-only: on Linux with kcov installed this runs natively,
# anywhere else it runs in a debian container (docker required).
# Output: coverage/ — kcov HTML + cobertura, plus coverage/sonar-generic.xml.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf coverage
mkdir -p coverage

# One kcov process over the whole suite does not survive it: the run stops partway through, at
# the same test every time, and reports coverage for the files it reached as though that were all
# of them. So the suite is sharded the way CI already shards it, each shard measured on its own,
# and kcov merges the parts. tests/run-shard.sh owns the split, so this cannot drift from CI.
SHARDS="${NIGHTSHIFT_COVERAGE_SHARDS:-6}"
INCLUDE=plugins/nightshift/hooks,plugins/nightshift/runtime,plugins/nightshift/lib

if [ "$(uname -s)" = Linux ] && command -v kcov >/dev/null 2>&1; then
  for s in $(seq 1 "$SHARDS"); do
    files=()
    while IFS= read -r f; do
      [ -n "$f" ] && files+=("$f")
    done < <(tests/run-shard.sh "$s" "$SHARDS" --list)
    kcov --include-path="$PWD/$INCLUDE" "coverage/shard-$s" \
      "$(command -v bats)" "${files[@]}" || true
  done
  kcov --merge coverage/merged coverage/shard-* ||
    find coverage -name cobertura.xml -print -quit | grep -q .
else
  docker run --rm -v "$PWD:/src" -w /src -e SHARDS="$SHARDS" -e INCLUDE="$INCLUDE" \
    debian:stable-slim sh -c '
    apt-get update -qq >/dev/null && apt-get install -y -qq kcov bats git jq shellcheck >/dev/null
    git config --global user.email dev@example.com
    git config --global user.name dev
    git config --global --add safe.directory "*"
    s=1
    while [ "$s" -le "$SHARDS" ]; do
      # No arrays in the container shell; the positional parameters carry the shard file list.
      # shellcheck disable=SC2046 # splitting the file list into arguments is the point
      set -- $(/src/tests/run-shard.sh "$s" "$SHARDS" --list)
      kcov --include-path="/src/$INCLUDE" "/src/coverage/shard-$s" \
        "$(command -v bats)" "$@" || true
      s=$((s + 1))
    done
    kcov --merge /src/coverage/merged /src/coverage/shard-* ||
      find /src/coverage -name cobertura.xml -print -quit | grep -q .'
fi

# The merged report is the one that describes the whole suite; a shard's own is a part of it.
cob="$(find coverage/merged -name cobertura.xml 2>/dev/null | head -n 1)"
[ -n "$cob" ] || cob="$(find coverage -name cobertura.xml | head -n 1)"
python3 - "$cob" <<'PY'
import sys, xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
out = ['<coverage version="1">']
for cls in root.iter('class'):
    path, lines = cls.get('filename'), cls.find('lines')
    if not path or lines is None:
        continue
    if path.startswith(('runtime/', 'hooks/', 'lib/')):
        path = 'plugins/nightshift/' + path
    out.append(f'  <file path="{path}">')
    for ln in lines.iter('line'):
        covered = 'true' if int(ln.get('hits', '0')) > 0 else 'false'
        out.append(f'    <lineToCover lineNumber="{ln.get("number")}" covered="{covered}"/>')
    out.append('  </file>')
out.append('</coverage>')
open('coverage/sonar-generic.xml', 'w').write('\n'.join(out) + '\n')
PY

jq -r '"coverage: " + .percent_covered + "% of " + (.total_lines|tostring) + " lines"' \
  "$(dirname "$cob")/coverage.json"
