#!/usr/bin/env bats
# Library layout: lib.sh is the public entry; modules load relative to it.

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
LIB_DIR="$BATS_TEST_DIRNAME/../plugins/nightshift/lib"

@test "lib.sh loads from a different working directory" {
  other="$BATS_TEST_TMPDIR/elsewhere"
  mkdir -p "$other"
  run bash -c 'cd "$1" && . "$2" && type ns_have_cmd >/dev/null && type ns_workspace_root >/dev/null && type repo_root >/dev/null && type ns_state_kind >/dev/null && type ns_policy_resolve >/dev/null && type ns_pid_alive >/dev/null && type ns_lock >/dev/null && printf loaded' _ "$other" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = loaded ]
}

@test "lib.sh may be sourced twice" {
  run bash -c '. "$1" && . "$1" && ns_have_cmd bash && [ "$NS_STATE_VERSION" = 1 ] && printf ok' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "lib.sh loads under set -u" {
  run bash -c 'set -u; . "$1"; type ns_lock >/dev/null; printf ok' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "callers keep sourcing lib.sh rather than individual modules" {
  root="$BATS_TEST_DIRNAME/../plugins/nightshift"
  for mod in common paths git state policy process ownership; do
    if grep -R --include='*.sh' -F "lib/${mod}.sh" "$root/hooks" "$root/runtime"; then
      echo "hook or runtime sourced lib/${mod}.sh directly"
      return 1
    fi
  done
  grep -R --include='*.sh' -lF 'lib/lib.sh' "$root/hooks" "$root/runtime" | grep -q .
}

@test "lib.sh is a loader; each public function has one implementation" {
  if grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{' "$LIB"; then
    return 1
  fi
  for fn in ns_workspace_root repo_root ns_lock ns_state_kind ns_policy_resolve ns_pid_alive valid_ere; do
    n="$(grep -hE "^${fn}\(\) \{" "$LIB_DIR"/*.sh | wc -l | tr -d ' ')"
    [ "$n" -eq 1 ] || { echo "expected one $fn, got $n"; return 1; }
  done
}

@test "ns_msys_path converts a drive letter without remapping Temp through cygpath" {
  run bash -c '. "$1"; ns_msys_path "$2"' _ "$LIB" 'D:/a/_temp/ns-fence'
  [ "$status" -eq 0 ]
  [ "$output" = "/d/a/_temp/ns-fence" ]
  run bash -c '. "$1"; ns_msys_path "$2"' _ "$LIB" 'C:\Users\runner\AppData\Local\Temp\ns-fence'
  [ "$status" -eq 0 ]
  [ "$output" = "/c/Users/runner/AppData/Local/Temp/ns-fence" ]
  run bash -c '. "$1"; ns_msys_path "$2"' _ "$LIB" '/tmp/foo'
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/foo" ]
}

# A native Windows helper that ends `exit (Some-NSFunction ...)` makes the function's whole output
# the value of that expression. Anything the function writes to the pipeline is consumed there and
# never reaches the caller — the command still exits 0, so nothing looks wrong. Two shipped helpers
# were written that way; the fix in both was to write to the console and return only the code.
@test "no Windows helper swallows its own output in an exit expression" {
  local module="$LIB_DIR/Nightshift.psm1"
  local root="$BATS_TEST_DIRNAME/../plugins/nightshift"
  local f last fn hits
  for f in "$root"/runtime/windows/*.ps1 "$root"/hooks/windows/*.ps1; do
    [ -f "$f" ] || continue
    last="$(grep -vE '^[[:space:]]*($|#)' "$f" | tail -1)"
    case "$last" in
      "exit ("*) ;;
      *) continue ;;
    esac
    fn="$(printf '%s' "$last" | sed -n 's/^exit (\([A-Za-z][A-Za-z]*-[A-Za-z][A-Za-z]*\).*/\1/p')"
    [ -n "$fn" ] || continue
    hits="$(awk -v want="function $fn" '
      $0 ~ "^" want "([[:space:]]|$)" { inside = 1; next }
      inside && /^function / { inside = 0 }
      inside && /Write-Output|Write-Host/ { n++ }
      END { print n + 0 }' "$module")"
    [ "$hits" -eq 0 ] || {
      echo "$(basename "$f") exits on $fn, which writes $hits line(s) to the pipeline"
      return 1
    }
  done
}
