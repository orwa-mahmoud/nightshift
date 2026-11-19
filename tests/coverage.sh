#!/usr/bin/env bash
# Line coverage for the shipped bash (plugins/nightshift/hooks + runtime + lib) — kcov over the bats suite.
# kcov's bash tracer is Linux-only: on Linux with kcov installed this runs natively; anywhere else
# the same script runs inside a debian container (docker required).
#
# kcov's memory grows with every test it traces: one heavy file alone passes 10 GB. So each test file
# is cut into groups of NIGHTSHIFT_COVERAGE_CHUNK tests (default 10), each group runs under its own
# kcov, NIGHTSHIFT_COVERAGE_JOBS groups at a time (default: one per CPU), and kcov merges the parts.
# A group that is killed, writes no coverage report, or runs a different number of tests than it was
# given fails the whole run with its file, its tests and the end of its log, and so does a merged
# report that counts no lines: an incomplete measurement is never reported as a coverage figure.
#
# Output: coverage/ — kcov HTML, plus two reports with repository-relative paths:
# coverage/cobertura.xml for Codecov and coverage/sonar-generic.xml for SonarQube.
set -euo pipefail
cd "$(dirname "$0")/.."

INCLUDE=plugins/nightshift/hooks,plugins/nightshift/runtime,plugins/nightshift/lib

CHUNKS=coverage/chunks.tsv

# test_names <test-file> — every test name in the file as bats matches it, one per line: the text of
# each `@test "..."` line exactly as written, backslashes included.
test_names() {
  sed -n 's/^@test "\(.*\)" {[[:space:]]*$/\1/p' "$1"
}

# ere_escape — standard input with every extended-regex special character escaped.
ere_escape() {
  sed 's#[]\[(){}.*+?^$|\\/]#\\&#g'
}

# write_chunks — one line per group in $CHUNKS: <test-file> TAB <test count> TAB <bats filter>.
write_chunks() {
  local file names count i group size
  size="$CHUNK"
  : >"$CHUNKS"
  while IFS= read -r file; do
    names="$(test_names "$file")"
    count="$(printf '%s\n' "$names" | grep -c . || :)"
    if [ "$count" -ne "$(grep -c '^@test ' "$file")" ]; then
      printf 'coverage: %s has %s @test lines but %s readable test names\n' "$file" "$(grep -c '^@test ' "$file")" "$count" >&2
      return 1
    fi
    i=0
    while [ "$i" -lt "$count" ]; do
      group="$(printf '%s\n' "$names" | sed -n "$((i + 1)),$((i + size))p")"
      printf '%s\t%s\t^(%s)$\n' "$file" "$(printf '%s\n' "$group" | grep -c .)" \
        "$(printf '%s\n' "$group" | ere_escape | paste -sd '|' -)" >>"$CHUNKS"
      i=$((i + size))
    done
  done < <(tests/run-shard.sh 1 1 --list)
}

# run_chunk <line> — the group on that line of $CHUNKS under its own kcov. Returns 1, after saying
# why on standard error, when the run was killed, wrote no coverage report, or ran a different
# number of tests than the group holds. A failing test still counts: its coverage is measured.
run_chunk() {
  local line="$1" file count filter out="coverage/part-$1" log="coverage/part-$1.log" status=0 ran why=""
  IFS=$'\t' read -r file count filter < <(sed -n "${line}p" "$CHUNKS")
  kcov --include-path="$PWD/$INCLUDE" "$out" "$(command -v bats)" --filter "$filter" "$file" >"$log" 2>&1 || status=$?
  ran="$(sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' "$log" | head -n 1)"
  if [ "$status" -ge 128 ]; then
    why="was killed by signal $((status - 128))"
  elif ! find "$out" -name cobertura.xml -print -quit 2>/dev/null | grep -q .; then
    why="wrote no coverage report (kcov exit $status)"
  elif [ "$ran" != "$count" ]; then
    why="ran ${ran:-no} tests where the group holds $count"
  fi
  if [ -z "$why" ]; then
    printf 'coverage: measured %s, group %s (%s tests)\n' "$file" "$line" "$count"
    return 0
  fi
  {
    printf 'coverage: %s, group %s %s, so its coverage is missing\n' "$file" "$line" "$why"
    printf -- '--- tests in the group: %s\n' "$filter"
    printf -- '--- last lines of %s\n' "$log"
    tail -n 25 "$log"
  } >&2
  return 1
}

# The parallel runner calls this script back once per group.
if [ "${1:-}" = --chunk ]; then
  run_chunk "$2"
  exit
fi

JOBS="${NIGHTSHIFT_COVERAGE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')}"
CHUNK="${NIGHTSHIFT_COVERAGE_CHUNK:-10}"
for setting in "NIGHTSHIFT_COVERAGE_JOBS=$JOBS" "NIGHTSHIFT_COVERAGE_CHUNK=$CHUNK"; do
  case "${setting#*=}" in
    '' | *[!0-9]* | 0)
      printf 'coverage: %s must be a positive whole number, got "%s"\n' "${setting%%=*}" "${setting#*=}" >&2
      exit 2
      ;;
  esac
done

if [ "$(uname -s)" != Linux ] || ! command -v kcov >/dev/null 2>&1; then
  exec docker run --rm -v "$PWD:/src" -w /src -e NIGHTSHIFT_COVERAGE_JOBS="$JOBS" -e NIGHTSHIFT_COVERAGE_CHUNK="$CHUNK" \
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
write_chunks
groups="$(grep -c . "$CHUNKS" || :)"
printf 'coverage: %s test groups of up to %s tests, %s at a time\n' "$groups" "$CHUNK" "$JOBS"

failed=0
seq 1 "$groups" | xargs -n 1 -P "$JOBS" bash tests/coverage.sh --chunk || failed=1
if [ "$failed" -ne 0 ]; then
  printf 'coverage: one or more test groups could not be measured (see above); no report written\n' >&2
  exit 1
fi

if ! kcov --merge coverage/merged coverage/part-*/; then
  printf 'coverage: kcov could not merge the per-group reports in coverage/part-*\n' >&2
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
