#!/usr/bin/env bash
# export-support.sh — write one local support bundle of allowlisted fields.
#
# Explicit owner action after Doctor. Never upload, transmit, attach, or open
# the file. Doctor itself stays read-only and must not invoke this.
# Known sensitive fields are omitted. This is not a complete sanitization.
#
#   export-support.sh [--project DIR]
#
# Exit: 0 wrote the bundle · 1 usage · 2 refused
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'export-support: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'export-support: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'export-support: cannot cd to %s\n' "$PROJECT" >&2
  exit 1
}

WORKSPACE="$HOST"
LINK_STATE="absent"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  if WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)"; then
    LINK_STATE="valid"
  else
    printf 'export-support: invalid .nightshift-link — Nightshift will not guess a workspace\n' >&2
    exit 2
  fi
fi

NS="$WORKSPACE/.nightshift"
declare ARMED_FILE ENDED_FILE STOP_FILE SESSION_END_FILE PULSE_FILE SESSION_FILE WATCHMAN_FILE LEASE_FILE
ns_layout_set ARMED_FILE "$NS" armed
ns_layout_set ENDED_FILE "$NS" ended
ns_layout_set STOP_FILE "$NS" stop
ns_layout_set SESSION_END_FILE "$NS" session-end
ns_layout_set PULSE_FILE "$NS" pulse
ns_layout_set SESSION_FILE "$NS" session
ns_layout_set WATCHMAN_FILE "$NS" watchman
ns_layout_set LEASE_FILE "$NS" lease
[ -d "$NS" ] || {
  printf 'export-support: no .nightshift/ at %s\n' "$WORKSPACE" >&2
  exit 2
}

HOME_ROOT="${HOME:-}"
[ -n "$HOME_ROOT" ] && HOME_ROOT="$(cd -P "$HOME_ROOT" 2>/dev/null && pwd)" || HOME_ROOT=""
TARGET="$(ns_work_target "$WORKSPACE" 2>/dev/null || true)"
[ -n "$TARGET" ] && TARGET="$(cd -P "$TARGET" 2>/dev/null && pwd)" || TARGET=""

PLUGIN_JSON="$_here/../.claude-plugin/plugin.json"
PLUGIN_VER="unknown"
PLUGIN_NAME="nightshift"
if [ -f "$PLUGIN_JSON" ]; then
  if command -v jq >/dev/null 2>&1; then
    PLUGIN_VER="$(jq -r '.version // "unknown"' "$PLUGIN_JSON" 2>/dev/null || printf 'unknown')"
    PLUGIN_NAME="$(jq -r '.name // "nightshift"' "$PLUGIN_JSON" 2>/dev/null || printf 'nightshift')"
  else
    PLUGIN_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_JSON" | sed -n 1p)"
    PLUGIN_VER="${PLUGIN_VER:-unknown}"
    PLUGIN_NAME="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_JSON" | sed -n 1p)"
    PLUGIN_NAME="${PLUGIN_NAME:-nightshift}"
  fi
fi

STATE_KIND="$(ns_state_kind "$WORKSPACE")"
STATE_VER="$(ns_state_version "$WORKSPACE" || true)"
case "$STATE_KIND" in
  current | legacy) ;;
  *) STATE_VER="" ;;
esac

declare RULES
ns_layout_set RULES "$NS" rules
RULES_STATE="missing"
RULES_KEYS=""
if [ ! -f "$RULES" ]; then
  RULES_STATE="missing"
elif ns_rules_load "$RULES"; then
  RULES_STATE="valid"
  RULES_KEYS="$(ns_rules_keys "$RULES" | tr '\n' ' ')"
else
  RULES_STATE="unreadable"
fi

# The resolved view, never the policy files themselves. The four owner free-form rule
# patterns always ship as their length, whatever it is; any other setting's value is
# omitted the same way only past 80 characters. Sources and expiries always ship. The jq half
# sits next to this file, resolved without dirname so a hostile PATH cannot reach it.
NS_EXPORT_POLICY_JQ="$_here/export-policy.jq"
NS_EXPORT_POLICY_PY='
import json, sys

FREEFORM = {"forbiddenCommands", "protectedDirs", "neverCommitPatterns", "expectedEmail"}
d = json.load(sys.stdin)["settings"]
for k in sorted(d):
    v = d[k]["value"]
    text = v if isinstance(v, str) else json.dumps(v)
    shown = text
    if k in FREEFORM or len(text) > 80:
        shown = "<redacted %d chars>" % len(text)
    sys.stdout.write("%s=%s (%s, %s)\n" % (k, shown, d[k]["source"], d[k]["expiry"]))
'

