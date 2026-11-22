#!/usr/bin/env bash
# Line coverage for the shipped bash (plugins/nightshift/hooks + runtime + lib) — kcov over the bats suite.
# kcov's bash tracer is Linux-only: on Linux with kcov installed this runs natively; anywhere else
# the same script runs inside a debian container (docker required).
#
# kcov's memory grows with every test it traces: one heavy file alone passes 10 GB. So each test file
# is cut into groups of at most NIGHTSHIFT_COVERAGE_CHUNK tests (default 5), each group runs under
# its own kcov, and kcov merges the parts. A test whose recorded peak fills the group budget runs
# alone. NIGHTSHIFT_COVERAGE_JOBS groups run at a time: as many as fit in the memory left after
# headroom, and never more than one per CPU. The limit is the smaller of host free memory and a
# cgroup limit, when one is set. A group killed for memory is measured again one test at a time,
# with nothing else running. A test
# that still cannot be measured alone, or a group that writes no coverage report or runs a different
# number of tests than it was given, fails the whole run with its file, its tests and the end of its
# log, and so does a merged report that counts no lines: an incomplete measurement is never reported
# as a coverage figure.
#
# Output: coverage/ — kcov HTML, plus two reports with repository-relative paths:
# coverage/cobertura.xml for Codecov and coverage/sonar-generic.xml for SonarQube.
set -euo pipefail
cd "$(dirname "$0")/.."

INCLUDE=plugins/nightshift/hooks,plugins/nightshift/runtime,plugins/nightshift/lib

# A shard run sets NIGHTSHIFT_COVERAGE_ROOT to its own directory. A local run uses coverage/.
COVERAGE_ROOT="${NIGHTSHIFT_COVERAGE_ROOT:-coverage}"
CHUNKS="$COVERAGE_ROOT/chunks.tsv"
# The groups killed in the parallel pass, one line number per line, measured again test by test.
RETRY="$COVERAGE_ROOT/retry.txt"
# The memory one group is planned to reach under kcov. Four groups at once on the 16 GB runner
# left about 1 GB free before the step was killed, so a run keeps this much unused.
GROUP_MB=6000
HEADROOM_MB=2048
PROFILE=tests/coverage-memory.tsv

# test_names <test-file> — every test name in the file as bats matches it, one per line: the text of
# each `@test "..."` line exactly as written, backslashes included.
test_names() {
  sed -n 's/^@test "\(.*\)" {[[:space:]]*$/\1/p' "$1"
}

# ere_escape — standard input with every extended-regex special character escaped.
ere_escape() {
  sed 's#[]\[(){}.*+?^$|\\/]#\\&#g'
}

# add_chunk <test-file> — append one group to $CHUNKS from the test names on standard input, and keep
# those names beside it in coverage/names-<line>.txt.
add_chunk() {
  local group line
  group="$(cat)"
  printf '%s\t%s\t^(%s)$\n' "$1" "$(printf '%s\n' "$group" | grep -c .)" \
    "$(printf '%s\n' "$group" | ere_escape | paste -sd '|' -)" >>"$CHUNKS"
  line="$(grep -c . "$CHUNKS")"
  printf '%s\n' "$group" >"$COVERAGE_ROOT/names-$line.txt"
}

# test_weight <file> <name> — megabytes to plan for one test. A profile row for the name wins,
# then a row for the whole file, then an even share of the group budget.
test_weight() {
  local file="$1" name="$2" star="" exact="" line f n mb
  if [ -f "$PROFILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '' | '#'*) continue ;;
      esac
      IFS=$(printf '\t') read -r f n mb <<<"$line"
      [ "$f" = "$file" ] || continue
      case "$mb" in
        '' | *[!0-9]*) continue ;;
      esac
      if [ "$n" = "$name" ]; then
        exact="$mb"
      elif [ "$n" = '*' ]; then
        star="$mb"
      fi
    done <"$PROFILE"
  fi
  if [ -n "$exact" ]; then
    printf '%s\n' "$exact"
  elif [ -n "$star" ]; then
    printf '%s\n' "$star"
  else
    printf '%s\n' "$UNIT_MB"
  fi
}

