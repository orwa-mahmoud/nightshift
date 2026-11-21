#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  TIMINGS="$REPO_ROOT/tests/shard-timings"
}

combined() { printf '%s\n%s\n' "$output" "$stderr"; }

# list_shards <platform> <timings-dir> <file-list>
list_shards() {
  local platform="$1" timings="$2" files="$3" s shard_files
  : >"$BATS_TEST_TMPDIR/merged"
  for s in 1 2 3 4 5 6; do
    shard_files="$(
      NIGHTSHIFT_SHARD_PLATFORM="$platform" \
        NIGHTSHIFT_SHARD_TIMINGS="$timings" \
        NIGHTSHIFT_SHARD_FILES="$files" \
        "$REPO_ROOT/tests/run-shard.sh" "$s" 6 --list
    )"
    printf '%s\n' "$shard_files" >>"$BATS_TEST_TMPDIR/merged"
  done
  sed '/^$/d' "$BATS_TEST_TMPDIR/merged"
}

report_of() {
  local platform="$1" timings="$2" files="$3"
  NIGHTSHIFT_SHARD_PLATFORM="$platform" \
    NIGHTSHIFT_SHARD_TIMINGS="$timings" \
    NIGHTSHIFT_SHARD_FILES="$files" \
    "$REPO_ROOT/tests/run-shard.sh" 1 6 --balance-report
}

paths_of() {
  awk -F '\t' '$0 !~ /^#/ && NF { print $1 }' "$1" | LC_ALL=C sort
}

@test "linux and macos shards each contain every bats file once" {
  local platform all merged
  all="$(cd "$REPO_ROOT" && find tests -name '*.bats' | LC_ALL=C sort)"
  [ -n "$all" ]
  for platform in linux macos; do
    merged=""
    local s shard_files
    for s in 1 2 3 4 5 6; do
      shard_files="$(
        cd "$REPO_ROOT" && NIGHTSHIFT_SHARD_PLATFORM="$platform" \
          "$REPO_ROOT/tests/run-shard.sh" "$s" 6 --list
      )"
      [ -n "$shard_files" ]
      merged="${merged}${shard_files}"$'\n'
    done
    [ "$(printf '%s\n' "$all" | wc -l | tr -d ' ')" -eq "$(printf '%s\n' "$merged" | sed '/^$/d' | wc -l | tr -d ' ')" ]
    diff -u <(printf '%s\n' "$all") <(printf '%s\n' "$merged" | sed '/^$/d' | LC_ALL=C sort) \
      || { echo "$platform partition broke"; return 1; }
  done
}

@test "one shard lists the coverage inventory in path order" {
  local platform listed
  grep -q 'tests/run-shard.sh 1 1 --list' "$REPO_ROOT/tests/coverage.sh"
  for platform in linux macos; do
    listed="$(
      cd "$REPO_ROOT" && NIGHTSHIFT_SHARD_PLATFORM="$platform" \
        "$REPO_ROOT/tests/run-shard.sh" 1 1 --list
    )"
    diff -u <(cd "$REPO_ROOT" && find tests -name '*.bats' | LC_ALL=C sort) <(printf '%s\n' "$listed") \
      || { echo "$platform inventory broke"; return 1; }
  done
}

@test "the same file list is packed the same way twice" {
  local platform first second
  for platform in linux macos; do
    first="$(cd "$REPO_ROOT" && NIGHTSHIFT_SHARD_PLATFORM="$platform" "$REPO_ROOT/tests/run-shard.sh" 1 6 --list)"
    second="$(cd "$REPO_ROOT" && NIGHTSHIFT_SHARD_PLATFORM="$platform" "$REPO_ROOT/tests/run-shard.sh" 1 6 --list)"
    [ "$first" = "$second" ]
  done
}

@test "run-shard rejects out-of-range shard numbers" {
  run bash "$REPO_ROOT/tests/run-shard.sh" 0 6 --list
  [ "$status" -eq 2 ]
  run bash "$REPO_ROOT/tests/run-shard.sh" 7 6 --list
  [ "$status" -eq 2 ]
  run bash "$REPO_ROOT/tests/run-shard.sh" 1 6 --nope
  [ "$status" -eq 2 ]
}

@test "the six shard check names still call this runner" {
  local wf="$REPO_ROOT/.github/workflows/ci.yaml"
  grep -q '^  bats:' "$wf"
  grep -q '^  bats-macos:' "$wf"
  [ "$(grep -c 'shard: \[1, 2, 3, 4, 5, 6\]' "$wf")" -eq 2 ]
  [ "$(grep -c 'tests/run-shard.sh "${{ matrix.shard }}" 6' "$wf")" -eq 2 ]
}

