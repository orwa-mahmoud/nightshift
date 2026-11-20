#!/usr/bin/env bash
# Boundary-side fixture for proving that a detached watchman crosses a transport disconnect.
set -euo pipefail

ACTION="${1:-}"
ROOT="${2:-}"
FIXTURE="${3:-}"
if [ -z "$ROOT" ] || [ -z "$FIXTURE" ]; then
  printf 'usage: disconnect-watchman.sh start|verify|cleanup REPOSITORY FIXTURE\n' >&2
  exit 2
fi
case "$FIXTURE" in
  /tmp/nightshift-environment.*)
    case "${FIXTURE#/tmp/}" in
      */* | '') printf 'disconnect fixture: refusing nested fixture path\n' >&2; exit 1 ;;
    esac
    ;;
  *)
    printf 'disconnect fixture: refusing unsafe fixture path\n' >&2
    exit 1
    ;;
esac
[ ! -L "$FIXTURE" ] || {
  printf 'disconnect fixture: refusing symlink fixture path\n' >&2
  exit 1
}
if [ -e "$FIXTURE" ] && { [ ! -d "$FIXTURE" ] || [ ! -O "$FIXTURE" ]; }; then
  printf 'disconnect fixture: fixture is not an owned directory\n' >&2
  exit 1
fi
fixture_parent="${FIXTURE%/*}"
temp_root="$(cd -P /tmp && pwd)"
[ "$(cd -P "$fixture_parent" 2>/dev/null && pwd)" = "$temp_root" ] || {
  printf 'disconnect fixture: fixture must be directly below /tmp\n' >&2
  exit 1
}

LIB="$ROOT/plugins/nightshift/lib/lib.sh"
WATCHMAN="$ROOT/plugins/nightshift/runtime/claude/watchman.sh"
RULES="$ROOT/plugins/nightshift/config/nightshift-rules-template.json"

read_watchman_pid() {
  local marker pid
  marker="$FIXTURE/.nightshift/.watchman"
  if [ ! -f "$marker" ] || [ -L "$marker" ]; then
    printf 'disconnect fixture: watchman marker is unavailable or unsafe\n' >&2
    return 1
  fi
  pid="$(sed -n '1p' "$marker")"
  case "$pid" in '' | *[!0-9]* | 0* | 1)
    printf 'disconnect fixture: watchman marker has an invalid pid\n' >&2
    return 1
    ;;
  esac
  printf '%s\n' "$pid"
}

stop_started_watchman() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

case "$ACTION" in
  start)
    mkdir -p "$FIXTURE/.nightshift"
    git -C "$FIXTURE" init -q
    cp "$RULES" "$FIXTURE/.nightshift/rules.json"
    printf '1\n' >"$FIXTURE/.nightshift/state-version"
    printf '# Shift Log\n' >"$FIXTURE/.nightshift/shift-log.md"
    printf '# Parking Lot\n' >"$FIXTURE/.nightshift/parking-lot.md"
    printf '## Items\n- [ ] **1. disconnect fixture.**\n' >"$FIXTURE/.nightshift/punch-list.md"
    : >"$FIXTURE/.nightshift/.shift-armed"
    nohup env NIGHTSHIFT_WATCH_SLEEP=5 \
      bash "$WATCHMAN" --project "$FIXTURE" --interval 1 --agent true \
      >"$FIXTURE/watchman.log" 2>&1 </dev/null &
    watchman_pid=$!
    trap 'stop_started_watchman "$watchman_pid"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    attempt=0
    while [ ! -s "$FIXTURE/.nightshift/.watchman" ]; do
      if ! kill -0 "$watchman_pid" 2>/dev/null; then
        wait "$watchman_pid" 2>/dev/null || true
        printf 'disconnect fixture: watchman exited before publishing its pid\n' >&2
        exit 1
      fi
      attempt=$((attempt + 1))
      [ "$attempt" -lt 100 ] || {
        stop_started_watchman "$watchman_pid"
        printf 'disconnect fixture: watchman did not publish its pid\n' >&2
        exit 1
      }
      sleep 0.02
    done
    pid="$(read_watchman_pid)"
    [ "$pid" = "$watchman_pid" ] || {
      printf 'disconnect fixture: watchman published an unexpected pid\n' >&2
      exit 1
    }
    kill -0 "$pid"
    trap - EXIT INT TERM
    ;;
  verify)
    pid="$(read_watchman_pid)"
    kill -0 "$pid"
    # shellcheck source=plugins/nightshift/lib/lib.sh
    . "$LIB"
    [ "$(ns_proc_cwd "$pid")" = "$(cd "$FIXTURE" && pwd)" ]
    : >"$FIXTURE/.nightshift/STOP"
    attempt=0
    while [ -e "$FIXTURE/.nightshift/.watchman" ]; do
      attempt=$((attempt + 1))
      [ "$attempt" -lt 400 ] || {
        printf 'disconnect fixture: watchman ignored STOP after reconnect\n' >&2
        exit 1
      }
      sleep 0.05
    done
    [ "$(sed -n '1p' "$FIXTURE/.nightshift/.watch-reason")" = "owner-stop" ]
    ;;
  cleanup)
    if [ -s "$FIXTURE/.nightshift/.watchman" ]; then
      pid="$(read_watchman_pid)"
      if kill -0 "$pid" 2>/dev/null; then
        # shellcheck source=plugins/nightshift/lib/lib.sh
        . "$LIB"
        expected_cwd="$(cd "$FIXTURE" && pwd)"
        actual_cwd="$(ns_proc_cwd "$pid" 2>/dev/null || true)"
        [ "$actual_cwd" = "$expected_cwd" ] || {
          printf 'disconnect fixture: refusing to signal a pid outside the fixture\n' >&2
          exit 1
        }
        actual_command="$(ps -p "$pid" -o args= 2>/dev/null || true)"
        case "$actual_command" in
          *"$WATCHMAN"*) ;;
          *)
            printf 'disconnect fixture: refusing to signal a non-watchman pid\n' >&2
            exit 1
            ;;
        esac
        kill "$pid"
        attempt=0
        while kill -0 "$pid" 2>/dev/null; do
          attempt=$((attempt + 1))
          [ "$attempt" -lt 200 ] || {
            printf 'disconnect fixture: watchman did not stop during cleanup\n' >&2
            exit 1
          }
          sleep 0.05
        done
      fi
    fi
    rm -rf -- "$FIXTURE"
    if [ -e "$FIXTURE" ] || [ -L "$FIXTURE" ]; then
      printf 'disconnect fixture: cleanup did not remove the fixture\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'usage: disconnect-watchman.sh start|verify|cleanup REPOSITORY FIXTURE\n' >&2
    exit 2
    ;;
esac