POLICY_STATE="unreadable"
ns_policy_read_shift "$WORKSPACE" >/dev/null 2>&1
POLICY_READ_RC=$?
case "$POLICY_READ_RC" in
  0) POLICY_STATE="valid" ;;
  3) POLICY_STATE="absent" ;;
  2) POLICY_STATE="malformed" ;;
  *) POLICY_STATE="unreadable" ;;
esac

# Same redaction as the jq/python halves, from the already-resolved table — not a parser.
_ns_export_policy_table() {
  local line name rest val meta
  ns_policy_resolve_table "$1" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%%=*}"
    rest="${line#*=}"
    case "$rest" in
      *' ('*)
        meta="${rest##* (}"
        val="${rest% ("$meta"}"
        ;;
      *)
        printf '%s\n' "$line"
        continue
        ;;
    esac
    case "$name" in
      forbiddenCommands | protectedDirs | neverCommitPatterns | expectedEmail)
        printf '%s=<redacted %s chars> (%s\n' "$name" "${#val}" "$meta"
        ;;
      *)
        if [ "${#val}" -gt 80 ]; then
          printf '%s=<redacted %s chars> (%s\n' "$name" "${#val}" "$meta"
        else
          printf '%s\n' "$line"
        fi
        ;;
    esac
  done
}

POLICY_LINES=""
if POLICY_JSON="$(ns_policy_resolve "$WORKSPACE" 2>/dev/null)"; then
  if command -v jq >/dev/null 2>&1; then
    POLICY_LINES="$(printf '%s' "$POLICY_JSON" | jq -r -f "$NS_EXPORT_POLICY_JQ" 2>/dev/null)" || POLICY_LINES=""
  elif command -v python3 >/dev/null 2>&1; then
    POLICY_LINES="$(printf '%s' "$POLICY_JSON" | python3 -c "$NS_EXPORT_POLICY_PY" 2>/dev/null)" || POLICY_LINES=""
  else
    POLICY_LINES="$(_ns_export_policy_table "$WORKSPACE" 2>/dev/null)" || POLICY_LINES=""
  fi
fi

REASON="$(ns_reason_code "$NS")"
REASON_LABEL=""
[ -z "$REASON" ] || REASON_LABEL="$(ns_reason_label "$REASON")"

LEASE_STATE="absent"
LEASE_HOST=""
LEASE_GENERATION=""
LEASE_MODE=""
if [ -e "$LEASE_FILE" ] || [ -L "$LEASE_FILE" ]; then
  if ns_lease_valid "$NS"; then
    LEASE_STATE="valid"
    LEASE_HOST="$NS_LEASE_HOST"
    LEASE_GENERATION="$NS_LEASE_GENERATION"
    if [ -n "$NS_LEASE_NONCE" ]; then
      LEASE_MODE="recovered"
    else
      LEASE_MODE="interactive"
    fi
  else
    LEASE_STATE="malformed"
  fi
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
declare outdir
ns_layout_set outdir "$NS" support
mkdir -p "$outdir" || {
  printf 'export-support: cannot create %s\n' "$outdir" >&2
  exit 2
}
tmp="$outdir/.$stamp.$$"
dest="$outdir/${stamp}.txt"

