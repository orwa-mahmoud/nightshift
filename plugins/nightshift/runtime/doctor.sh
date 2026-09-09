#!/usr/bin/env bash
# doctor.sh — read-only site diagnosis. Prints what Nightshift sees; never repairs.
#
#   doctor.sh [--project DIR]
#
# Exit: 0 report printed · 1 usage
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
_here="$(cd -P "$_here" && pwd)" || exit 1
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'doctor: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'doctor: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'doctor: cannot cd to %s\n' "$PROJECT" >&2
  exit 1
}

emit() { printf '%s\n' "$1"; }
fact() { FACTS="${FACTS}${FACTS:+
}$1"; }
warn() { WARNS="${WARNS}${WARNS:+
}$1"; }
act() { # safe|confirm|blocked  message
  ACTIONS="${ACTIONS}${ACTIONS:+
}[$1] $2"
}

FACTS=""
WARNS=""
ACTIONS=""

LINK="$HOST/.nightshift-link"
LINK_STATE="absent"
WORKSPACE="$HOST"
if [ -e "$LINK" ] || [ -L "$LINK" ]; then
  if WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)"; then
    LINK_STATE="valid"
    fact "task root $HOST links to workspace $WORKSPACE"
  else
    LINK_STATE="invalid"
    WORKSPACE="$HOST"
    warn "invalid .nightshift-link — Nightshift will not guess a workspace"
    act confirm "replace .nightshift-link with an absolute path to a directory that already contains .nightshift/, using $_here/link-workspace.sh"
  fi
else
  fact "task root is the workspace: $HOST"
fi

NS="$WORKSPACE/.nightshift"
STATE_KIND="absent"
STATE_VER=""
if [ -d "$NS" ]; then
  STATE_KIND="$(ns_state_kind "$WORKSPACE")"
  STATE_VER="$(ns_state_version "$WORKSPACE" || true)"
fi
if [ ! -d "$NS" ]; then
  warn "no .nightshift/ at $WORKSPACE"
  act confirm "run Nightshift setup from the project you want to change (not a ChatGPT scratch workspace)"
  emit "Nightshift Doctor"
  emit "Host:        $HOST"
  emit "Workspace:   $WORKSPACE"
  emit "Link:        $LINK_STATE"
  emit "Nightshift:  missing"
  emit ""
  emit "Facts"
  printf '%s\n' "${FACTS:-none}"
  emit ""
  emit "resolved policy"
  emit "none"
  emit ""
  emit "Warnings"
  printf '%s\n' "${WARNS:-none}"
  emit ""
  emit "Actions (Doctor does not perform these)"
  printf '%s\n' "${ACTIONS:-none}"
  exit 0
fi

TARGET=""
UNUSABLE_RECV=0
if MODE="$(ns_work_mode "$WORKSPACE" 2>/dev/null)"; then
  fact "work mode $MODE"
  if [ ! -s "$NS/work-mode" ]; then
    proposed="$(ns_propose_work_mode "$WORKSPACE" 2>/dev/null)" || proposed=""
    if [ "$proposed" = artifact ]; then
      warn "work mode is unset; Setup would propose artifact"
      act confirm "persist the proposed artifact mode with Setup; Doctor does not write work-mode"
    fi
  fi
  if [ "$MODE" = artifact ]; then
    fact "artifact receipts $(ns_receipts_count "$WORKSPACE")"
    if latest="$(ns_latest_receipt "$WORKSPACE")"; then
      fact "latest artifact receipt ${latest##*/}"
    fi
    recv="$(ns_receipts_dir "$WORKSPACE")"
    if [ -e "$recv" ] || [ -L "$recv" ]; then
      if ! ns_receipts_usable_dir "$WORKSPACE" >/dev/null; then
        UNUSABLE_RECV=1
        warn "artifact receipts path is not a usable directory"
        act confirm "replace the unusable receipts path with a real directory so receipts can land; Doctor does not rewrite it"
      fi
    fi
  fi