# write_chunks — one line per group in $CHUNKS: <test-file> TAB <test count> TAB <bats filter>.
# Tests stay in file order. A group stops before it passes the budget or the chunk cap.
write_chunks() {
  local file names count name weight sum n batch
  : >"$CHUNKS"
  : >"$RETRY"
  while IFS= read -r file; do
    names="$(test_names "$file")"
    count="$(printf '%s\n' "$names" | grep -c . || :)"
    if [ "$count" -ne "$(grep -c '^@test ' "$file")" ]; then
      printf 'coverage: %s has %s @test lines but %s readable test names\n' "$file" "$(grep -c '^@test ' "$file")" "$count" >&2
      return 1
    fi
    sum=0
    n=0
    batch=""
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      weight="$(test_weight "$file" "$name")"
      if [ "$n" -gt 0 ] && { [ $((sum + weight)) -gt "$BUDGET_MB" ] || [ "$n" -ge "$CHUNK" ]; }; then
        printf '%s\n' "$batch" | sed '/^$/d' | add_chunk "$file"
        sum=0
        n=0
        batch=""
      fi
      batch="${batch}${name}"$'\n'
      sum=$((sum + weight))
      n=$((n + 1))
    done <<<"$names"
    if [ "$n" -gt 0 ]; then
      printf '%s\n' "$batch" | sed '/^$/d' | add_chunk "$file"
    fi
  done < <(tests/run-shard.sh 1 1 --list)
}

# The memory a group may use, and how many groups may run. A cgroup limit counts when it is
# tighter than the host. Headroom stays unused. An explicit job count is left alone.
resolve_budget() {
  local host="" cg="" max="" cur="" avail="" usable="" cpus="" root quota period
  root="${NIGHTSHIFT_COVERAGE_CGROUP:-/sys/fs/cgroup}"
  if [ -n "${NIGHTSHIFT_COVERAGE_MEM_MB:-}" ]; then
    host="$NIGHTSHIFT_COVERAGE_MEM_MB"
  else
    host="$(awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' "${NIGHTSHIFT_COVERAGE_MEMINFO:-/proc/meminfo}" 2>/dev/null || true)"
  fi
  if [ -f "$root/memory.max" ]; then
    max="$(tr -d '[:space:]' <"$root/memory.max")"
    cur="$(tr -d '[:space:]' <"$root/memory.current" 2>/dev/null || echo 0)"
  elif [ -f "$root/memory.limit_in_bytes" ]; then
    max="$(tr -d '[:space:]' <"$root/memory.limit_in_bytes")"
    cur="$(tr -d '[:space:]' <"$root/memory.usage_in_bytes" 2>/dev/null || echo 0)"
  fi
  case "$max" in
    '' | max | *[!0-9]*) max="" ;;
  esac
  case "$cur" in
    '' | *[!0-9]*) cur=0 ;;
  esac
  # A limit above a terabyte is the unlimited sentinel.
  if [ -n "$max" ] && [ "$max" -lt 1099511627776 ] && [ "$max" -gt "$cur" ]; then
    cg=$(((max - cur) / 1024 / 1024))
  fi
  avail=""
  if [ -n "$host" ]; then avail="$host"; fi
  if [ -n "$cg" ] && { [ -z "$avail" ] || [ "$cg" -lt "$avail" ]; }; then avail="$cg"; fi
  [ -n "$avail" ] || avail=1024
  AVAIL_MB="$avail"
  usable=$((avail - HEADROOM_MB))
  [ "$usable" -ge 1 ] || usable=1
  if [ "$usable" -lt "$GROUP_MB" ]; then
    BUDGET_MB="$usable"
  else
    BUDGET_MB="$GROUP_MB"
  fi
  UNIT_MB=$((BUDGET_MB / CHUNK))
  [ "$UNIT_MB" -ge 1 ] || UNIT_MB=1
  if [ -z "$JOBS" ]; then
    if [ -n "${NIGHTSHIFT_COVERAGE_CPUS:-}" ]; then
      cpus="$NIGHTSHIFT_COVERAGE_CPUS"
    elif [ -f "$root/cpu.max" ]; then
      read -r quota period <"$root/cpu.max" || true
      case "$quota" in
        '' | max | *[!0-9]*) quota="" ;;
      esac
      case "$period" in
        '' | *[!0-9]* | 0) period="" ;;
      esac
      if [ -n "$quota" ] && [ -n "$period" ]; then
        cpus=$(((quota + period - 1) / period))
      fi
    fi
    [ -n "${cpus:-}" ] || cpus="$(getconf _NPROCESSORS_ONLN)"
    if [ "$usable" -ge "$GROUP_MB" ]; then
      JOBS=$((usable / GROUP_MB))
    else
      JOBS=1
    fi
    [ "$JOBS" -le "$cpus" ] || JOBS="$cpus"
    [ "$JOBS" -ge 1 ] || JOBS=1
  fi
}

