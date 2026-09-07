#!/usr/bin/env bats
# One verb per helper, and the runtime picking the file, the flags and the workspace.
#
# Skills carried every command in two or three spellings, and the model read all of them on every
# host. No host loads a skill per platform, so the per-host command file is made executable
# instead: these hold what the dispatcher is allowed to decide, and what it must leave alone.

load helpers

RT="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime"
NS="$RT/ns"
NSPS="$RT/windows/ns.ps1"

ps_ready() {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
}

# canon <path> — the workspace as the resolver reports it. On macOS the temp root is a symlink,
# and every Nightshift resolver answers with the real path.
canon() { (cd -P "$1" && pwd); }

# on <host> <project> [args…] — the dispatcher, with only that host's environment set.
on() {
  local host="$1" project="$2"
  shift 2
  env -u CLAUDE_PROJECT_DIR -u CLAUDECODE -u CLAUDE_PLUGIN_ROOT \
    -u CODEX_PROJECT_DIR -u CODEX_HOME -u CODEX_SANDBOX \
    -u CURSOR_PROJECT_DIR -u CURSOR_PLUGIN_ROOT -u CURSOR_TRACE_ID \
    "NIGHTSHIFT_HOST=$host" "CLAUDE_PROJECT_DIR=$project" "$NS" "$@"
}

@test "bind prints the five resolved facts" {
  p="$(new_project ns-bind)"
  run on claude "$p" bind
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 5 ]
  printf '%s\n' "$output" | grep -q "^NIGHTSHIFT_WORKSPACE	$(canon "$p")$"
  printf '%s\n' "$output" | grep -q "^NS	$(canon "$p")/.nightshift$"
  printf '%s\n' "$output" | grep -q '^HOST	claude$'
  printf '%s\n' "$output" | grep -q '^NIGHTSHIFT_PLUGIN_ROOT	.*/plugins/nightshift$'
}

@test "a verb resolves to the shared helper, and a per-host verb to this host's own" {
  p="$(new_project ns-resolve)"
  for host in claude codex cursor; do
    run on "$host" "$p" help
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qE "^  status +.*/runtime/status\.sh$"
    printf '%s\n' "$output" | grep -qE "^  watchman +.*/runtime/$host/watchman\.sh$"
    printf '%s\n' "$output" | grep -qF "host $host"
  done
}