@test "weights separate two heavy files that round-robin stacks" {
  local dir files report
  dir="$BATS_TEST_TMPDIR/heavy"
  mkdir -p "$dir"
  files="$dir/files.txt"
  printf '%s\n' tests/a.bats tests/b.bats tests/c.bats tests/d.bats tests/e.bats tests/f.bats tests/g.bats >"$files"
  # No samples: equal weights, and the two heavy names share a round-robin shard.
  mkdir -p "$dir/empty"
  [ "$(NIGHTSHIFT_SHARD_PLATFORM=macos NIGHTSHIFT_SHARD_TIMINGS="$dir/empty" NIGHTSHIFT_SHARD_FILES="$files" \
    "$REPO_ROOT/tests/run-shard.sh" 1 6 --list | tr '\n' ' ')" = "tests/a.bats tests/g.bats " ]
  cat >"$dir/macos.tsv" <<'EOF'
tests/a.bats	1000
tests/b.bats	10
tests/c.bats	10
tests/d.bats	10
tests/e.bats	10
tests/f.bats	10
tests/g.bats	1000
EOF
  [ "$(NIGHTSHIFT_SHARD_PLATFORM=macos NIGHTSHIFT_SHARD_TIMINGS="$dir" NIGHTSHIFT_SHARD_FILES="$files" \
    "$REPO_ROOT/tests/run-shard.sh" 1 6 --list)" = "tests/a.bats" ]
  [ "$(NIGHTSHIFT_SHARD_PLATFORM=macos NIGHTSHIFT_SHARD_TIMINGS="$dir" NIGHTSHIFT_SHARD_FILES="$files" \
    "$REPO_ROOT/tests/run-shard.sh" 2 6 --list)" = "tests/g.bats" ]
  report="$(report_of macos "$dir" "$files")"
  printf '%s\n' "$report" | grep -qx 'packed_longest 1000'
  printf '%s\n' "$report" | grep -qx 'round_robin_longest 2000'
}

@test "a new file takes the median weight and a deleted file leaves the schedule" {
  local dir files report once s line
  dir="$BATS_TEST_TMPDIR/edit"
  mkdir -p "$dir"
  cat >"$dir/macos.tsv" <<'EOF'
tests/a.bats	1000
tests/b.bats	10
tests/c.bats	10
tests/d.bats	10
tests/e.bats	10
tests/f.bats	10
tests/g.bats	1000
tests/gone.bats	9999
EOF
  files="$dir/files.txt"
  printf '%s\n' tests/a.bats tests/b.bats tests/c.bats tests/d.bats tests/e.bats tests/f.bats tests/g.bats tests/new.bats >"$files"
  report="$(report_of macos "$dir" "$files")"
  printf '%s\n' "$report" | grep -qx 'weight tests/new.bats 10'
  printf '%s\n' "$report" | grep -qx 'weight tests/gone.bats 9999' && return 1
  once=0
  for s in 1 2 3 4 5 6; do
    while IFS= read -r line; do
      [ "$line" = "tests/new.bats" ] && once=$((once + 1))
      [ "$line" = "tests/gone.bats" ] && return 1
    done <<EOF
$(NIGHTSHIFT_SHARD_PLATFORM=macos NIGHTSHIFT_SHARD_TIMINGS="$dir" NIGHTSHIFT_SHARD_FILES="$files" \
  "$REPO_ROOT/tests/run-shard.sh" "$s" 6 --list)
EOF
  done
  [ "$once" -eq 1 ]

  printf '%s\n' tests/a.bats tests/c.bats tests/d.bats tests/e.bats tests/f.bats tests/g.bats tests/new.bats >"$files"
  once=0
  for s in 1 2 3 4 5 6; do
    while IFS= read -r line; do
      [ "$line" = "tests/b.bats" ] && once=$((once + 1))
    done <<EOF
$(NIGHTSHIFT_SHARD_PLATFORM=macos NIGHTSHIFT_SHARD_TIMINGS="$dir" NIGHTSHIFT_SHARD_FILES="$files" \
  "$REPO_ROOT/tests/run-shard.sh" "$s" 6 --list)
EOF
  done
  [ "$once" -eq 0 ]
  diff -u <(LC_ALL=C sort "$files") <(list_shards macos "$dir" "$files" | LC_ALL=C sort)
}

