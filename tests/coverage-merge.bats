#!/usr/bin/env bats
# A coverage merge accepts one complete set of shard manifests and rejects a
# missing, duplicate, or mismatched shard. The tracer is a stub.

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/tests" "$ROOT/bin" "$ROOT/plugins/nightshift"
  cp "$BATS_TEST_DIRNAME/coverage.sh" "$ROOT/tests/coverage.sh"
  cat >"$ROOT/tests/run-shard.sh" <<'EOF'
#!/bin/bash
printf '%s\n' tests/a.bats tests/b.bats
EOF
  chmod +x "$ROOT/tests/run-shard.sh"
  at='@test'
  printf '%s\n' "$at \"alpha\" {" 'true' '}' >"$ROOT/tests/a.bats"
  printf '%s\n' "$at \"beta\" {" 'true' '}' >"$ROOT/tests/b.bats"
  cat >"$ROOT/bin/kcov" <<'EOF'
#!/bin/bash
[ "$1" = --merge ] || exit 1
mkdir -p "$2"
printf '%s\n' '<coverage version="1"><sources></sources><packages><package><classes><class filename="lib/a.sh"><lines><line number="1" hits="1"/></lines></class></classes></package></packages></coverage>' >"$2/cobertura.xml"
printf '%s\n' '{"total_lines":1,"percent_covered":"100"}' >"$2/coverage.json"
exit 0
EOF
  chmod +x "$ROOT/bin/kcov"
  git -C "$ROOT" init -q
  git -C "$ROOT" config user.email dev@example.com
  git -C "$ROOT" config user.name dev
  git -C "$ROOT" add tests
  git -C "$ROOT" commit -q -m init
  COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
}

lay() {
  (
    cd "$ROOT" && env NIGHTSHIFT_COVERAGE_MEM_MB=16000 NIGHTSHIFT_COVERAGE_CPUS=2 \
      bash tests/coverage.sh --plan >/dev/null
  )
  rm -rf "$ROOT/coverage/shard-1" "$ROOT/coverage/shard-2" "$ROOT/coverage/shard-1b"
  mkdir -p "$ROOT/coverage/shard-1" "$ROOT/coverage/shard-2"
  n=0
  while IFS= read -r row; do
    n=$((n + 1))
    if [ $(((n - 1) % 2)) -eq 0 ]; then dest="$ROOT/coverage/shard-1"; else dest="$ROOT/coverage/shard-2"; fi
    printf '%s\t%s\n' "$n" "$row" >>"$dest/groups.txt"
    mkdir -p "$dest/part-$n"
  done <"$ROOT/coverage/chunks.tsv"
  for spec in "1:$ROOT/coverage/shard-1" "2:$ROOT/coverage/shard-2"; do
    id="${spec%%:*}"
    dir="${spec#*:}"
    {
      printf 'commit %s\n' "$COMMIT"
      printf 'shard %s\n' "$id"
      printf 'shards 2\n'
      printf 'result ok\n'
      if [ -f "$dir/groups.txt" ]; then cat "$dir/groups.txt"; fi
    } >"$dir/manifest.txt"
  done
}

merge_run() {
  run env PATH="$ROOT/bin:$PATH" bash "$ROOT/tests/coverage.sh" --merge
}

@test "the workflow traces two shards and merges them before upload" {
  wf="$BATS_TEST_DIRNAME/../.github/workflows/coverage.yml"
  grep -q 'shard: \[1, 2\]' "$wf"
  grep -q 'NIGHTSHIFT_COVERAGE_SHARDS: 2' "$wf"
  grep -q 'tests/coverage.sh --merge' "$wf"
  grep -q 'coverage/cobertura.xml' "$wf"
}

@test "two shards merge into one cobertura report and one sonar report" {
  lay
  cd "$ROOT"
  merge_run
  [ "$status" -eq 0 ]
  [ -f "$ROOT/coverage/cobertura.xml" ]
  [ -f "$ROOT/coverage/sonar-generic.xml" ]
  grep -q 'lib/a.sh' "$ROOT/coverage/sonar-generic.xml"
}

@test "a missing shard fails the merge" {
  lay
  rm -rf "$ROOT/coverage/shard-2"
  cd "$ROOT"
  merge_run
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" "$stderr" | grep -q 'shard 2 of 2 is missing'
}

@test "a duplicate shard fails the merge" {
  lay
  mkdir -p "$ROOT/coverage/shard-1b"
  cp "$ROOT/coverage/shard-1/manifest.txt" "$ROOT/coverage/shard-1b/manifest.txt"
  cd "$ROOT"
  merge_run
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" "$stderr" | grep -q 'shard 1 is reported more than once'
}

@test "a shard whose groups are not the plan fails the merge" {
  lay
  printf '9\ttests/a.bats\t1\t^(nope)$\n' >>"$ROOT/coverage/shard-1/manifest.txt"
  cd "$ROOT"
  merge_run
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" "$stderr" | grep -q 'does not match the plan'
}

@test "a host without kcov merges inside the kcov container" {
  if command -v kcov >/dev/null 2>&1; then
    skip "kcov is installed on this host"
  fi
  rm "$ROOT/bin/kcov"
  cat >"$ROOT/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$DOCKER_ARGS"
STUB
  chmod +x "$ROOT/bin/docker"
  cd "$ROOT"
  run env PATH="$ROOT/bin:$PATH" DOCKER_ARGS="$BATS_TEST_TMPDIR/docker-args" \
    bash "$ROOT/tests/coverage.sh" --merge
  [ "$status" -eq 0 ]
  [[ $output != *'kcov: command not found'* ]] || false
  grep -qx 'debian:stable-slim' "$BATS_TEST_TMPDIR/docker-args"
  [ "$(tail -n 1 "$BATS_TEST_TMPDIR/docker-args")" = --merge ]
}
