#!/usr/bin/env bash
# Run the full bats suite in parallel shards (default 6). Same coverage as bats -r tests/.
# Usage: tests/run-parallel.sh [JOBS]
set -euo pipefail

jobs="${1:-6}"
case "$jobs" in
  *[!0-9]* | '')
    echo "usage: tests/run-parallel.sh [JOBS]" >&2
    exit 2
    ;;
esac
if [ "$jobs" -lt 1 ]; then
  echo "JOBS must be >= 1" >&2
  exit 2
fi

cd "$(dirname "$0")/.."

tmpdir="${TMPDIR:-/tmp}/nightshift-bats-parallel-$$"
command mkdir -p "$tmpdir"
trap 'rm -rf "$tmpdir"' EXIT

failed=0
for s in $(seq 1 "$jobs"); do
  # set +e so a setup failure is recorded. A worker killed before that write leaves no result,
  # which the parent treats as a failure of its own.
  (
    set +e
    export BATS_TMPDIR="$tmpdir/bats-shard-${s}"
    code=0
    {
      command mkdir -p "$BATS_TMPDIR"
      code=$?
      if [ "$code" -eq 0 ]; then
        tests/run-shard.sh "$s" "$jobs"
        code=$?
      fi
    } >"$tmpdir/shard-${s}.log" 2>&1
    printf '%s\n' "$code" >"$tmpdir/shard-${s}.exit"
    exit "$code"
  ) &
  printf '%s\n' "$!" >"$tmpdir/shard-${s}.pid"
done

for s in $(seq 1 "$jobs"); do
  pid="$(cat "$tmpdir/shard-${s}.pid")"
  status=0
  wait "$pid" || status=$?
  result=""
  if [ -f "$tmpdir/shard-${s}.exit" ]; then
    result="$(tr -d '[:space:]' <"$tmpdir/shard-${s}.exit")"
  fi
  if [ -z "$result" ] || [ "$status" -ne 0 ] || [ "$result" -ne 0 ]; then
    failed=1
    echo "=== shard $s/$jobs FAILED (worker $pid exit ${status}, result ${result:-missing}) ===" >&2
    if [ -s "$tmpdir/shard-${s}.log" ]; then
      cat "$tmpdir/shard-${s}.log" >&2
    else
      echo "shard $s: no log" >&2
    fi
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "all $jobs shards passed" >&2