else
  MODE=""
  warn "work mode is malformed; treating the site as unusable until Setup rewrites it"
fi
if TARGET="$(ns_work_target "$WORKSPACE" 2>/dev/null)"; then
  fact "work target $TARGET"
else
  rc=$?
  TARGET="$WORKSPACE"
  if [ "$rc" -eq 3 ]; then
    warn "work target is a disposable scratch workspace"
  else
    warn "work target could not be resolved; treating workspace as the code root"
  fi
fi

# The one resolver renders the one view: every effective setting, where it came from, and when
# it expires. Doctor reads it and never re-derives precedence — same order and wording as the
# PowerShell Doctor, so both hosts print the same lines.
POLICY_LINES=""
POLICY_OUT="$(ns_policy_read_shift "$WORKSPACE")"
POLICY_RC=$?
if [ "$POLICY_RC" -eq 2 ]; then
  warn "shift-policy.json is malformed ($POLICY_OUT); the shift resolves to built-in defaults and rules only"
  act confirm "repair the named field in shift-policy.json, or delete the file so the next Start writes safe defaults"
fi
if POLICY_LINES="$(ns_policy_resolve_table "$WORKSPACE" 2>/dev/null)"; then
  :
else
  POLICY_LINES=""
  warn "the shift policy could not be resolved; treat the shift as built-in defaults plus rules"
fi
# A provisioning transaction on disk means an install stopped mid-flight. The recovery helper
# owns the reading and the proof; Doctor prints its one diagnosis line and never settles it.
if [ -e "$NS/provision-transaction.json" ] || [ -L "$NS/provision-transaction.json" ]; then
  PROVISION_TAB=$(printf '\t')
  if PROVISION_LINE="$("$_here/provision-recover.sh" --project "$WORKSPACE" --diagnose 2>/dev/null)" &&
    [ -n "$PROVISION_LINE" ]; then
    PROVISION_KIND="${PROVISION_LINE%%"$PROVISION_TAB"*}"
    PROVISION_TEXT="${PROVISION_LINE#*"$PROVISION_TAB"}"
    if [ "$PROVISION_KIND" = provable ]; then
      fact "$PROVISION_TEXT"
    else
      warn "$PROVISION_TEXT; Start will refuse to arm"
      act confirm "inspect .nightshift/provision-transaction.json and provision-baseline/, restore by hand or run provision.sh rollback after fixing the target, then Start again"
    fi
  else
    warn "provision-transaction.json cannot be read; Start will refuse to arm"
    act confirm "inspect .nightshift/provision-transaction.json and provision-baseline/, restore by hand or run provision.sh rollback after fixing the target, then Start again"
  fi
fi

PUNCH="$NS/punch-list.md"
OPEN=0
TICKED=0
if [ -f "$PUNCH" ]; then
  OPEN="$(ns_open_boxes "$PUNCH")"
  TICKED="$(ns_ticked_boxes "$PUNCH")"
  fact "punch list open=$OPEN ticked=$TICKED"
else
  warn "punch-list.md is missing"
fi

# Reports gaps between what open items need and what the resolver allows; it never refuses —
# a gap is parked, not blocked.
if ns_policy_json_tool >/dev/null 2>&1; then
  PREFLIGHT_OUT="$("$_here/preflight-needs.sh" --project "$WORKSPACE" 2>/dev/null)" || PREFLIGHT_OUT=""
  if [ -n "$PREFLIGHT_OUT" ]; then
    fact "$(printf '%s\n' "$PREFLIGHT_OUT" | sed -n '1p')"
    fact "$(printf '%s\n' "$PREFLIGHT_OUT" | tail -n1)"
  fi
fi