# accept_tap <log> <count> — the plan and the terminal results against the group's selection.
# A finished run prints `<failed> <skipped>` and returns 0. A completed failure and a platform
# skip are both terminal results: they are counted apart, and they do not by themselves reject
# the batch. A missing, duplicated or truncated sequence, a plan that is not the selection, or a
# bailout prints the reason and returns 1.
accept_tap() {
  awk -v n="$2" '
    BEGIN { fails = 0; skips = 0 }
    function num(s) { return s + 0 }
    /^1\.\.[0-9]+$/ {
      plans++
      plan = num(substr($0, 4))
      next
    }
    /^Bail out!/ { bail = 1; next }
    /^(ok|not ok) [0-9]+/ {
      split($0, f, " ")
      id = ($1 == "not") ? num(f[3]) : num(f[2])
      if (id < 1 || (id in seen)) dup = 1
      seen[id] = 1
      results++
      if (tolower($0) ~ /# *skip/) skips++
      else if ($1 == "not") fails++
      next
    }
    END {
      if (bail) { print "bailed out"; exit 1 }
      if (plans != 1 || plan != n) { print "plan does not match the selection"; exit 1 }
      missing = 0
      for (i = 1; i <= n; i++) if (!(i in seen)) missing = 1
      if (dup || missing || results != n) { print "results are missing, duplicated or truncated"; exit 1 }
      print fails, skips
    }
  ' "$1"
}

# report_ok <dir> — a cobertura.xml kcov wrote that parses as XML. Status 1 when it is missing
# or not a report.
report_ok() {
  local cob
  cob="$(find "$1" -name cobertura.xml -print -quit 2>/dev/null)" || true
  [ -n "$cob" ] || return 1
  python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$cob"
}

# run_chunk <line> — the group on that line of $CHUNKS under its own kcov, in a session of its own.
# Whatever the group's tests leave running is stopped once kcov exits, and counted, so leftover
# processes cannot pile up across groups. A group of several tests killed by a signal is recorded in
# $RETRY and its partial output removed, to be measured again test by test. Returns 1, after saying
# why on standard error, when a single test was killed, the run wrote no usable coverage report, or
# the TAP plan and the terminal results do not both match the selection. The log is kept. An
# incomplete batch is removed so it cannot be merged into either published report. A failing test
# and a platform skip still count: they are measured, and named apart in the measured line.
run_chunk() {
  local line="$1" file count filter out="$COVERAGE_ROOT/part-$1" log="$COVERAGE_ROOT/part-$1.log" status=0 why=""
  local err="$COVERAGE_ROOT/part-$1.err" name
  local session left free tap_rc=0 summary failed_n=0 skipped_n=0 started elapsed rss="" gnu_time="" candidate
  # The traced tests see none of this run's own settings: a test that drives coverage.sh in a
  # fixture would otherwise write into this run's shard.
  local -a clean=(env)
  while IFS= read -r name; do
    clean+=(-u "$name")
  done < <(compgen -e | grep '^NIGHTSHIFT_COVERAGE_' || :)
  IFS=$'\t' read -r file count filter < <(sed -n "${line}p" "$CHUNKS")
  started="$(date +%s)"
  # setsid executes a program, not a shell keyword. `command time` is the shell's own word, so the
  # session must be given the GNU time binary, and only when that binary records a peak.
  gnu_time=""
  for candidate in /usr/bin/time /bin/time; do
    if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
      gnu_time="$candidate"
      break
    fi
  done
  # Bats writes TAP on standard output. kcov's bash tracer passes lines it does not parse to standard
  # error, among them the rest of a traced multi-line value, which can look like a TAP result. Only
  # standard output is read as TAP.
  if [ -n "$gnu_time" ]; then
    setsid "${clean[@]}" "$gnu_time" -f 'COVERAGE_RSS_KB %M' -o "$out.time" kcov --include-path="$PWD/$INCLUDE" "$out" \
      "$(command -v bats)" --filter "$filter" "$file" >"$log" 2>"$err" &
  else
    setsid "${clean[@]}" kcov --include-path="$PWD/$INCLUDE" "$out" "$(command -v bats)" --filter "$filter" "$file" \
      >"$log" 2>"$err" &
  fi
  session=$!
  wait "$session" || status=$?
  elapsed=$(($(date +%s) - started))
  if [ -f "$out.time" ]; then
    rss="$(awk '/^COVERAGE_RSS_KB / { printf "%d", $2 / 1024 }' "$out.time")"
  fi
  left="$(pgrep -s "$session" | grep -c . || :)"
  [ "$left" -eq 0 ] || pkill -KILL -s "$session" || :
  free="$(awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' "${NIGHTSHIFT_COVERAGE_MEMINFO:-/proc/meminfo}" 2>/dev/null)" || free=unknown
  if [ "$status" -ge 128 ]; then
    why="was killed by signal $((status - 128))"
  elif ! report_ok "$out"; then
    if find "$out" -name cobertura.xml -print -quit 2>/dev/null | grep -q .; then
      why="wrote an invalid coverage report (kcov exit $status)"
    else
      why="wrote no coverage report (kcov exit $status)"
    fi
  else
    summary="$(accept_tap "$log" "$count")" || tap_rc=$?
    if [ "$tap_rc" -ne 0 ]; then
      why="$summary"
    else
      read -r failed_n skipped_n <<<"$summary"
    fi
  fi
  if [ -z "$why" ]; then
    printf 'coverage: measured %s, group %s (%s tests, %s failed, %s skipped, %s leftover processes stopped, %s MB free, %ss' \
      "$file" "$line" "$count" "$failed_n" "$skipped_n" "$left" "$free" "$elapsed"
    if [ -n "$rss" ]; then
      printf ', peak %s MB' "$rss"
    fi
    printf ')\n'
    return 0
  fi
  if [ "$status" -ge 128 ] && [ "$count" -gt 1 ]; then
    rm -rf "$out"
    printf '%s\n' "$line" >>"$RETRY"
    printf 'coverage: %s, group %s %s (%s tests, %ss, %s MB free); its tests are measured again one at a time\n' \
      "$file" "$line" "$why" "$count" "$elapsed" "$free"
    return 0
  fi
  rm -rf "$out"
  {
    printf 'coverage: %s, group %s %s, so its coverage is missing (%s leftover processes stopped, %s MB free)\n' \
      "$file" "$line" "$why" "$left" "$free"
    printf -- '--- tests in the group: %s\n' "$filter"
    printf -- '--- last lines of %s\n' "$log"
    tail -n 25 "$log"
    printf -- '--- last lines of %s\n' "$err"
    tail -n 25 "$err"
  } >&2
  return 1
}

# The parallel runner calls this script back once per group.
if [ "${1:-}" = --chunk ]; then
  run_chunk "$2"
  exit
fi

# Empty means the default, worked out where the measurement runs.
JOBS="${NIGHTSHIFT_COVERAGE_JOBS:-}"
CHUNK="${NIGHTSHIFT_COVERAGE_CHUNK:-5}"
for setting in "NIGHTSHIFT_COVERAGE_JOBS=$JOBS" "NIGHTSHIFT_COVERAGE_CHUNK=$CHUNK"; do
  name="${setting%%=*}"
  value="${setting#*=}"
  [ "$name" = NIGHTSHIFT_COVERAGE_JOBS ] && [ -z "$value" ] && continue
  case "$value" in
    '' | *[!0-9]* | 0)
      printf 'coverage: %s must be a positive whole number, got "%s"\n' "$name" "$value" >&2
      exit 2
      ;;
  esac
