#!/usr/bin/env bash
# shift-policy.sh — read and write the three policy files, and print the one resolved view.
#
#   shift-policy.sh --project DIR get
#   shift-policy.sh --project DIR set --from-json FILE|-
#   shift-policy.sh --project DIR defaults-get
#   shift-policy.sh --project DIR defaults-set [--verificationProfile fast|balanced|strict|custom]
#                                             [--hours N|null] [--execution review-first|run-direct]
#                                             [--toolingPolicy existing-tools|review-missing|auto-add]
#   shift-policy.sh --project DIR resolve [--json|--table]
#   shift-policy.sh --project DIR archive
#
# Writes only .nightshift/shift-policy.json, .nightshift/shift-defaults.json, and the dated
# archive directory the clock-out gate files the snapshot into. Both writes are refused while the
# shift is armed: composition writes before arming, and hardhat guards the files after.
# Exit: 0 ok · 1 usage · 2 contract failure, naming the field · 3 nothing to read or archive
#       · 4 refused while armed
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0" >&2
  exit 1
}

die() {
  printf 'shift-policy: %s\n' "$1" >&2
  exit "$2"
}

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
CMD=""
FROM=""
FORMAT=json
SET_PROFILE=""
SET_HOURS=""
SET_TOOLING=""
SET_EXECUTION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || usage
      PROJECT="$2"
      shift 2
      ;;
    --from-json)
      [ $# -ge 2 ] || usage
      FROM="$2"
      shift 2
      ;;
    --json)
      FORMAT=json
      shift
      ;;
    --table)
      FORMAT=table
      shift
      ;;
    --verificationProfile)
      [ $# -ge 2 ] || usage
      SET_PROFILE="$2"
      shift 2
      ;;
    --hours)
      [ $# -ge 2 ] || usage
      SET_HOURS="$2"
      shift 2
      ;;
    --toolingPolicy)
      [ $# -ge 2 ] || usage
      SET_TOOLING="$2"
      shift 2
      ;;
    --execution)
      [ $# -ge 2 ] || usage
      SET_EXECUTION="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    get | set | defaults-get | defaults-set | resolve | archive)
      [ -z "$CMD" ] || usage
      CMD="$1"
      shift
      ;;
    *)
      printf 'shift-policy: unknown argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done
[ -n "$CMD" ] || usage

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || die "cannot cd to $PROJECT" 1
WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" ||
    die 'invalid .nightshift-link — Nightshift will not guess a workspace' 2
fi
NS="$WORKSPACE/.nightshift"
POLICY="$NS/shift-policy.json"
DEFAULTS="$NS/shift-defaults.json"

# The snapshot is where tonight's deadline, verification level and elevation allowances live.
# A host with no jq and no python3 still reads and writes it through the bounded reader; only a
# host with no awk either has nothing left to read it with.
ns_policy_json_tool >/dev/null || ns_rules_awk_bin >/dev/null ||
  die 'no JSON reader on this host: install jq, python3, or awk' 2

# Every write lands by rename, so a reader never sees half a policy.
atomic_write() { # <destination> — content on stdin
  local dest="$1" tmp
  tmp="$dest.tmp.$$"
  cat >"$tmp" || {
    rm -f "$tmp"
    die "cannot write $dest" 2
  }
  mv "$tmp" "$dest" || {
    rm -f "$tmp"
    die "cannot write $dest" 2
  }
}

refuse_while_armed() {
  [ -e "$NS/.shift-armed" ] || [ -L "$NS/.shift-armed" ] || return 0
  die 'refuse to write the shift policy while the shift is armed — park the need' 4
}

now_utc() {
  if [ -n "${NIGHTSHIFT_POLICY_NOW:-}" ]; then
    printf '%s' "$NIGHTSHIFT_POLICY_NOW"
    return 0
  fi
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

cmd_get() {
  local out rc
  out="$(ns_policy_read_shift "$WORKSPACE")"
  rc=$?
  case "$rc" in
    0)
      printf '%s\n' "$out"
      exit 0
      ;;
    3)
      printf '{}\n'
      exit 3
      ;;
    4) die 'JSON parser unavailable; composition writes shift-policy.json and Start already has rules.json' 2 ;;
    *) die "invalid shift-policy.json: $out" 2 ;;
  esac
}