if ns_receipts_enabled "$WORKSPACE"; then
  fact "completion record per-item receipt"
  # A planted file where receipts/ belongs is reported as itself; do not also warn
  # about missing receipt text for that path.
  if [ "${UNUSABLE_RECV:-0}" -eq 0 ]; then
    MISSING="$(ns_receipts_missing_count "$WORKSPACE" 2>/dev/null)" || MISSING=0
    if [ "${MISSING:-0}" -gt 0 ]; then
      fact "receipts missing model text $MISSING"
      warn "$MISSING ticked items have no receipt text; each item completes through its receipt file"
      act confirm "write the missing receipts under .nightshift/receipts/; Doctor does not rewrite the punch list"
    fi
  fi
else
  fact "completion record none; the owner disabled receipts"
fi

ORDERS="$(ns_open_boxes_file "$NS/work-orders.md")"
if [ "$ORDERS" -gt 0 ]; then
  fact "pending Hunt work orders=$ORDERS"
fi
DRAFTS="$(ns_open_drafts "$NS/drafting-table.md")"
if [ "$DRAFTS" -gt 0 ]; then
  fact "staged drafting-table items=$DRAFTS"
fi

ARMED=0
[ -f "$NS/.shift-armed" ] && ARMED=1
ENDED=0
if [ -f "$NS/.ended" ] && [ ! -L "$NS/.ended" ]; then
  ENDED=1
elif [ -L "$NS/.ended" ]; then
  warn "ended path is not a usable file"
fi
STOP=0
[ -f "$NS/STOP" ] && STOP=1
SESSION_END=0
if [ -f "$NS/.session-end" ] && [ ! -L "$NS/.session-end" ]; then
  SESSION_END=1
elif [ -L "$NS/.session-end" ]; then
  warn "session-end path is not a usable file"
fi
PULSE=0
if [ -f "$NS/.shift-pulse" ] && [ ! -L "$NS/.shift-pulse" ]; then
  PULSE=1
elif [ -L "$NS/.shift-pulse" ]; then
  warn "shift-pulse path is not a usable file"
fi
STALL=""
if [ -L "$NS/.stall" ]; then
  warn "stall path is not a usable file"
elif [ -f "$NS/.stall" ]; then
  STALL="$(tr -d '[:space:]' <"$NS/.stall" 2>/dev/null)"
fi

if [ "$ARMED" -eq 1 ]; then fact "shift is armed"; else fact "shift is not armed"; fi
case "$STATE_KIND" in
  current)
    fact "state version ${STATE_VER:-$NS_STATE_VERSION} (current)"
    ;;
  legacy)
    fact "state version 0 (legacy — no state-version marker)"
    if [ "$ARMED" -eq 1 ]; then
      warn "legacy workspace cannot be migrated while a shift is armed"
      act blocked "wait until the shift is unarmed, then write version 1 with $_here/migrate-state.sh"
    else
      act confirm "write $NS/state-version as 1 with $_here/migrate-state.sh — only the marker is added"
    fi
    ;;
  future)
    warn "state version ${STATE_VER:-unknown} is newer than this plugin supports ($NS_STATE_VERSION)"
    act blocked "upgrade Nightshift; never rewrite or downgrade a newer state-version"
    ;;
  malformed)
    warn "state-version is malformed"
    act confirm "inspect $NS/state-version and replace it with a single integer while unarmed — never guess"
    ;;
esac
[ "$ENDED" -eq 1 ] && fact "gate has clocked the shift out (.ended)"
[ "$STOP" -eq 1 ] && fact "STOP is present"
[ "$SESSION_END" -eq 1 ] && fact "clean session-end marker is present"
[ "$PULSE" -eq 1 ] && fact "shift-pulse marker is present"
[ -n "$STALL" ] && fact "stall count $STALL"

DEADLINE="$NS/deadline"
dl_raw=""
if [ -L "$DEADLINE" ]; then
  warn "deadline path is not a usable file"
elif [ ! -f "$DEADLINE" ]; then
  fact "deadline=none"