done

# publish_coverage <merged-dir> — cobertura.xml and sonar-generic.xml at coverage/.
publish_coverage() {
  local cob lines
  cob="$(find "$1" -name cobertura.xml 2>/dev/null | head -n 1)"
  if [ -z "$cob" ]; then
    printf 'coverage: the merged kcov output in %s has no cobertura.xml\n' "$1" >&2
    return 1
  fi
  lines="$(jq -r '.total_lines' "$(dirname "$cob")/coverage.json")"
  case "$lines" in
    '' | *[!0-9]* | 0)
      printf 'coverage: the merged report counts no lines (total_lines "%s"); nothing was measured\n' "$lines" >&2
      return 1
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

sources = root.find('sources')
if sources is not None:
    for source in list(sources):
        sources.remove(source)
    ET.SubElement(sources, 'source').text = '.'
tree.write('coverage/cobertura.xml', encoding='utf-8', xml_declaration=True)
PY
  jq -r '"coverage: " + .percent_covered + "% of " + (.total_lines|tostring) + " lines"' \
    "$(dirname "$cob")/coverage.json"
}

# merge_coverage — one report from coverage/shard-*/ when those manifests agree.
# shellcheck disable=SC2094
merge_coverage() {
  local expected="" dir commit shard shards result id total="" rest line
  local plan manifests ids groups
  expected="${NIGHTSHIFT_COVERAGE_COMMIT:-}"
  if [ -z "$expected" ]; then
    expected="$(git rev-parse HEAD 2>/dev/null || true)"
  fi
  if [ -z "$expected" ]; then
    printf 'coverage: merge has no commit to compare\n' >&2
    return 1
  fi
  manifests="$(mktemp)"
  ids="$(mktemp)"
  groups="$(mktemp)"
  : >"$manifests"
  : >"$ids"
  : >"$groups"
  for dir in coverage/shard-*; do
    [ -f "$dir/manifest.txt" ] || continue
    printf '%s\n' "$dir" >>"$manifests"
  done
  if [ ! -s "$manifests" ]; then
    printf 'coverage: merge found no shard manifests in coverage/shard-*\n' >&2
    rm -f "$manifests" "$ids" "$groups"
    return 1
  fi
  while IFS= read -r dir; do
    commit="$(awk '$1 == "commit" { print $2 }' "$dir/manifest.txt")"
    shard="$(awk '$1 == "shard" && $2 ~ /^[0-9]+$/ { print $2 }' "$dir/manifest.txt")"
    shards="$(awk '$1 == "shards" { print $2 }' "$dir/manifest.txt")"
    result="$(awk '$1 == "result" { print $2 }' "$dir/manifest.txt")"
    if [ "$commit" != "$expected" ] || [ "$result" != ok ] || [ -z "$shard" ] || [ -z "$shards" ]; then
      printf 'coverage: %s is not a successful manifest for %s\n' "$dir" "$expected" >&2
      rm -f "$manifests" "$ids" "$groups"
      return 1
    fi
    if [ -n "$total" ] && [ "$shards" != "$total" ]; then
      printf 'coverage: %s says %s shards, another says %s\n' "$dir" "$shards" "$total" >&2
      rm -f "$manifests" "$ids" "$groups"
      return 1
    fi
    total="$shards"
    if grep -qx "$shard" "$ids"; then
      printf 'coverage: shard %s is reported more than once\n' "$shard" >&2
      rm -f "$manifests" "$ids" "$groups"
      return 1
    fi
    printf '%s\n' "$shard" >>"$ids"
    awk 'NF && $1 ~ /^[0-9]+$/ { print }' "$dir/manifest.txt" >>"$groups"
  done <"$manifests"
  id=1
  while [ "$id" -le "$total" ]; do
    if ! grep -qx "$id" "$ids"; then
      printf 'coverage: shard %s of %s is missing\n' "$id" "$total" >&2
      rm -f "$manifests" "$ids" "$groups"
      return 1
    fi
    id=$((id + 1))
  done
  plan="$(mktemp -d)"
  COVERAGE_ROOT="$plan"
  CHUNKS="$plan/chunks.tsv"
  RETRY="$plan/retry.txt"
  mkdir -p "$plan"
  resolve_budget
  write_chunks
  while IFS= read -r line; do
    id="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    if [ "$id" != "$(printf '%s\n' "$line" | cut -f1)" ]; then
      printf 'coverage: a shard group line is not the plan\n' >&2
      rm -rf "$plan"
      rm -f "$manifests" "$ids" "$groups"
      return 1
    fi
    if [ "$(sed -n "${id}p" "$CHUNKS")" != "$rest" ]; then
      printf 'coverage: shard group %s does not match the plan\n' "$id" >&2
      rm -rf "$plan"
      rm -f "$manifests" "$ids" "$groups"
      return 1
    fi
    found=0
    while IFS= read -r dir; do
      if [ -d "$dir/part-$id" ]; then found=1; break; fi
    done <"$manifests"
    if [ "$found" -ne 1 ]; then
      printf 'coverage: shard group %s has no report directory\n' "$id" >&2
      rm -rf "$plan"
      rm -f "$manifests" "$ids" "$groups"
      return 1
    fi
  done <"$groups"
  if [ "$(cut -f1 "$groups" | sort | uniq -d | grep -c . || true)" -ne 0 ]; then
    printf 'coverage: a group is listed by more than one shard\n' >&2
    rm -rf "$plan"
    rm -f "$manifests" "$ids" "$groups"
    return 1
  fi
  if [ "$(grep -c . "$groups" || :)" -ne "$(grep -c . "$CHUNKS" || :)" ]; then
    printf 'coverage: shard groups do not cover the plan\n' >&2
    rm -rf "$plan"
    rm -f "$manifests" "$ids" "$groups"
    return 1
  fi
  rm -rf "$plan"
  parts=""
  while IFS= read -r dir; do
    for part in "$dir"/part-*; do
      [ -d "$part" ] || continue
      parts="$parts $part"
    done
  done <"$manifests"
  rm -f "$manifests" "$ids" "$groups"
  # shellcheck disable=SC2086
  if ! kcov --merge coverage/merged $parts; then
    printf 'coverage: kcov could not merge the shard reports\n' >&2
    return 1
  fi
  publish_coverage coverage/merged
}