@test "verbs are derived from the tree, so a new helper is a verb and a deleted one is not" {
  p="$(new_project ns-derived)"
  run on claude "$p" help
  # Every shared helper on disk is offered, and nothing that is not a helper.
  for f in "$RT"/*.sh; do
    printf '%s\n' "$output" | grep -qE "^  $(basename "$f" .sh) "
  done
  ! printf '%s\n' "$output" | grep -qE '^  (ns|lib) '
  run on claude "$p" no-such-helper
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'no verb no-such-helper on claude'
}

@test "a verb cannot escape the runtime directory" {
  p="$(new_project ns-escape)"
  for bad in ../../lib/lib ../ns ./status "a/b"; do
    run on claude "$p" "$bad"
    [ "$status" -eq 1 ]
  done
}

@test "the workspace is resolved once and passed to the helpers that take it" {
  p="$(new_project ns-project)"
  run on claude "$p" status
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "Workspace:   $(canon "$p")"

  # catalog-index takes no --project; the dispatcher must not invent one for it.
  run on claude "$p" catalog-index --help
  [ "$status" -ne 2 ]
  ! printf '%s\n' "$output" | grep -qF 'unknown argument: --project'
}

@test "a caller who names the project themselves is not overridden" {
  p="$(new_project ns-explicit)"
  other="$(new_project ns-explicit-other)"
  run on claude "$p" status --project "$other"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "Workspace:   $(canon "$other")"
}

@test "a workspace link is followed, and an invalid one refuses in the preflight's format" {
  p="$(new_project ns-link)"
  real="$(new_project ns-link-real)"
  host="$BATS_TEST_TMPDIR/ns-link-host"
  mkdir -p "$host"
  printf '%s\n' "$real" >"$host/.nightshift-link"
  run on claude "$host" bind
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^NIGHTSHIFT_WORKSPACE	$(canon "$real")$"

  printf 'not-an-absolute-path\n' >"$host/.nightshift-link"
  run on claude "$host" bind
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'refuse workspace invalid .nightshift-link'
  printf '%s\n' "$output" | grep -qF 'repair '
}

@test "the helper's exit status and both streams pass through untouched" {
  p="$(new_project ns-passthrough)"
  # A refusal the helper owns: punch-list exits 2 when there is no list.
  rm -f "$p/.nightshift/punch-list.md"
  run on claude "$p" punch-list next
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'punch-list: no punch list at'

  printf '## Gates\n\n- one gate.\n\n## Items\n\n- [ ] **P01 - open.**\n' \
    >"$p/.nightshift/punch-list.md"
  run on claude "$p" punch-list next
  [ "$status" -eq 0 ]
  # Byte for byte what the helper prints when called directly.
  "$RT/punch-list.sh" --project "$p" next >"$p/direct.txt"
  on claude "$p" punch-list next >"$p/dispatched.txt"
  diff -u "$p/direct.txt" "$p/dispatched.txt"
}

@test "the dispatcher adds nothing of its own to a successful run" {
  p="$(new_project ns-quiet)"
  on claude "$p" status >"$p/dispatched.txt" 2>"$p/dispatched.err"
  "$RT/status.sh" --project "$p" >"$p/direct.txt" 2>"$p/direct.err"
  diff -u "$p/direct.txt" "$p/dispatched.txt"
  diff -u "$p/direct.err" "$p/dispatched.err"
}

# The Windows twin. The skills promise one spelling of every command; that promise is only kept if
# the POSIX flag reaches the right PowerShell parameter.

@test "bind is byte-identical on both dispatchers" {
  ps_ready
  p="$(canon "$(new_project ns-twin-bind)")"
  on claude "$p" bind >"$p/posix.txt"
  env CLAUDE_PROJECT_DIR="$p" NIGHTSHIFT_HOST=claude \
    pwsh -NoProfile -NonInteractive -File "$NSPS" bind >"$p/windows.txt"
  diff -u "$p/posix.txt" "$p/windows.txt"
}

@test "a POSIX flag reaches the PowerShell parameter that answers to it" {
  ps_ready
  p="$(new_project ns-twin-flags)"
  # --project is -Project, and a switch consumes no value.
  run env CLAUDE_PROJECT_DIR="$p" pwsh -NoProfile -NonInteractive -File "$NSPS" preflight-needs --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.schemaVersion == 1' >/dev/null

  # A helper that spells the parameter more fully than the flag does: --host is -HostName.
  run env CLAUDE_PROJECT_DIR="$p" pwsh -NoProfile -NonInteractive -File "$NSPS" \
    start-preflight --host claude
  # Whatever the preflight decides, it must not have failed to bind its own parameter.
  ! printf '%s\n' "$output" | grep -qiF 'cannot find a positional parameter'
  ! printf '%s\n' "$output" | grep -qiF 'parameter cannot be found'
}

@test "a flag no PowerShell helper answers to is refused by the helper, not swallowed" {
  ps_ready
  p="$(new_project ns-twin-unknown)"
  run env CLAUDE_PROJECT_DIR="$p" pwsh -NoProfile -NonInteractive -File "$NSPS" \
    shift-policy get --not-a-flag
  [ "$status" -ne 0 ]
}

@test "the twin exceptions are named, so the list cannot grow unnoticed" {
  # The skills say the verbs are the same on both hosts. These four are where that is not true,
  # and a fifth appearing should fail here rather than in front of an owner.
  posix_only=""
  for f in "$RT"/*.sh; do
    b="$(basename "$f" .sh)"
    [ -f "$RT/windows/$b.ps1" ] || posix_only="$posix_only $b"
  done
  [ "$posix_only" = " provision-recover" ]

  windows_only=""
  for f in "$RT"/windows/*.ps1; do
    b="$(basename "$f" .ps1)"
    [ "$b" = ns ] && continue
    [ -f "$RT/$b.sh" ] || windows_only="$windows_only $b"
  done
  [ "$windows_only" = " setup start-watchman watchman" ]
}

@test "every runtime helper is executable, because the dispatcher execs it" {
  # `ns` uses exec, so a helper without the bit fails with Permission denied rather than a message
  # anyone can act on — and the docs tell owners to run these verbs themselves.
  missing=""
  for f in "$RT"/*.sh "$RT"/*/*.sh "$RT/ns"; do
    [ -f "$f" ] || continue
    case "$f" in */windows/*) continue ;; esac
    [ -x "$f" ] || missing="$missing ${f##*/}"
  done
  [ -z "$missing" ] || { echo "not executable:$missing"; return 1; }
}

@test "every verb ns offers can actually be executed" {
  p="$(new_project ns-executable)"
  for verb in $(on claude "$p" help | awk 'NF == 2 && $1 !~ /^ns/ {print $1}'); do
    target="$(on claude "$p" help | awk -v v="$verb" '$1 == v {print $2}')"
    [ -x "$target" ] || { echo "$verb resolves to a file that cannot be executed: $target"; return 1; }
  done
}
