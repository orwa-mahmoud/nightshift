#!/usr/bin/env bats
# The parallel runner has to notice every shard, including one that dies before its test command
# and one that leaves no result behind.

load helpers

ROOT=""

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/tests" "$ROOT/bin"
  cp "$BATS_TEST_DIRNAME/run-parallel.sh" "$ROOT/tests/run-parallel.sh"
  cat >"$ROOT/bin/mkdir" <<'EOF'
#!/bin/bash
if [ "${FAIL_SHARD1_MKDIR:-}" = 1 ]; then
  for arg in "$@"; do
    if printf '%s\n' "$arg" | grep -q 'bats-shard-1$'; then
      echo "mkdir: cannot create $arg" >&2
      exit 1
    fi
  done
fi
exec /bin/mkdir "$@"
EOF
  chmod +x "$ROOT/bin/mkdir"
}

install_shard() {
  cat >"$ROOT/tests/run-shard.sh"
  chmod +x "$ROOT/tests/run-shard.sh"
}

@test "two green shards pass" {
  install_shard <<'EOF'
#!/bin/bash
echo "shard $1 of $2 ok"
exit 0
EOF
  run bash "$ROOT/tests/run-parallel.sh" 2
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" "$stderr" | grep -q 'all 2 shards passed'
}

@test "a failing shard fails the parent and shows its log" {
  install_shard <<'EOF'
#!/bin/bash
if [ "$1" = 1 ]; then
  echo "shard 1 blew up"
  exit 1
fi
exit 0
EOF
  run bash "$ROOT/tests/run-parallel.sh" 2
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" "$stderr" | grep -q 'shard 1/2 FAILED'
  printf '%s\n' "$output" "$stderr" | grep -q 'shard 1 blew up'
}

@test "a shard that cannot create its directory fails the parent" {
  install_shard <<'EOF'
#!/bin/bash
echo "shard $1 ran"
exit 0
EOF
  run env PATH="$ROOT/bin:$PATH" FAIL_SHARD1_MKDIR=1 bash "$ROOT/tests/run-parallel.sh" 2
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" "$stderr" | grep -q 'shard 1/2 FAILED'
  printf '%s\n' "$output" "$stderr" | grep -q 'cannot create'
}

@test "a shard that leaves no result fails the parent" {
  install_shard <<'EOF'
#!/bin/bash
if [ "$1" = 1 ]; then
  kill -9 "$PPID"
fi
echo "shard $1 ran"
exit 0
EOF
  run bash "$ROOT/tests/run-parallel.sh" 2
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" "$stderr" | grep -q 'result missing'
}
