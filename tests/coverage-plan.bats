#!/usr/bin/env bats
# Group planning follows the memory limit and the recorded peaks. These fixtures
# do not trace anything.

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/tests" "$ROOT/plugins/nightshift"
  cp "$BATS_TEST_DIRNAME/coverage.sh" "$ROOT/tests/coverage.sh"
  cat >"$ROOT/tests/run-shard.sh" <<'EOF'
#!/bin/bash
printf '%s\n' tests/light.bats tests/status.bats
EOF
  chmod +x "$ROOT/tests/run-shard.sh"
  at='@test'
  {
    printf '%s\n' "$at \"one\" {" 'true' '}'
    printf '%s\n' "$at \"two\" {" 'true' '}'
    printf '%s\n' "$at \"three\" {" 'true' '}'
    printf '%s\n' "$at \"four\" {" 'true' '}'
    printf '%s\n' "$at \"five\" {" 'true' '}'
    printf '%s\n' "$at \"six\" {" 'true' '}'
  } >"$ROOT/tests/light.bats"
  {
    printf '%s\n' "$at \"alpha\" {" 'true' '}'
    printf '%s\n' "$at \"beta\" {" 'true' '}'
    printf '%s\n' "$at \"gamma\" {" 'true' '}'
  } >"$ROOT/tests/status.bats"
  printf 'tests/status.bats\t*\t6000\n' >"$ROOT/tests/coverage-memory.tsv"
}

plan() {
  (
    cd "$ROOT" && env \
      NIGHTSHIFT_COVERAGE_MEM_MB="$1" \
      NIGHTSHIFT_COVERAGE_CPUS="$2" \
      NIGHTSHIFT_COVERAGE_CGROUP="${3:-}" \
      NIGHTSHIFT_COVERAGE_MEMINFO="${4:-}" \
      bash tests/coverage.sh --plan
  )
}

@test "a full budget keeps light groups at five and isolates the heavy file" {
  run plan 16000 4
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'budget 6000 MB, 2 at a time (16000 MB available, 2048 MB headroom)'
  [ "$(awk -F '\t' '$1 == "tests/light.bats" { print $2 }' "$ROOT/coverage/chunks.tsv" | tr '\n' ' ')" = "5 1 " ]
  [ "$(awk -F '\t' '$1 == "tests/status.bats" { print $2 }' "$ROOT/coverage/chunks.tsv" | tr '\n' ' ')" = "1 1 1 " ]
  grep -q 'alpha' "$ROOT/coverage/names-3.txt"
}

@test "a tight limit shrinks the budget and runs one group at a time" {
  run plan 7000 8
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'budget 4952 MB, 1 at a time (7000 MB available, 2048 MB headroom)'
  [ "$(awk -F '\t' '$1 == "tests/light.bats" { print $2 }' "$ROOT/coverage/chunks.tsv" | tr '\n' ' ')" = "5 1 " ]
  [ "$(awk -F '\t' '$1 == "tests/status.bats" { print $2 }' "$ROOT/coverage/chunks.tsv" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "a cgroup limit tighter than host memory is the one that is planned against" {
  mkdir -p "$BATS_TEST_TMPDIR/cgroup"
  printf '8589934592\n' >"$BATS_TEST_TMPDIR/cgroup/memory.max"
  printf '1073741824\n' >"$BATS_TEST_TMPDIR/cgroup/memory.current"
  printf '200000 100000\n' >"$BATS_TEST_TMPDIR/cgroup/cpu.max"
  printf 'MemAvailable: 20000000 kB\n' >"$BATS_TEST_TMPDIR/meminfo"
  run plan '' '' "$BATS_TEST_TMPDIR/cgroup" "$BATS_TEST_TMPDIR/meminfo"
  [ "$status" -eq 0 ]
  # 8 GiB minus 1 GiB is 7168 MB, then 2048 MB headroom leaves a 5120 MB budget and one job.
  printf '%s\n' "$output" | grep -q 'budget 5120 MB, 1 at a time (7168 MB available, 2048 MB headroom)'
}

@test "the shipped profile isolates every status test" {
  grep -q '^tests/status.bats	\*	6000$' "$BATS_TEST_DIRNAME/coverage-memory.tsv"
}