else
  dl_raw="$(tr -d '[:space:]' <"$DEADLINE" 2>/dev/null)"
  if printf '%s' "$dl_raw" | grep -qE '^[0-9]+$'; then
    now="$(date +%s)"
    if [ "$now" -ge "$dl_raw" ]; then
      fact "deadline=$dl_raw remaining=0s (elapsed)"
    else
      fact "deadline=$dl_raw remaining=$((dl_raw - now))s"
    fi
  else
    warn "deadline is not a UNIX epoch — watchmen compare integer seconds"
    dl_raw=""
  fi
fi

# shift-policy.json is authoritative for the deadline; the file is a derived projection. A
# mismatch is tampering or a stale projection either way, so Doctor names both values.
POLICY_DEADLINE="$(ns_policy_deadline_epoch "$WORKSPACE" 2>/dev/null)" || POLICY_DEADLINE=""
if [ -n "$dl_raw" ] && [ -n "$POLICY_DEADLINE" ] && [ "$dl_raw" != "$POLICY_DEADLINE" ]; then
  warn "deadline file $dl_raw does not match shift-policy deadlineEpoch $POLICY_DEADLINE; the gate honours the earlier value"
  act confirm "synchronize the deadline projection with the policy before the next arm; Doctor rewrites neither"
fi

if [ "$ARMED" -eq 1 ] && [ "$OPEN" -eq 0 ] && [ "$ENDED" -eq 0 ]; then
  warn "armed with no open boxes and no .ended — clock-out may still be due"
  act confirm "ask Nightshift for status, or start so the watchman can spawn the clock-out"
fi
if [ "$STOP" -eq 1 ] && [ "$ARMED" -eq 1 ]; then
  warn "stop-work order is pending until the next stop attempt"
  act confirm "run $_here/stop-shift.sh --project $HOST to disarm immediately; a bare STOP file waits for the next Stop event; do not delete STOP by hand"
fi
if [ "$STOP" -eq 1 ] && [ "$ARMED" -eq 0 ]; then
  warn "STOP leftover while no shift is armed — start will clear it"
  act confirm "run start when you want a new shift, which clears stale STOP"
fi
if [ -f "$PUNCH" ] && [ "$OPEN" -eq 0 ]; then
  fact "punch list has no open items — leftover Shift contract and Gates still bind the next Hunt or Start cut"
  if [ "$ARMED" -eq 0 ]; then
    warn "empty punch list will inherit the current contract"
    act confirm "review punch-list.md contract and Gates before composing a new campaign; Archive files ticked items but never resets them"
  fi
fi
# Staged work is only an offer when there is nothing already approved to do. An open checkbox
# under ## Items is the shift, so Doctor reports what is staged and stops there — the same
# precedence Start applies, said the same way.
if [ "$ORDERS" -gt 0 ] && [ "$ARMED" -eq 0 ] && [ "$OPEN" -eq 0 ]; then
  act confirm "start to promote a parked Hunt order, or hunt to compose a new one"
fi
if [ "$DRAFTS" -gt 0 ] && [ "$ARMED" -eq 0 ] && [ "$OPEN" -eq 0 ]; then
  act confirm "promote agreed drafting-table items into punch-list.md, or start to be offered them"
fi
if [ "$OPEN" -gt 0 ] && { [ "$ORDERS" -gt 0 ] || [ "$DRAFTS" -gt 0 ]; }; then
  fact "staged work is informational while $OPEN punch-list items are open — start works the current list, and drafts and Hunt orders stay staged for a later shift"
fi

json_is_object() {
  ns_rules_load "$1"
}

json_tool_rule_state() { # $1 = rules file, $2 = exact tool name
  ns_rules_tool_state "$1" "$2"
}

RULES="$NS/rules.json"
if [ ! -f "$RULES" ]; then
  warn "rules.json is missing — watchman will refuse to arm"
  act confirm "re-run setup and accept the shipped rules template"
