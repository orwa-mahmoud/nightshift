#!/usr/bin/env bats
# Names, ids and counts read from files and flags accept ASCII only, the same on both runtimes and
# in any locale. /bin/bash is bash 3.2 on macOS, where a bracket range follows the locale's
# collation; PowerShell's \d takes any Unicode digit and its default matching ignores case.

bats_require_minimum_version 1.5.0

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
LIB="$ROOT/plugins/nightshift/lib/lib.sh"
MOD="$ROOT/plugins/nightshift/lib/Nightshift.psm1"
ARCHIVE="$ROOT/plugins/nightshift/runtime/archive-receipts.sh"
ARCHIVE_PS1="$ROOT/plugins/nightshift/runtime/windows/archive-receipts.ps1"

E_ACUTE="$(printf '\xc3\xa9')"
ARABIC_THREE="$(printf '\xd9\xa3')"

in_utf8_bash() { # <script> [args...] — run with lib.sh loaded, under the system bash and UTF-8
  local script="$1"
  shift
  env LC_ALL=en_US.UTF-8 /bin/bash -c ". \"\$0\"; $script" "$LIB" "$@"
}

@test "lease nonces, Cursor model ids and policy digests refuse non-ASCII letters" {
  ns="$BATS_TEST_TMPDIR/site/.nightshift"
  mkdir -p "$ns"
  run in_utf8_bash 'ns_lease_write_unlocked "$1" sid claude 1 "$2" "" ""' "$ns" "n$E_ACUTE"
  [ "$status" -ne 0 ]
  [ ! -e "$(in_utf8_bash 'ns_layout_path "$1" lease' "$ns")" ]
  run in_utf8_bash 'ns_lease_write_unlocked "$1" sid claude 1 nonce-1 "" ""' "$ns"
  [ "$status" -eq 0 ]

  run in_utf8_bash 'ns_cursor_model_safe "$1"' "gpt-$E_ACUTE"
  [ "$status" -ne 0 ]
  run in_utf8_bash 'ns_cursor_model_safe "$1"' 'gpt-5.1:high'
  [ "$status" -eq 0 ]

  run in_utf8_bash '_ns_json_hex "\"$1\"" 4' ABCD
  [ "$status" -ne 0 ]
  run in_utf8_bash '_ns_json_hex "\"$1\"" 4' 'ab1f'
  [ "$status" -eq 0 ]
}

@test "an archive date is ASCII digits on both runtimes" {
  p="$(new_project archive-date)"
  rm -f "$p/.nightshift/.shift-armed"
  date="$ARABIC_THREE$ARABIC_THREE$ARABIC_THREE$ARABIC_THREE-11-10"
  run env LC_ALL=en_US.UTF-8 /bin/bash "$ARCHIVE" --project "$p" --date "$date"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'must be YYYY-MM-DD'
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  run pwsh -NoProfile -File "$ARCHIVE_PS1" -Project "$p" -Date "$date"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'must be YYYY-MM-DD'
  [ -z "$(find "$p/.nightshift" -path '*archive*' -name "*$ARABIC_THREE*" -print -quit)" ]
}

@test "a stall count in Unicode digits reads as no count, without an error, in the Windows gate" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh is not installed'
  fi
  stall="$BATS_TEST_TMPDIR/stall"
  printf 'fingerprint\n%s\n' "$ARABIC_THREE" >"$stall"
  run env NS_T_STALL="$stall" pwsh -NoProfile -Command \
    "Import-Module '$MOD' -Force -DisableNameChecking; Get-NSGateStallState -Path \$env:NS_T_STALL -WarnEvery 3"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ "$output" = quiet ]
  printf 'fingerprint\n3\n' >"$stall"
  run env NS_T_STALL="$stall" pwsh -NoProfile -Command \
    "Import-Module '$MOD' -Force -DisableNameChecking; Get-NSGateStallState -Path \$env:NS_T_STALL -WarnEvery 3"
  [ "$output" = warned ]
}