# in_container [--merge] — this script again inside a debian container that has kcov, for a host
# without it. The container installs as root and runs as the caller's user id. The suite assumes an
# unprivileged user, as on every CI leg: as root, a file made unreadable or unwritable is neither.
in_container() {
  exec docker run --rm -v "$PWD:/src" -w /src \
    -e NIGHTSHIFT_COVERAGE_JOBS="$JOBS" -e NIGHTSHIFT_COVERAGE_CHUNK="$CHUNK" \
    -e NIGHTSHIFT_COVERAGE_SHARD="${NIGHTSHIFT_COVERAGE_SHARD:-}" \
    -e NIGHTSHIFT_COVERAGE_SHARDS="${NIGHTSHIFT_COVERAGE_SHARDS:-}" \
    -e NIGHTSHIFT_COVERAGE_COMMIT="${NIGHTSHIFT_COVERAGE_COMMIT:-}" \
    -e NIGHTSHIFT_COVERAGE_MEM_MB="${NIGHTSHIFT_COVERAGE_MEM_MB:-}" \
    -e NIGHTSHIFT_COVERAGE_CPUS="${NIGHTSHIFT_COVERAGE_CPUS:-}" \
    -e COVERAGE_UID="$(id -u)" \
    debian:stable-slim bash -c '
    set -e
    apt-get update -qq >/dev/null
    apt-get install -y -qq kcov bats git jq shellcheck python3 ruby procps time >/dev/null
    run_coverage() {
      git config --global user.email dev@example.com
      git config --global user.name dev
      git config --global --add safe.directory "*"
      exec bash tests/coverage.sh "$@"
    }
    if [ "$COVERAGE_UID" -eq 0 ]; then
      run_coverage "$@"
    fi
    useradd --create-home --non-unique --uid "$COVERAGE_UID" coverage
    exec runuser -u coverage -- env HOME=/home/coverage bash -c "$(declare -f run_coverage); run_coverage \"\$@\"" _ "$@"' \
    _ "$@"
}

