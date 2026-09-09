#!/usr/bin/env bash
# status.sh — read-only shift status for the native Status skill.
#
#   status.sh --project DIR
#
# Prints a compact glanceable summary: punch-list progress, evidence counts, resolved policy,
# preflight gaps, and liveness vs checkpoint vs stall as separate lines. Never writes.
#
# Exit: 0 report printed · 1 usage
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'status: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'status: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'status: cannot cd to %s\n' "$PROJECT" >&2
  exit 1
}

WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" || WORKSPACE="$HOST"
fi
NS="$WORKSPACE/.nightshift"

emit() { printf '%s\n' "$1"; }
# A fact whose value is empty is still a fact: `none` is an answer, a blank line is not.
fact() { printf '%s %s\n' "$1" "${2:-none}"; }

if [ ! -d "$NS" ]; then
  emit "Nightshift Status"
  emit "Nightshift: missing at $WORKSPACE"
  exit 0
fi

PUNCH="$NS/punch-list.md"
OPEN=0
TICKED=0
[ -f "$PUNCH" ] && OPEN="$(ns_open_boxes "$PUNCH")" && TICKED="$(ns_ticked_boxes "$PUNCH")"
ARMED=0
[ -f "$NS/.shift-armed" ] && ARMED=1
WATCH="$(rule "$WORKSPACE" watchMinutes "${NIGHTSHIFT_WATCH:-}")"
case "$WATCH" in '' | *[!0-9]*) WATCH=0 ;; esac

STOP_REASON="$(ns_status_stop_reason "$NS" 2>/dev/null)"

emit "Nightshift Status"
emit "Workspace:   $WORKSPACE"
emit "Shift:       $([ "$ARMED" -eq 1 ] && printf armed || printf 'not armed')"
emit "Items:       open=$OPEN ticked=$TICKED"
emit "evidence:    $(ns_evidence_counts "$WORKSPACE")"
emit "liveness:    $(ns_status_liveness "$NS" "$WATCH")"
activity="$(ns_status_last_activity "$NS")"
emit "last activity: ${activity:-none}"
emit "last checkpoint: $(ns_status_last_checkpoint "$WORKSPACE")"
emit "stall attempts: $(ns_status_stall_attempts "$NS")"

# The facts, derived here rather than by hand in the skill. One per line, stable label first, so
# the model renders them rather than recomputing them.
emit ""
emit "facts"
fact "schema" "$(ns_state_version "$WORKSPACE" 2>/dev/null)"

# Unarmed with work still open is the one state that reads wrong at a glance: a punch list nobody
# is holding is a to-do file, and only Start makes it a shift.
if [ "$ARMED" -eq 0 ] && [ "${OPEN:-0}" -gt 0 ]; then
  fact "armed" "no (the punch list is a to-do file, not a shift; Start begins one)"
else
  fact "armed" "$([ "$ARMED" -eq 1 ] && printf yes || printf no)"
fi

fact "open item" "$(ns_status_open_title "$PUNCH")"
fact "parked" "$(ns_status_entry_count "$NS/parking-lot.md")"
ns_status_entry_titles "$NS/parking-lot.md" 0 | while IFS= read -r line; do
  [ -n "$line" ] && fact "parked entry" "$line"
done

DRAFTS="$(ns_open_drafts "$NS/drafting-table.md" 2>/dev/null)" || DRAFTS=0
ORDERS="$(ns_open_boxes_file "$NS/work-orders.md" 2>/dev/null)" || ORDERS=0
# With approved work open, staged work is informational and nothing else: Start works the punch
# list exactly as the owner left it.
if [ "${OPEN:-0}" -gt 0 ]; then
  fact "staged" "drafts=$DRAFTS orders=$ORDERS (informational while items are open)"
else
  fact "staged" "drafts=$DRAFTS orders=$ORDERS"
fi

ns_status_entry_titles "$NS/snag-log.md" 3 | while IFS= read -r line; do
  [ -n "$line" ] && fact "snag" "$line"
done

fact "opportunities" "$(ns_status_opportunity_counts "$NS/opportunity-map.md")"
ns_status_building "$NS/opportunity-map.md" | while IFS="$(printf '\t')" read -r key value; do
  [ -n "$key" ] && fact "building $key" "$value"
done

DEADLINE="$(ns_status_deadline_remaining "$NS" 2>/dev/null)"
fact "deadline" "${DEADLINE:-none (finite list)}"
if [ -f "$NS/STOP" ]; then
  fact "stop" "present${STOP_REASON:+ ($STOP_REASON)}"
else
  fact "stop" "absent"
fi
fact "session" "$([ -f "$NS/.shift-session" ] && printf 'bound' || printf 'none')"
fact "lease" "$(ns_lease_valid "$NS" >/dev/null 2>&1 && printf 'held' || printf 'absent or unowned')"

if [ -f "$NS/.watch-reason" ]; then
  REASON_CODE="$(ns_reason_code "$NS" 2>/dev/null)"
  fact "watch reason" "${REASON_CODE:-none}${REASON_CODE:+ ($(ns_reason_label "$REASON_CODE" 2>/dev/null))}"
else
  fact "watch reason" "none"
fi

fact "work mode" "$(ns_work_mode "$WORKSPACE" 2>/dev/null)"
fact "work target" "$(ns_work_target "$WORKSPACE" 2>/dev/null)"
RECEIPTS="$(ns_receipts_count "$WORKSPACE" 2>/dev/null)" || RECEIPTS=0
fact "artifact receipts" "$RECEIPTS"
fact "latest artifact receipt" "$(ns_latest_receipt "$WORKSPACE" 2>/dev/null)"
UNUSABLE_RECV=0
if [ "$(ns_work_mode "$WORKSPACE" 2>/dev/null)" = artifact ]; then
  RECV_PATH="$(ns_receipts_dir "$WORKSPACE" 2>/dev/null)"
  if { [ -e "$RECV_PATH" ] || [ -L "$RECV_PATH" ]; } &&
    ! ns_receipts_usable_dir "$WORKSPACE" >/dev/null 2>&1; then
    UNUSABLE_RECV=1
    fact "receipts warning" "the artifact receipts path is not a usable directory"
  fi
fi
if ns_receipts_enabled "$WORKSPACE"; then
  fact "completion record" "per-item receipt"
  # A planted file where receipts/ belongs is reported as itself; do not also
  # count missing receipt text for that path.
  if [ "$UNUSABLE_RECV" -eq 0 ]; then
    MISSING="$(ns_receipts_missing_count "$WORKSPACE" 2>/dev/null)" || MISSING=0
    if [ "${MISSING:-0}" -gt 0 ]; then
      fact "receipts missing model text" "$MISSING"
    fi
  fi
else
  fact "completion record" "none; the owner disabled receipts"
fi

ns_status_transitions "$NS/shift-log.md" 3 | while IFS= read -r line; do
  [ -n "$line" ] && fact "transition" "$line"
done

emit ""
emit "resolved policy"
if POLICY_LINES="$(ns_policy_resolve_table "$WORKSPACE" 2>/dev/null)"; then
  printf '%s\n' "$POLICY_LINES"
else
  emit "none"
fi
emit ""
emit "preflight gaps"
PREFLIGHT=""
if ns_policy_json_tool >/dev/null 2>&1; then
  PREFLIGHT="$("$_here/preflight-needs.sh" --project "$WORKSPACE" 2>/dev/null)" || PREFLIGHT=""
fi
if [ -n "$PREFLIGHT" ]; then
  printf '%s\n' "$PREFLIGHT"
else
  emit "none"
fi
exit 0
