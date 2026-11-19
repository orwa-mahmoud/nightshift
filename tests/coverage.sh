#!/usr/bin/env bash
# Line coverage for the shipped bash (plugins/nightshift/hooks + runtime + lib) — kcov over the bats suite.
# kcov's bash tracer is Linux-only: on Linux with kcov installed this runs natively; anywhere else
# the same script runs inside a debian container (docker required).
#
# Each test file runs under its own kcov, NIGHTSHIFT_COVERAGE_JOBS at a time (default: one per CPU),
# and kcov merges the parts. A file whose run is killed or writes no coverage report fails the whole
# run with its name and the end of its log, and so does a merged report that counts no lines: an
# incomplete measurement is never reported as a coverage figure.
#
# Output: coverage/ — kcov HTML, plus two reports with repository-relative paths:
# coverage/cobertura.xml for Codecov and coverage/sonar-generic.xml for SonarQube.
set -euo pipefail
cd "$(dirname "$0")/.."

INCLUDE=plugins/nightshift/hooks,plugins/nightshift/runtime,plugins/nightshift/lib

# run_file <index> <test-file> — one test file under its own kcov. Returns 1, after saying why on
# standard error, when the run was killed or wrote no coverage report. A failing test still counts:
# its coverage is measured all the same.
run_file() {
  local out="coverage/part-$1" log="coverage/part-$1.log" status=0
  kcov --include-path="$PWD/$INCLUDE" "$out" "$(command -v bats)" "$2" >"$log" 2>&1 || status=$?
  if [ "$status" -lt 128 ] && find "$out" -name cobertura.xml -print -quit 2>/dev/null | grep -q .; then
    printf 'coverage: measured %s\n' "$2"
    return 0
  fi
  {
    if [ "$status" -ge 128 ]; then
      printf 'coverage: %s was killed by signal %s, so its coverage is missing\n' "$2" "$((status - 128))"
    else
      printf 'coverage: %s wrote no coverage report (kcov exit %s)\n' "$2" "$status"
    fi
    printf -- '--- last lines of %s\n' "$log"
    tail -n 25 "$log"
  } >&2
  return 1
}

# The parallel runner calls this script back once per test file.
if [ "${1:-}" = --file ]; then
  run_file "$2" "$3"
  exit
fi

JOBS="${NIGHTSHIFT_COVERAGE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')}"
case "$JOBS" in
  '' | *[!0-9]* | 0)
    printf 'coverage: NIGHTSHIFT_COVERAGE_JOBS must be a positive whole number, got "%s"\n' "$JOBS" >&2
    exit 2
    ;;
esac

if [ "$(uname -s)" != Linux ] || ! command -v kcov >/dev/null 2>&1; then
  exec docker run --rm -v "$PWD:/src" -w /src -e NIGHTSHIFT_COVERAGE_JOBS="$JOBS" \
    debian:stable-slim bash -c '
    set -e
    apt-get update -qq >/dev/null
    apt-get install -y -qq kcov bats git jq shellcheck python3 procps >/dev/null
    git config --global user.email dev@example.com
    git config --global user.name dev
    git config --global --add safe.directory "*"
    exec bash tests/coverage.sh'
fi

rm -rf coverage
mkdir -p coverage


failed=0
tests/run-shard.sh 1 1 --list | awk '{ print NR, $0 }' |
  xargs -n 2 -P "$JOBS" bash tests/coverage.sh --file || failed=1
if [ "$failed" -ne 0 ]; then
  printf 'coverage: one or more test files could not be measured (see above); no report written\n' >&2
  exit 1
fi

if ! kcov --merge coverage/merged coverage/part-*; then
  printf 'coverage: kcov could not merge the per-file reports in coverage/part-*\n' >&2
  exit 1
fi
cob="$(find coverage/merged -name cobertura.xml 2>/dev/null | head -n 1)"
if [ -z "$cob" ]; then
  printf 'coverage: the merged kcov output in coverage/merged has no cobertura.xml\n' >&2
  exit 1
fi
lines="$(jq -r '.total_lines' "$(dirname "$cob")/coverage.json")"
case "$lines" in
  '' | *[!0-9]* | 0)
    printf 'coverage: the merged report counts no lines (total_lines "%s"); nothing was measured\n' "$lines" >&2
    exit 1
    ;;
esac

python3 - "$cob" <<'PY'
import sys, xml.etree.ElementTree as ET

tree = ET.parse(sys.argv[1])
root = tree.getroot()
out = ['<coverage version="1">']
for cls in root.iter('class'):
    path, lines = cls.get('filename'), cls.find('lines')
    if not path or lines is None:
        continue
    if path.startswith(('runtime/', 'hooks/', 'lib/')):
        path = 'plugins/nightshift/' + path
    cls.set('filename', path)
    out.append(f'  <file path="{path}">')
    for ln in lines.iter('line'):
        covered = 'true' if int(ln.get('hits', '0')) > 0 else 'false'
        out.append(f'    <lineToCover lineNumber="{ln.get("number")}" covered="{covered}"/>')
    out.append('  </file>')
out.append('</coverage>')
open('coverage/sonar-generic.xml', 'w').write('\n'.join(out) + '\n')

# kcov names files relative to the directory it traced; the copy for Codecov names them from the
# repository root, so its paths match the files in git.
sources = root.find('sources')
if sources is not None:
    for source in list(sources):
        sources.remove(source)
    ET.SubElement(sources, 'source').text = '.'
tree.write('coverage/cobertura.xml', encoding='utf-8', xml_declaration=True)
PY

jq -r '"coverage: " + .percent_covered + "% of " + (.total_lines|tostring) + " lines"' \
  "$(dirname "$cob")/coverage.json"