@test "replaying stored profiles reports the schedule before any hosted comparison" {
  local dir files report
  dir="$BATS_TEST_TMPDIR/replay"
  mkdir -p "$dir"

  # One run's samples, that run's files. The numbers are the replay of the
  # stored logs, not a measurement from a runner.
  files="$dir/files-249.txt"
  paths_of "$TIMINGS/macos-249.tsv" >"$files"
  cp "$TIMINGS/macos-249.tsv" "$dir/macos-249.tsv"
  report="$(report_of macos "$dir" "$files")"
  printf '%s\n' "$report" | grep -qx 'packed_longest 1900'
  printf '%s\n' "$report" | grep -qx 'round_robin_longest 2780'

  rm -f "$dir/macos-249.tsv"
  paths_of "$TIMINGS/macos-248.tsv" >"$files"
  cp "$TIMINGS/macos-248.tsv" "$dir/macos-248.tsv"
  report="$(report_of macos "$dir" "$files")"
  printf '%s\n' "$report" | grep -qx 'packed_longest 1857'
  printf '%s\n' "$report" | grep -qx 'round_robin_longest 2533'

  rm -f "$dir/macos-248.tsv"
  paths_of "$TIMINGS/linux-249.tsv" >"$files"
  cp "$TIMINGS/linux-249.tsv" "$dir/linux-249.tsv"
  report="$(report_of linux "$dir" "$files")"
  printf '%s\n' "$report" | grep -qx 'packed_longest 999'
  printf '%s\n' "$report" | grep -qx 'round_robin_longest 1561'

  rm -f "$dir/linux-249.tsv"
  paths_of "$TIMINGS/linux-248.tsv" >"$files"
  cp "$TIMINGS/linux-248.tsv" "$dir/linux-248.tsv"
  report="$(report_of linux "$dir" "$files")"
  printf '%s\n' "$report" | grep -qx 'packed_longest 924'
  printf '%s\n' "$report" | grep -qx 'round_robin_longest 1357'

  # Costs learned from one run, scored against the other run's file list.
  rm -f "$dir"/linux-*.tsv "$dir"/macos-*.tsv
  paths_of "$TIMINGS/macos-249.tsv" >"$files"
  cp "$TIMINGS/macos-248.tsv" "$dir/macos-248.tsv"
  report="$(report_of macos "$dir" "$files")"
  printf '%s\n' "$report" | grep -qx 'packed_longest 1857'
  paths_of "$TIMINGS/linux-248.tsv" >"$files"
  rm -f "$dir"/macos-*.tsv
  cp "$TIMINGS/linux-249.tsv" "$dir/linux-249.tsv"
  report="$(report_of linux "$dir" "$files")"
  printf '%s\n' "$report" | grep -qx 'packed_longest 999'

  # Both samples: the weight is the median, and the two slowest files split.
  rm -f "$dir"/linux-*.tsv "$dir"/macos-*.tsv
  cp "$TIMINGS/macos-248.tsv" "$TIMINGS/macos-249.tsv" "$dir/"
  paths_of "$TIMINGS/macos-249.tsv" >"$files"
  report="$(report_of macos "$dir" "$files")"
  printf '%s\n' "$report" | grep -qx 'packed_longest 1873'
  printf '%s\n' "$report" | grep -qx 'weight tests/doctor.bats 1307'
  printf '%s\n' "$report" | grep -qx 'weight tests/status.bats 1101'
  [ "$(NIGHTSHIFT_SHARD_PLATFORM=macos NIGHTSHIFT_SHARD_TIMINGS="$dir" NIGHTSHIFT_SHARD_FILES="$files" \
    "$REPO_ROOT/tests/run-shard.sh" 1 6 --list | grep -c -x -e 'tests/doctor.bats' -e 'tests/status.bats')" -eq 1 ]
  [ "$(NIGHTSHIFT_SHARD_PLATFORM=macos NIGHTSHIFT_SHARD_TIMINGS="$dir" NIGHTSHIFT_SHARD_FILES="$files" \
    "$REPO_ROOT/tests/run-shard.sh" 2 6 --list | grep -c -x -e 'tests/doctor.bats' -e 'tests/status.bats')" -eq 1 ]
}

@test "a shard run records every file and still reports a failure" {
  local tmp bin
  tmp="$BATS_TEST_TMPDIR/exec"
  bin="$tmp/bin"
  mkdir -p "$bin" "$tmp/timings"
  cat >"$bin/bats" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >>"$BATS_SEEN"
if [ "$1" = "tests/a.bats" ]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$bin/bats"
  printf '%s\n' tests/a.bats tests/b.bats >"$tmp/files.txt"
  run env PATH="$bin:$PATH" \
    BATS_SEEN="$tmp/seen" \
    NIGHTSHIFT_SHARD_PLATFORM=linux \
    NIGHTSHIFT_SHARD_TIMINGS="$tmp/timings" \
    NIGHTSHIFT_SHARD_FILES="$tmp/files.txt" \
    NIGHTSHIFT_CLASSIFIED_AT=1 \
    "$REPO_ROOT/tests/run-shard.sh" 1 1
  [ "$status" -eq 1 ]
  combined | grep -q '  tests/a.bats '
  combined | grep -q '  tests/b.bats '
  combined | grep -q 'shard 1/1: 2 file(s), platform linux, work '
  combined | grep -q ', wall '
  combined | grep -q ', before_work '
  [ "$(wc -l <"$tmp/seen" | tr -d ' ')" -eq 2 ]
  grep -q 'tests/a.bats' "$tmp/timings/observed/linux-shard-1.tsv"
  grep -q 'tests/b.bats' "$tmp/timings/observed/linux-shard-1.tsv"
}