# The merge needs only kcov, on any system; tracing bash also needs Linux.
if [ "${1:-}" = --merge ]; then
  command -v kcov >/dev/null 2>&1 || in_container --merge
  merge_coverage
  exit
fi

if [ "${1:-}" = --plan ]; then
  resolve_budget
  rm -rf coverage
  mkdir -p coverage
  write_chunks
  printf 'coverage: %s test groups, budget %s MB, %s at a time (%s MB available, %s MB headroom)\n' \
    "$(grep -c . "$CHUNKS" || :)" "$BUDGET_MB" "$JOBS" "$AVAIL_MB" "$HEADROOM_MB"
  exit 0
fi

if [ "$(uname -s)" != Linux ] || ! command -v kcov >/dev/null 2>&1; then
  in_container
fi

resolve_budget

shard="${NIGHTSHIFT_COVERAGE_SHARD:-}"
shards="${NIGHTSHIFT_COVERAGE_SHARDS:-}"
if [ -n "$shard" ] || [ -n "$shards" ]; then
  case "$shard$shards" in
    *[!0-9]*)
      printf 'coverage: NIGHTSHIFT_COVERAGE_SHARD and NIGHTSHIFT_COVERAGE_SHARDS must be positive numbers\n' >&2
      exit 2
      ;;
  esac
  if [ "$shard" -lt 1 ] || [ "$shards" -lt 1 ] || [ "$shard" -gt "$shards" ]; then
    printf 'coverage: shard %s is not inside 1..%s\n' "$shard" "$shards" >&2
    exit 2
  fi
  COVERAGE_ROOT="coverage/shard-$shard"
  export NIGHTSHIFT_COVERAGE_ROOT="$COVERAGE_ROOT"
  CHUNKS="$COVERAGE_ROOT/chunks.tsv"
  RETRY="$COVERAGE_ROOT/retry.txt"
  rm -rf "$COVERAGE_ROOT"