cmd_set() {
  local tmpd candidate out rc
  [ -n "$FROM" ] || usage
  [ -d "$NS" ] || die "no .nightshift/ at $WORKSPACE — run setup first" 2
  refuse_while_armed
  tmpd="$(mktemp -d)" || die 'cannot create a temporary directory' 2
  candidate="$tmpd/candidate.json"
  if [ "$FROM" = - ]; then
    cat >"$candidate"
  else
    [ -f "$FROM" ] || {
      rm -rf "$tmpd"
      die "no such file: $FROM" 1
    }
    cat "$FROM" >"$candidate"
  fi
  out="$(ns_policy_validate_shift_file "$candidate")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf "$tmpd"
    case "$rc" in
      3) die 'the policy to write is empty' 2 ;;
      4) die 'JSON parser unavailable; composition writes shift-policy.json and Start already has rules.json' 2 ;;
      *) die "invalid shift-policy.json: $out" 2 ;;
    esac
  fi
  ns_policy_pretty_text <"$candidate" >"$tmpd/pretty.json" || {
    rm -rf "$tmpd"
    die 'cannot render the policy' 2
  }
  atomic_write "$POLICY" <"$tmpd/pretty.json"
  rm -rf "$tmpd"
  printf '%s\n' "$POLICY"
  exit 0
}

cmd_defaults_get() {
  ns_policy_read_defaults "$WORKSPACE" || :
  exit 0
}

cmd_defaults_set() {
  [ -d "$NS" ] || die "no .nightshift/ at $WORKSPACE — run setup first" 2
  refuse_while_armed
  ns_policy_read_defaults "$WORKSPACE" >/dev/null || :
  if [ -n "$SET_PROFILE" ]; then
    case "$SET_PROFILE" in
      fast | balanced | strict | custom) NS_POLICY_DEF_PROFILE="\"$SET_PROFILE\"" ;;
      *) die 'verificationProfile must be fast, balanced, strict, or custom' 2 ;;
    esac
  fi
  if [ -n "$SET_HOURS" ]; then
    case "$SET_HOURS" in
      null) NS_POLICY_DEF_HOURS=null ;;
      '' | *[!0-9]*) die 'hours must be a whole number of hours or null' 2 ;;
      *) NS_POLICY_DEF_HOURS="$SET_HOURS" ;;
    esac
  fi
  if [ -n "$SET_TOOLING" ]; then
    case "$SET_TOOLING" in
      existing-tools | review-missing | auto-add) NS_POLICY_DEF_TOOLING="\"$SET_TOOLING\"" ;;
      *) die 'toolingPolicy must be existing-tools, review-missing, or auto-add' 2 ;;
    esac
  fi
  if [ -n "$SET_EXECUTION" ]; then
    case "$SET_EXECUTION" in
      review-first | run-direct) NS_POLICY_DEF_EXECUTION="\"$SET_EXECUTION\"" ;;
      *) die 'execution must be review-first or run-direct' 2 ;;
    esac
  fi
  NS_POLICY_DEF_UPDATED="\"$(now_utc)\""
  ns_policy_defaults_json | ns_policy_pretty_text | atomic_write "$DEFAULTS"
  printf '%s\n' "$DEFAULTS"
  exit 0
}

cmd_resolve() {
  if [ "$FORMAT" = table ]; then
    ns_policy_resolve_table "$WORKSPACE" || die 'JSON parser unavailable; composition writes shift-policy.json and Start already has rules.json' 2
  else
    ns_policy_resolve "$WORKSPACE" || die 'JSON parser unavailable; composition writes shift-policy.json and Start already has rules.json' 2
  fi
  exit 0
}

cmd_archive() {
  local out rc shift_id dated dest
  out="$(ns_policy_read_shift "$WORKSPACE")"
  rc=$?
  case "$rc" in
    0) ;;
    3) die 'no shift-policy.json to archive' 3 ;;
    4) die 'JSON parser unavailable; composition writes shift-policy.json and Start already has rules.json' 2 ;;
    *) die "invalid shift-policy.json: $out" 2 ;;
  esac
  shift_id="$(ns_policy_shift_id "$WORKSPACE")" || die 'shift-policy.json carries no shiftId' 2
  dated="$NS/archive/$(date '+%Y-%m-%d')"
  mkdir -p "$dated" || die "cannot create $dated" 2
  dest="$dated/shift-policy-$shift_id.json"
  mv "$POLICY" "$dest" || die "cannot archive $POLICY" 2
  printf '%s\n' "$dest"
  exit 0
}

case "$CMD" in
  get) cmd_get ;;
  set) cmd_set ;;
  defaults-get) cmd_defaults_get ;;
  defaults-set) cmd_defaults_set ;;
  resolve) cmd_resolve ;;
  archive) cmd_archive ;;
esac