elif json_is_object "$RULES"; then
  fact "rules.json is a JSON object"
  wm="$(rule "$WORKSPACE" watchMinutes "")"
  case "$wm" in
    '' | *[!0-9]*) warn "watchMinutes missing or not a whole number"; act confirm "restore watchMinutes from the shipped template (10, or 0 to disarm)" ;;
    *) fact "watchMinutes $wm" ;;
  esac
  retry="$(rule "$WORKSPACE" watchRetrySeconds "${NIGHTSHIFT_WATCH_RETRY:-}")"
  resume="$(ns_expand_injected_paths "$WORKSPACE" "$(rule "$WORKSPACE" revivalPrompt "${NIGHTSHIFT_REVIVAL_PROMPT:-}")")"
  fresh="$(ns_expand_injected_paths "$WORKSPACE" "$(rule "$WORKSPACE" freshRevivalPrompt "${NIGHTSHIFT_FRESH_PROMPT:-}")")"
  if [ -z "$retry" ]; then
    warn "watchRetrySeconds is empty — watchman will refuse to arm"
    act confirm "restore watchRetrySeconds from the shipped template"
  fi
  if [ -z "$resume" ]; then
    warn "revivalPrompt is empty — watchman will refuse to arm"
    act confirm "restore revivalPrompt from the shipped template"
  fi
  if [ -z "$fresh" ]; then
    warn "freshRevivalPrompt is empty — watchman will refuse to arm"
    act confirm "restore freshRevivalPrompt from the shipped template"
  fi
  for tool in AskUserQuestion request_user_input AskQuestion; do
    tool_state="$(json_tool_rule_state "$RULES" "$tool")"
    case "$tool_state" in
      allow) fact "toolDeny.$tool explicitly allows the question tool" ;;
      deny) fact "toolDeny.$tool explicitly denies the question tool" ;;
      missing | invalid)
        warn "toolDeny.$tool is $tool_state — question behavior has no explicit policy"
        act confirm "re-run setup and review the shipped $tool entry (non-empty denies; empty allows)"
        ;;
    esac
  done
else
  if [ -n "$NS_RULES_ERR" ]; then
    warn "rules.json is unreadable or not a JSON object ($NS_RULES_ERR)"
  else
    warn "rules.json is unreadable or not a JSON object"
  fi
  act confirm "fix $NS/rules.json or re-run setup — never half-apply a broken file"
fi

HOST_REC="none"
SID=""
TPATH=""
SPID=""
if [ -L "$NS/.shift-session" ]; then
  warn "shift-session path is not a usable file"
elif [ -f "$NS/.shift-session" ]; then
  SID="$(sed -n 1p "$NS/.shift-session" 2>/dev/null || true)"
  TPATH="$(sed -n 2p "$NS/.shift-session" 2>/dev/null || true)"
  SPID="$(sed -n 3p "$NS/.shift-session" 2>/dev/null | tr -d '[:space:]')"
  HOST_REC="$(ns_session_host "$NS")"
  fact "recorded host $HOST_REC"
  if [ -n "$SID" ]; then
    fact "session id is present (not printed)"
    if [ "$HOST_REC" = "codex" ]; then
      kind="$(ns_codex_identity_kind "$SID")"
      fact "Codex identity kind $kind"
      if [ "$kind" != "resumable" ]; then
        warn "recorded Codex identity is $kind — watchman must not claim it resumed that thread"
        act blocked "capture a resumable Codex session id before relying on overnight revival"
      fi
    fi
  else
    warn "session id line is empty"
    act confirm "let the next tool call record identity, or accept a fresh-session fallback"
  fi
  if [ -n "$SPID" ] && printf '%s' "$SPID" | grep -qE '^[0-9]+$'; then
    if kill -0 "$SPID" 2>/dev/null; then
      fact "recorded pid $SPID is alive"
    else
      fact "recorded pid $SPID is dead"
    fi
  fi