else
  rm -rf coverage
fi
mkdir -p "$COVERAGE_ROOT"
write_chunks
groups="$(grep -c . "$CHUNKS" || :)"
printf 'coverage: %s test groups, budget %s MB, %s at a time (%s MB available, %s MB headroom)\n' \
  "$groups" "$BUDGET_MB" "$JOBS" "$AVAIL_MB" "$HEADROOM_MB"

: >"$COVERAGE_ROOT/run-list.txt"
n=0
while IFS= read -r _; do
  n=$((n + 1))
  if [ -z "$shard" ] || [ $(((n - 1) % shards)) -eq $((shard - 1)) ]; then
    printf '%s\n' "$n" >>"$COVERAGE_ROOT/run-list.txt"
  fi
done <"$CHUNKS"

failed=0
if [ -s "$COVERAGE_ROOT/run-list.txt" ]; then
  xargs -n 1 -P "$JOBS" bash tests/coverage.sh --chunk <"$COVERAGE_ROOT/run-list.txt" || failed=1
fi
# Each group killed in the parallel pass, again one test at a time, with the machine to itself.
while IFS= read -r group; do
  file="$(sed -n "${group}p" "$CHUNKS" | cut -f1)"
  while IFS= read -r name; do
    printf '%s\n' "$name" | add_chunk "$file"
    bash tests/coverage.sh --chunk "$(grep -c . "$CHUNKS")" </dev/null || failed=1
  done <"$COVERAGE_ROOT/names-$group.txt"
done <"$RETRY"
if [ -n "$shard" ]; then
  commit="${NIGHTSHIFT_COVERAGE_COMMIT:-$(git rev-parse HEAD)}"
  {
    printf 'commit %s\n' "$commit"
    printf 'shard %s\n' "$shard"
    printf 'shards %s\n' "$shards"
    if [ "$failed" -eq 0 ]; then printf 'result ok\n'; else printf 'result failed\n'; fi
    n=0
    while IFS= read -r row; do
      n=$((n + 1))
      if [ $(((n - 1) % shards)) -eq $((shard - 1)) ]; then
        printf '%s\t%s\n' "$n" "$row"
      fi
    done <"$CHUNKS"
  } >"$COVERAGE_ROOT/manifest.txt"
  if [ "$failed" -ne 0 ]; then
    printf 'coverage: shard %s could not measure every group (see above)\n' "$shard" >&2
    exit 1
  fi
  printf 'coverage: shard %s of %s wrote %s\n' "$shard" "$shards" "$COVERAGE_ROOT"
  exit 0
fi
if [ "$failed" -ne 0 ]; then
  printf 'coverage: one or more test groups could not be measured (see above); no report written\n' >&2
  exit 1
fi

if ! kcov --merge coverage/merged "$COVERAGE_ROOT"/part-*/; then
  printf 'coverage: kcov could not merge the per-group reports in %s/part-*\n' "$COVERAGE_ROOT" >&2
  exit 1
fi
publish_coverage coverage/merged
