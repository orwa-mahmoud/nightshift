#!/usr/bin/env bats
# The coverage group runner accepts a batch only when the TAP plan and the terminal results both
# match the selection. These replay that runner with stub kcov and bats, and look at its exit
# status and whether the group's report was kept.

load helpers

ROOT=""

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/tests" "$ROOT/bin" "$ROOT/coverage"
  cp "$BATS_TEST_DIRNAME/coverage.sh" "$ROOT/tests/coverage.sh"
  cat >"$ROOT/bin/setsid" <<'EOF'
#!/bin/bash
exec "$@"
EOF
  cat >"$ROOT/bin/kcov" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    --include-path) shift 2 ;;
    --include-path=*) shift ;;
    *) break ;;
  esac
done
out="$1"
shift
mkdir -p "$out"
case "${COVERAGE_REPORT:-ok}" in
  missing) ;;
  invalid) printf 'not xml\n' >"$out/cobertura.xml" ;;
  *) printf '<coverage line-rate="1"/>\n' >"$out/cobertura.xml" ;;
esac
exec "$@"
EOF
  cat >"$ROOT/bin/bats" <<'EOF'
#!/bin/bash
cat "${COVERAGE_TAP:?}"
exit "${COVERAGE_STATUS:-0}"
EOF
  chmod +x "$ROOT/bin/setsid" "$ROOT/bin/kcov" "$ROOT/bin/bats"
}

# run_one <count> <tap> — one group, the stub's TAP, the runner's own exit.
run_one() {
  local count="$1" tap="$2"
  printf 'tests/sample.bats\t%s\t^(sample)$\n' "$count" >"$ROOT/coverage/chunks.tsv"
  printf '%s\n' "$tap" >"$ROOT/coverage/tap.txt"
  export COVERAGE_TAP="$ROOT/coverage/tap.txt"
  run env PATH="$ROOT/bin:$PATH" COVERAGE_TAP="$COVERAGE_TAP" COVERAGE_STATUS="${COVERAGE_STATUS:-0}" \
    COVERAGE_REPORT="${COVERAGE_REPORT:-ok}" bash "$ROOT/tests/coverage.sh" --chunk 1
}

combined() { printf '%s\n%s\n' "$output" "$stderr"; }

@test "a complete batch is measured and its report is kept" {
  COVERAGE_STATUS=0 COVERAGE_REPORT=ok
  run_one 2 $'1..2\nok 1\nok 2'
  [ "$status" -eq 0 ]
  combined | grep -q '0 failed, 0 skipped'
  [ -f "$ROOT/coverage/part-1/cobertura.xml" ]
}

@test "a platform skip is measured apart from a failure" {
  COVERAGE_STATUS=0 COVERAGE_REPORT=ok
  run_one 2 $'1..2\nok 1\nok 2 # skip no pwsh on this platform'
  [ "$status" -eq 0 ]
  combined | grep -q '0 failed, 1 skipped'
  [ -f "$ROOT/coverage/part-1/cobertura.xml" ]
}

@test "a completed failure is measured and is not a missing result" {
  COVERAGE_STATUS=1 COVERAGE_REPORT=ok
  run_one 2 $'1..2\nok 1\nnot ok 2'
  [ "$status" -eq 0 ]
  combined | grep -q '1 failed, 0 skipped'
  [ -f "$ROOT/coverage/part-1/cobertura.xml" ]
}

@test "a plan with no terminal results is not measured" {
  COVERAGE_STATUS=0 COVERAGE_REPORT=ok
  run_one 5 $'1..5'
  [ "$status" -eq 1 ]
  combined | grep -q 'results are missing, duplicated or truncated'
  [ ! -e "$ROOT/coverage/part-1/cobertura.xml" ]
  [ -f "$ROOT/coverage/part-1.log" ]
}

@test "a truncated result sequence is not measured" {
  COVERAGE_STATUS=0 COVERAGE_REPORT=ok
  run_one 5 $'1..5\nok 1'
  [ "$status" -eq 1 ]
  combined | grep -q 'results are missing, duplicated or truncated'
  [ ! -e "$ROOT/coverage/part-1/cobertura.xml" ]
  [ -f "$ROOT/coverage/part-1.log" ]
}

@test "a duplicated result number is not measured" {
  COVERAGE_STATUS=0 COVERAGE_REPORT=ok
  run_one 2 $'1..2\nok 1\nok 1'
  [ "$status" -eq 1 ]
  combined | grep -q 'results are missing, duplicated or truncated'
  [ ! -e "$ROOT/coverage/part-1/cobertura.xml" ]
}

@test "a killed group of several tests is measured again one at a time" {
  COVERAGE_STATUS=137 COVERAGE_REPORT=ok
  run_one 5 $'1..5\nok 1\nok 2\nok 3\nok 4\nok 5'
  [ "$status" -eq 0 ]
  combined | grep -q 'signal 9'
  combined | grep -q 'one at a time'
  [ ! -e "$ROOT/coverage/part-1/cobertura.xml" ]
  [ -f "$ROOT/coverage/part-1.log" ]
  [ "$(tr -d '[:space:]' <"$ROOT/coverage/retry.txt")" = 1 ]
}

@test "a group killed by a signal keeps the log and not the report" {
  COVERAGE_STATUS=130 COVERAGE_REPORT=ok
  run_one 1 $'1..1\nok 1'
  [ "$status" -eq 1 ]
  combined | grep -q 'killed by signal'
  [ ! -e "$ROOT/coverage/part-1/cobertura.xml" ]
  [ -f "$ROOT/coverage/part-1.log" ]
}

@test "an invalid coverage report is not measured" {
  COVERAGE_STATUS=0 COVERAGE_REPORT=invalid
  run_one 1 $'1..1\nok 1'
  [ "$status" -eq 1 ]
  combined | grep -q 'invalid coverage report'
  [ ! -e "$ROOT/coverage/part-1/cobertura.xml" ]
  [ -f "$ROOT/coverage/part-1.log" ]
}