else
  fact "no .shift-session yet"
  if [ "$ARMED" -eq 1 ] && [ "$OPEN" -gt 0 ]; then
    warn "armed shift has no session record — a 500 can land before first work"
  fi
fi

LEASE_STATE="absent"
LEASE_GENERATION=""
if [ -e "$NS/.shift-lease" ] || [ -L "$NS/.shift-lease" ]; then
  if ns_lease_valid "$NS"; then
    LEASE_STATE="valid"
    LEASE_HOST="$NS_LEASE_HOST"
    LEASE_GENERATION="$NS_LEASE_GENERATION"
    LEASE_NONCE="$NS_LEASE_NONCE"
    LEASE_PID="$NS_LEASE_PID"
    fact "process lease host $LEASE_HOST generation $LEASE_GENERATION"
    if [ -n "$LEASE_NONCE" ]; then
      fact "process lease belongs to a watchman recovery (capability not printed)"
    else
      fact "process lease belongs to the interactive shift process"
    fi
    if [ "$HOST_REC" != "none" ] && [ "$LEASE_HOST" != "$HOST_REC" ]; then
      warn "process lease host $LEASE_HOST disagrees with recorded session host $HOST_REC"
      act blocked "run $_here/stop-shift.sh --project $HOST, then Start again; do not rewrite the lease by hand"
    fi
    if [ -n "$LEASE_PID" ]; then
      if ns_recorded_process "$LEASE_PID" "$NS_LEASE_START"; then
        fact "lease holder pid $LEASE_PID is alive"
      else
        fact "lease holder pid $LEASE_PID is not confirmed alive"
      fi
    fi
    if [ "$(ns_reason_code "$NS")" = clock-out-failed ]; then
      warn "terminal clock-out failed without releasing the shift"
      if [ -n "$LEASE_NONCE" ]; then
        if [ -n "$LEASE_PID" ] && ns_recorded_process "$LEASE_PID" "$NS_LEASE_START"; then
          fact "recovery worker is alive; the recorded conversation cannot reclaim yet"
          act confirm "wait until the recovery worker exits, or run $_here/stop-shift.sh --project $HOST; reopening the recorded conversation stays blocked while that worker holds the lease"
        else
          fact "recovery worker is not confirmed alive after a failed clock-out; run $_here/stop-shift.sh --project $HOST, then Start"
        fi
      else
        fact "process lease restored to the interactive shift; the recorded conversation can operate"
        act confirm "reopen the recorded conversation to continue or run $_here/stop-shift.sh --project $HOST; Start re-arms after Stop"
      fi
    elif [ -n "$LEASE_NONCE" ] && [ -n "$LEASE_PID" ] && ns_recorded_process "$LEASE_PID" "$NS_LEASE_START"; then
      fact "recovery worker is alive; the recorded conversation cannot reclaim yet"
      act confirm "wait until the recovery worker exits, or run $_here/stop-shift.sh --project $HOST; reopening the recorded conversation stays blocked while that worker holds the lease"
    elif [ -n "$LEASE_NONCE" ] && [ -n "$LEASE_PID" ] && [ -n "$SID" ]; then
      ns_recorded_process "$LEASE_PID" "$NS_LEASE_START"
      rc=$?
      if [ "$rc" -eq 1 ]; then
        fact "lease held by a dead recovery attempt (generation $LEASE_GENERATION, pid $LEASE_PID); the recorded conversation reclaims it on its next tool call"
      fi
    fi
  else
    LEASE_STATE="malformed"
    warn "process lease is malformed — ownership cannot be proven"
    act blocked "run $_here/stop-shift.sh --project $HOST, then Start again; never guess or edit .shift-lease"
  fi
elif [ "$ARMED" -eq 1 ] && [ -n "$SID" ]; then
  warn "armed shift has no process lease — the bound session's next tool call must bootstrap it"