{
  printf 'Nightshift support bundle\n'
  printf 'Generated: %s\n' "$stamp"
  printf '\n== plugin ==\n'
  printf 'name: %s\n' "$PLUGIN_NAME"
  printf 'version: %s\n' "$PLUGIN_VER"
  printf '\n== host ==\n'
  printf 'uname: %s\n' "$(uname -s)"
  printf 'link: %s\n' "$LINK_STATE"
  printf '\n== state ==\n'
  printf 'kind: %s\n' "$STATE_KIND"
  [ -z "$STATE_VER" ] || printf 'version: %s\n' "$STATE_VER"
  printf '\n== identities ==\n'
  if id_host="$(ns_tokenize_text "$HOST" "$HOME_ROOT" "$WORKSPACE" "$TARGET")"; then
    printf 'task: %s\n' "$id_host"
  else
    printf 'task: omitted\n'
  fi
  if id_ws="$(ns_tokenize_text "$WORKSPACE" "$HOME_ROOT" "$WORKSPACE" "$TARGET")"; then
    printf 'workspace: %s\n' "$id_ws"
  else
    printf 'workspace: omitted\n'
  fi
  if [ -n "$TARGET" ]; then
    if id_tg="$(ns_tokenize_text "$TARGET" "$HOME_ROOT" "$WORKSPACE" "$TARGET")"; then
      printf 'work_target: %s\n' "$id_tg"
    else
      printf 'work_target: omitted\n'
    fi
  else
    printf 'work_target: unresolved\n'
  fi
  printf '\n== markers ==\n'
  if [ -L "$ARMED_FILE" ]; then
    printf 'armed: unusable\n'
  else
    printf 'armed: %s\n' "$( [ -f "$ARMED_FILE" ] && printf yes || printf no )"
  fi
  if [ -L "$ENDED_FILE" ]; then
    printf 'ended: unusable\n'
  else
    printf 'ended: %s\n' "$( [ -f "$ENDED_FILE" ] && printf yes || printf no )"
  fi
  printf 'stop: %s\n' "$( [ -f "$STOP_FILE" ] && printf yes || printf no )"
  if [ -L "$SESSION_END_FILE" ]; then
    printf 'session_end: unusable\n'
  else
    printf 'session_end: %s\n' "$( [ -f "$SESSION_END_FILE" ] && printf yes || printf no )"
  fi
  if [ -L "$PULSE_FILE" ]; then
    printf 'shift_pulse: unusable\n'
  else
    printf 'shift_pulse: %s\n' "$( [ -f "$PULSE_FILE" ] && printf yes || printf no )"
  fi
  if [ -L "$SESSION_FILE" ]; then
    printf 'session_record: unusable\n'
  else
    printf 'session_record: %s\n' "$( [ -f "$SESSION_FILE" ] && printf present || printf absent )"
  fi
  printf 'process_lease: %s\n' "$LEASE_STATE"
  [ -z "$LEASE_HOST" ] || printf 'lease_host: %s\n' "$LEASE_HOST"
  [ -z "$LEASE_GENERATION" ] || printf 'lease_generation: %s\n' "$LEASE_GENERATION"
  [ -z "$LEASE_MODE" ] || printf 'lease_mode: %s\n' "$LEASE_MODE"
  if [ -L "$WATCHMAN_FILE" ]; then
    printf 'watchman_pidfile: unusable\n'
  else
    printf 'watchman_pidfile: %s\n' "$( [ -f "$WATCHMAN_FILE" ] && printf present || printf absent )"
  fi
  printf '\n== rules ==\n'
  printf 'validity: %s\n' "$RULES_STATE"
  printf 'keys: %s\n' "${RULES_KEYS:-}"
  printf '\n== resolved policy ==\n'
  printf 'shift_policy: %s\n' "$POLICY_STATE"
  if [ -n "$POLICY_LINES" ]; then
    printf '%s\n' "$POLICY_LINES"
  fi
  printf '\n== evidence summary ==\n'
  printf '%s\n' "$(ns_evidence_counts "$WORKSPACE")"
  printf 'liveness: %s\n' "$(ns_status_liveness "$NS" "$(rule "$WORKSPACE" watchMinutes "${NIGHTSHIFT_WATCH:-}")")"
  activity="$(ns_status_last_activity "$NS")"
  printf 'last activity: %s\n' "${activity:-none}"
  printf 'last checkpoint: %s\n' "$(ns_status_last_checkpoint "$WORKSPACE")"
  printf 'stall attempts: %s\n' "$(ns_status_stall_attempts "$NS")"
  declare inv
  ns_layout_set inv "$NS" capabilities
  if [ -f "$inv" ] && [ ! -L "$inv" ] && command -v jq >/dev/null 2>&1; then
    printf 'inventory items: %s\n' "$(jq '.items | length' "$inv" 2>/dev/null || printf 0)"
  else
    printf 'inventory items: omitted\n'
  fi
  printf '\n== runtime log ==\n'
  printf 'omitted\n'
  printf '\n== watchman reason ==\n'
  if [ -n "$REASON" ]; then
    printf 'code: %s\n' "$REASON"
    printf 'label: %s\n' "$REASON_LABEL"
  else
    printf 'code: none\n'
  fi
} >"$tmp" || {
  rm -f "$tmp"
  printf 'export-support: failed to write bundle\n' >&2
  exit 2
}

chmod 600 "$tmp" || {
  rm -f "$tmp"
  printf 'export-support: failed to restrict bundle mode\n' >&2
  exit 2
}
mv "$tmp" "$dest" || {
  rm -f "$tmp"
  printf 'export-support: failed to publish bundle\n' >&2
  exit 2
}

printf 'Support bundle: %s\n' "$dest"
printf 'Included: plugin version, markers, the resolved policy view, counts\n'
printf 'Omitted: scheduled.log, evidence ledger raw output, known sensitive fields, repository contents, diffs, transcripts, prompts, owner files, credentials, network, session identities, lease capabilities, capability inventory contents, policy files\n'
printf 'Known sensitive fields are omitted. Inspect the file before sharing. Never uploaded, attached, or opened automatically.\n'
exit 0