fi

WPID=""
WATCHMAN_UNUSABLE=0
if [ -L "$NS/.watchman" ]; then
  warn "watchman pidfile path is not a usable file"
  WATCHMAN_UNUSABLE=1
elif [ -f "$NS/.watchman" ]; then
  WPID="$(sed -n 1p "$NS/.watchman" 2>/dev/null | tr -d '[:space:]')"
fi
if [ -n "$WPID" ] && printf '%s' "$WPID" | grep -qE '^[0-9]+$'; then
  if kill -0 "$WPID" 2>/dev/null; then
    fact "watchman pid $WPID is alive"
  else
    fact "watchman pid $WPID is stale"
    if [ "$ARMED" -eq 0 ]; then
      act safe "remove leftover .watchman — the recorded process is gone and no shift is armed"
    else
      act confirm "re-run start so the host watchman is armed; do not launch a second copy by hand beside a living one"
    fi
  fi
elif [ "$WATCHMAN_UNUSABLE" -eq 0 ]; then
  fact "no live watchman pid file"
fi

RCODE="$(ns_reason_code "$NS")"
if [ -n "$RCODE" ]; then
  fact "watchman reason $RCODE ($(ns_reason_label "$RCODE"))"
fi

if [ "$ARMED" -eq 1 ] && [ "$OPEN" -gt 0 ] && [ -z "$WPID" ] && [ "$WATCHMAN_UNUSABLE" -eq 0 ]; then
  warn "shift is armed with open boxes and no watchman"
  act confirm "re-run start so the host watchman is armed, or work the list in the live session"
fi

fact "evidence $(ns_evidence_counts "$WORKSPACE")"
fact "liveness $(ns_status_liveness "$NS" "$(rule "$WORKSPACE" watchMinutes "${NIGHTSHIFT_WATCH:-}")")"
activity="$(ns_status_last_activity "$NS")"
if [ -n "$activity" ]; then
  fact "last activity epoch $activity"
else
  fact "last activity none"
fi
fact "last checkpoint $(ns_status_last_checkpoint "$WORKSPACE")"
fact "stall attempts $(ns_status_stall_attempts "$NS")"

# capabilities.json is the tooling cache the shift keeps after a tooling commit lands.
if [ -f "$NS/capabilities.json" ] && [ ! -L "$NS/capabilities.json" ] && command -v jq >/dev/null 2>&1; then
  inv_n="$(jq '.items | length' "$NS/capabilities.json" 2>/dev/null || printf 0)"
  fact "tooling cache items=$inv_n"
fi

[ -n "$TPATH" ] && [ ! -f "$TPATH" ] && warn "recorded transcript/rollout path is not a readable file"

act confirm "export a local support bundle with $_here/export-support.sh — written under $NS/support/, never uploaded"
act blocked "Doctor never repairs, arms, stops, revives, or deletes"

emit "Nightshift Doctor"
emit "Host:        $HOST"
emit "Workspace:   $WORKSPACE"
emit "Link:        $LINK_STATE"
emit "Work target: $TARGET"
emit "Recorded:    ${HOST_REC:-none}"
emit "Lease:       $LEASE_STATE${LEASE_GENERATION:+ (generation $LEASE_GENERATION)}"
emit "State:       ${STATE_VER:--} ($STATE_KIND)"
emit "Armed:       $ARMED  Open: $OPEN  Ticked: $TICKED  STOP: $STOP  Ended: $ENDED"
emit ""
emit "Facts"
printf '%s\n' "${FACTS:-none}"
emit ""
emit "resolved policy"
printf '%s\n' "${POLICY_LINES:-none}"
emit ""
emit "Warnings"
printf '%s\n' "${WARNS:-none}"
emit ""
emit "Actions (Doctor does not perform these)"
printf '%s\n' "${ACTIONS:-none}"
exit 0
