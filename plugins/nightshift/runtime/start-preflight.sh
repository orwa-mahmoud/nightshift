#!/usr/bin/env bash
# start-preflight.sh — the Start skill's one preflight. Prints one verdict per line.
#
#   start-preflight.sh --project DIR [--host claude|codex|cursor] [--phase preflight|bind]
#                      [--dry-run]
#
# Verdict grammar, one per line. The verdict sentence is byte-identical on POSIX and native
# Windows; only interpolated paths and a parser's own diagnostic tail differ.
#
#   ok <topic> <detail>      a resolved fact the skill may report
#   warn <topic> <detail>    arm anyway, but say this to the owner
#   refuse <topic> <detail>  do not arm
#   repair <text>            the exact repair for the refusal above it
#
# Phase preflight covers everything before `.shift-armed`; phase bind is the Codex identity
# checkpoint that runs after the binding probe and before the watchman.
#
# Exit: 0 may arm · 1 refused · 2 usage
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
_here="$(cd -P "$_here" && pwd)" || exit 2
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"
# shellcheck source=plugins/nightshift/lib/control.sh
. "$_here/../lib/control.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
HOST_NAME=""
PHASE=preflight
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'start-preflight: --project needs a value\n' >&2; exit 2; }
      PROJECT="$2"; shift 2 ;;
    --host)
      [ $# -ge 2 ] || { printf 'start-preflight: --host needs a value\n' >&2; exit 2; }
      HOST_NAME="$2"; shift 2 ;;
    --phase)
      [ $# -ge 2 ] || { printf 'start-preflight: --phase needs a value\n' >&2; exit 2; }
      PHASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 2 ;;
    *) printf 'start-preflight: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$PHASE" in
  preflight | bind) ;;
  *) printf 'start-preflight: unknown phase: %s\n' "$PHASE" >&2; exit 2 ;;
esac

case "$HOST_NAME" in
  '')
    if [ -n "${CURSOR_PLUGIN_ROOT:-}" ]; then HOST_NAME=cursor
    elif [ -n "${CODEX_PROJECT_DIR:-}${CODEX_SANDBOX:-}${CODEX_SANDBOX_MODE:-}" ]; then HOST_NAME=codex
    elif [ -n "${CLAUDE_PLUGIN_ROOT:-}${CLAUDE_PROJECT_DIR:-}" ]; then HOST_NAME=claude
    else HOST_NAME=unknown
    fi
    ;;
  claude | codex | cursor) ;;
  *) printf 'start-preflight: unknown host: %s\n' "$HOST_NAME" >&2; exit 2 ;;
esac

REFUSED=0
NS_EXPLAIN_FILE="$_here/../lib/preflight-explain.txt"
ok()     { printf 'ok %s\n' "$1"; }
repair() { printf 'repair %s\n' "$1"; }
# A warn or a refuse carries its own explanation, so no verdict site has to remember to print one.
# `ok` lines get none: a resolved fact explains itself.
warn()   { printf 'warn %s\n' "$1"; ns_explain_emit "$(ns_explain_topic "$1")"; }
refuse() { REFUSED=1; printf 'refuse %s\n' "$1"; ns_explain_emit "$(ns_explain_topic "$1")"; }

HOST_ROOT="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  refuse "workspace cannot resolve the project path $PROJECT"
  repair "invoke Start from the host-opened project folder"
  exit 1
}

WORKSPACE="$HOST_ROOT"
if [ -e "$HOST_ROOT/.nightshift-link" ] || [ -L "$HOST_ROOT/.nightshift-link" ]; then
  if WORKSPACE="$(ns_workspace_root "$HOST_ROOT" 2>/dev/null)"; then
    ok "link $HOST_ROOT -> $WORKSPACE"
  else
    refuse "link .nightshift-link does not name one existing Nightshift workspace"
    repair "rewrite .nightshift-link with one absolute path to a directory that already holds .nightshift/, or run link-workspace with an owner-provided path"
    exit 1
  fi
fi

NS="$WORKSPACE/.nightshift"
ok "host $HOST_NAME"
ok "workspace $WORKSPACE"

# The hooks answer for whatever directory the host opened, and the markers this start is about to
# write land under the workspace resolved above. When a host was launched in a parent folder and
# the working directory moved afterwards, those are two different places: the shift would arm in
# one and its session and lease would be recorded against the other. Nightshift does not guess
# which was meant — it names both and refuses before anything is armed.
HOST_PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-}}"
if [ -n "$HOST_PROJECT" ]; then
  HOST_PROJECT_ABS="$(cd -P "$HOST_PROJECT" 2>/dev/null && pwd)" || HOST_PROJECT_ABS=""
  if [ -n "$HOST_PROJECT_ABS" ] && [ "$HOST_PROJECT_ABS" != "$HOST_ROOT" ]; then
    BOUND="$HOST_PROJECT_ABS"
    if [ -e "$HOST_PROJECT_ABS/.nightshift-link" ] || [ -L "$HOST_PROJECT_ABS/.nightshift-link" ]; then
      BOUND="$(ns_workspace_root "$HOST_PROJECT_ABS" 2>/dev/null)" || BOUND="$HOST_PROJECT_ABS"
    fi
    if [ "$BOUND" != "$WORKSPACE" ]; then
      refuse "binding the host opened $HOST_PROJECT_ABS and this start was given $HOST_ROOT, which resolve to different workspaces ($BOUND and $WORKSPACE)"
      # Relaunching is not the only way out. When the owner named the workspace they meant, the
      # link is made from here and this conversation carries on; the link binds the host root
      # rather than this one conversation, which is why it takes their say-so.
      repair "reopen the host on the project you mean, then run Start again"
      repair "or, if $WORKSPACE is the workspace you meant, link it from this session with ns link-workspace --host-root \"$HOST_PROJECT_ABS\" --workspace \"$WORKSPACE\", then run the preflight and the binding probe again - this conversation carries on. The link binds the host root, not this one conversation, which is why it takes the owner's say-so"
      exit 1
    fi
  fi
fi

if [ ! -d "$NS" ] || [ -L "$NS" ]; then
  refuse "workspace no usable .nightshift/ at $WORKSPACE"
  repair "run Nightshift setup in this project before starting a shift"
  exit 1
fi

# ---------------------------------------------------------------- phase bind
# Codex exposes task identity through hook payloads, so the recorded id can only be classified
# after the binding probe has written .shift-session.
if [ "$PHASE" = bind ]; then
  SID="$(ns_session_line "$NS" 1)"
  REC_HOST="$(ns_session_host "$NS")"
  ok "session-host $REC_HOST"
  if [ "$REC_HOST" != codex ]; then
    ok "codex-identity not-applicable"
    exit 0
  fi
  KIND="$(ns_codex_identity_kind "$SID")"
  case "$KIND" in
    resumable)
      ok "codex-identity resumable" ;;
    missing)
      warn "codex-identity missing - same-thread recovery is unavailable until an identity is recorded, so revival falls back to a fresh session whose handover is the punch list" ;;
    *)
      refuse "codex-identity $KIND - the watchman must not claim it resumed that thread"
      repair "remove the markers this start created (.shift-armed and its new .shift-session) and reset the lease in the same call, append one failed-preflight line to shift-log.md, and stop before the watchman or item work" ;;
  esac
  [ "$REFUSED" -eq 0 ] || exit 1
  exit 0
fi

# ------------------------------------------------------------ state version
STATE_KIND="$(ns_state_kind "$WORKSPACE")"
case "$STATE_KIND" in
  current | legacy)
    ok "state-version $(ns_state_version "$WORKSPACE" || true) ($STATE_KIND)" ;;
  *)
    refuse "state-version $(ns_state_refuse_message "$STATE_KIND")"
    repair "Setup or Doctor repairs the marker with migrate-state; Start never writes it" ;;
esac

# --------------------------------------------------------- work mode/target
WORK_MODE=""
if WORK_MODE="$(ns_work_mode "$WORKSPACE" 2>/dev/null)"; then
  ok "work-mode $WORK_MODE"
  if [ ! -s "$NS/work-mode" ]; then
    proposed="$(ns_propose_work_mode "$WORKSPACE" 2>/dev/null)" || proposed=""
    if [ "$proposed" = artifact ]; then
      refuse "work-mode unset and Setup would propose artifact"
      repair "run Setup to record artifact mode; never git init a notes folder to make it a repository"
    fi
  fi
  if [ "$WORK_MODE" = artifact ]; then
    recv="$(ns_receipts_dir "$WORKSPACE")"
    if { [ -e "$recv" ] || [ -L "$recv" ]; } && ! ns_receipts_usable_dir "$WORKSPACE" >/dev/null; then
      refuse "receipts artifact receipts path exists but is not a usable directory"
      repair "replace $recv with a real directory so write-receipt can land"
    fi
  fi
else
  WORK_MODE=""
  refuse "work-mode malformed - the site is unusable until Setup rewrites it"
  repair "run Setup to record repository or artifact as one word"
fi

if WORK_TARGET="$(ns_work_target "$WORKSPACE" 2>/dev/null)"; then
  ok "work-target $WORK_TARGET"
else
  rc=$?
  WORK_TARGET="$WORKSPACE"
  if [ "$rc" -eq 3 ]; then
    refuse "work-target resolves to a disposable scratch path"
    repair "open the project from a persistent folder or Git repository, then run Setup there"
  else
    refuse "work-target cannot be resolved from $WORKSPACE"
    repair "run Setup to record one work target; several child repositories make the choice ambiguous and Nightshift never guesses"
  fi
fi

# ---------------------------------------------------- one shift, one agent
LEASE_STATE=absent
if [ -e "$NS/.shift-lease" ] || [ -L "$NS/.shift-lease" ]; then
  if ns_lease_valid "$NS"; then
    LEASE_STATE=valid
  else
    LEASE_STATE=malformed
    refuse "lease malformed - ownership cannot be proven, so this is unowned state"
    repair "issue STOP, then run ns stop-shift in a terminal and start again; never edit or delete .shift-lease by hand"
    # The owner runs this themselves, in a terminal, after STOP. Never from the blocked session.
    repair "if the lease is still unowned after that, reset it yourself with: bash -c '. \"\$NIGHTSHIFT_PLUGIN_ROOT/lib/lib.sh\"; ns_lease_reset_stale \"\$NIGHTSHIFT_WORKSPACE/.nightshift\"' - a false result is a refusal, not permission to delete the lease directly"
  fi
fi

SESSION_LIVE=0
SESSION_UNKNOWN=0
if ns_session_present "$NS"; then
  s_pid="$(ns_session_line "$NS" 3 | tr -d '[:space:]')"
  s_start="$(ns_session_line "$NS" 4)"
  s_host="$(ns_session_host "$NS")"
  case "$s_pid" in
    '' | *[!0-9]*) ;;
    *)
      ns_recorded_process "$s_pid" "$s_start"
      case "$?" in
        0) SESSION_LIVE=1 ;;
        1) ;;
        *) SESSION_UNKNOWN=1 ;;
      esac
      ;;
  esac
  if [ "$SESSION_LIVE" -eq 1 ]; then
    refuse "session an agent is already working this punch list on $s_host"
    repair "ask Nightshift for status, or pause it with ns stop-shift before starting a second shift"
  elif [ "$SESSION_UNKNOWN" -eq 1 ]; then
    refuse "session process-evidence-unavailable - a pid that kill -0 cannot classify is not a dead session"
    repair "run Start from a shell that can see the recorded process, or pause the shift with ns stop-shift"
  fi
fi

if [ "$LEASE_STATE" = valid ] && ns_lease_pid_live "$NS"; then
  refuse "lease a live process holds generation $NS_LEASE_GENERATION of this shift"
  repair "wait for that worker to exit, or pause the shift with ns stop-shift"
fi

if [ "$(ns_reason_code "$NS")" = clock-out-failed ] && [ "$LEASE_STATE" = valid ] && [ -z "$NS_LEASE_NONCE" ]; then
  warn "lease terminal clock-out failed without releasing the shift - reopen the recorded conversation rather than resetting the lease"
fi

OPEN=0
TICKED=0
if [ -f "$NS/punch-list.md" ] && [ ! -L "$NS/punch-list.md" ]; then
  OPEN="$(ns_open_boxes "$NS/punch-list.md")"
  TICKED="$(ns_ticked_boxes "$NS/punch-list.md")"
fi

WATCHMAN_LIVE=0
if [ -f "$NS/.watchman" ] && [ ! -L "$NS/.watchman" ]; then
  w_pid="$(sed -n 1p "$NS/.watchman" 2>/dev/null | tr -d '[:space:]')"
  w_start="$(sed -n 2p "$NS/.watchman" 2>/dev/null || true)"
  case "$w_pid" in
    '' | *[!0-9]*) ;;
    *) ns_recorded_process "$w_pid" "$w_start" && WATCHMAN_LIVE=1 ;;
  esac
fi
if [ "$WATCHMAN_LIVE" -eq 1 ] && [ -f "$NS/.shift-armed" ] && [ "$OPEN" -gt 0 ]; then
  refuse "watchman a live watchman is recovering this shift, including between recovery attempts"
  repair "ask Nightshift for status, or pause it with ns stop-shift; never kill that watchman as stale"
  # The panic form when the helper cannot be run: it only writes the marker, so the watchman stands
  # down at its next Stop event rather than immediately.
  repair "if you cannot run that, write the marker yourself with: touch \"$NS/STOP\" - the watchman then stands down at its next Stop event"
fi

[ "$REFUSED" -eq 0 ] || exit 1

# ------------------------------------------- cross-host handoff, then reset
if [ "$LEASE_STATE" = valid ]; then
  ns_fence_check "$NS" >/dev/null 2>&1
  case "$?" in
    0) ok "fence takeover allowed - the prior worker is fenced and no duplicate is live" ;;
    1)
      refuse "fence the on-disk fence does not permit takeover"
      repair "pause the shift with ns stop-shift, then start again" ;;
    *)
      refuse "fence the on-disk fence is missing or unreadable"
      repair "pause the shift with ns stop-shift, then start again" ;;
  esac
else
  ok "fence no prior worker to fence"
fi

[ "$REFUSED" -eq 0 ] || exit 1

# A paused shift with a spent deadline never gets a silent new budget.
CONTROL_REASON="$(ns_control_start_refuse_reason "$NS")"
if [ -n "$CONTROL_REASON" ]; then
  refuse "control a paused shift with an expired deadline does not get a silent new budget"
  repair "run Reset then Start, or write the new UNIX epoch yourself; never clear STOP and never invent a time budget"
  exit 1
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if ! ns_control_stop_watchman "$NS"; then
    refuse "watchman a recorded watchman pid could not be verified, so it was left running"
    repair "pause the shift with ns stop-shift, then start again"
    exit 1
  fi
  CLEARED=""
  for m in STOP .stall .notified .ended .session-end .shift-pulse .mint-failed .shift-session .shift-armed .watchman-tick .lock.d; do
    if [ -e "$NS/$m" ] || [ -L "$NS/$m" ]; then
      CLEARED="${CLEARED}${CLEARED:+ }$m"
    fi
  done
  # The finished shift's accounting goes with its markers. Left in place, the next shift would open
  # transcripts at the last shift's offsets and add to its totals, and two nights would be one
  # number nobody could separate. Renamed, not dropped: Archive files it with the rest.
  RETIRED_USAGE="$(ns_usage_retire "$NS" "$(ns_ended_field "$WORKSPACE" shiftId)")" || RETIRED_USAGE=""
  [ -z "$RETIRED_USAGE" ] || CLEARED="${CLEARED}${CLEARED:+ }usage->${RETIRED_USAGE##*/}"
  ns_control_drop "$NS/STOP"
  ns_control_drop_runtime_markers "$NS"
  if ns_control_deadline_passed "$NS"; then
    ns_control_drop "$NS/deadline"
    CLEARED="${CLEARED}${CLEARED:+ }deadline"
  fi
  ok "markers ${CLEARED:-none}"
  ok "lease reset"
else
  ok "markers dry-run"
  ok "lease dry-run"
fi

# ------------------------------------------------------------------- rules
RULES_RC=0
RULES_REASON="$(ns_rules_check "$WORKSPACE")" || RULES_RC=$?
case "$RULES_RC" in
  0) ok "rules readable" ;;
  3)
    refuse "rules rules.json is missing"
    repair "run Setup and accept the shipped rules template" ;;
  *)
    refuse "rules rules.json is not the accepted shape: ${RULES_REASON:-unreadable}"
    repair "fix that named reason in $NS/rules.json or re-run Setup; never half-apply a broken file" ;;
esac

if [ "$RULES_RC" -eq 0 ]; then
  WATCH_MINUTES="$(rule "$WORKSPACE" watchMinutes "${NIGHTSHIFT_WATCH:-}")"
  case "$WATCH_MINUTES" in '' | *[!0-9]*) WATCH_MINUTES=0 ;; esac
  if [ "$WATCH_MINUTES" -gt 0 ]; then
    ok "watch-minutes $WATCH_MINUTES"
    for key in watchRetrySeconds revivalPrompt freshRevivalPrompt; do
      case "$key" in
        watchRetrySeconds) value="$(rule "$WORKSPACE" "$key" "${NIGHTSHIFT_WATCH_RETRY:-}")" ;;
        revivalPrompt) value="$(ns_expand_injected_paths "$WORKSPACE" "$(rule "$WORKSPACE" "$key" "${NIGHTSHIFT_REVIVAL_PROMPT:-}")")" ;;
        *) value="$(ns_expand_injected_paths "$WORKSPACE" "$(rule "$WORKSPACE" "$key" "${NIGHTSHIFT_FRESH_PROMPT:-}")")" ;;
      esac
      if [ -z "$value" ]; then
        refuse "rules $key is empty, so the watchman would refuse to arm"
        repair "restore $key from the shipped rules template with Setup"
      fi
    done
  else
    ok "watch-minutes 0 (watchman disarmed)"
  fi

  # New knobs: the shipped template's top-level keys and its three native question-tool
  # entries. A key the template has and the file lacks means a plugin update brought a knob
  # nobody has reviewed. Start names it once and never adds it.
  NEW_KEYS=""
  TEMPLATE="$_here/../skills/nightshift/references/nightshift-rules-template.json"
  if [ -f "$TEMPLATE" ]; then
    present="$(ns_rules_keys "$NS/rules.json" 2>/dev/null || true)"
    for key in $(ns_rules_keys "$TEMPLATE" 2>/dev/null || true); do
      case "
$present
" in
        *"
$key
"*) ;;
        *) NEW_KEYS="${NEW_KEYS}${NEW_KEYS:+ }$key" ;;
      esac
    done
  fi
  for tool in AskUserQuestion request_user_input AskQuestion; do
    case "$(ns_rules_tool_state "$NS/rules.json" "$tool")" in
      allow | deny) ;;
      *)
        warn "rules toolDeny.$tool has no explicit policy and must be repaired with Setup before that ask tool can run; a non-empty value denies, an empty value allows" ;;
    esac
  done
  [ -z "$NEW_KEYS" ] || warn "rules a plugin update brought knobs this file lacks: $NEW_KEYS - review them with Setup; Start never adds them"
fi

# ----------------------------------------------------------- provisioning
if [ -e "$NS/provision-transaction.json" ] || [ -L "$NS/provision-transaction.json" ]; then
  PROVISION_TAB="$(printf '\t')"
  PROVISION_LINE=""
  if [ -x "$_here/provision-recover.sh" ]; then
    PROVISION_LINE="$("$_here/provision-recover.sh" --project "$WORKSPACE" --diagnose 2>/dev/null)" || PROVISION_LINE=""
  fi
  if [ -n "$PROVISION_LINE" ] && [ "${PROVISION_LINE%%"$PROVISION_TAB"*}" = provable ]; then
    ok "provision an interrupted install is proven recovered"
  else
    refuse "provision an interrupted install cannot be proven recovered"
    repair ".nightshift/provision-transaction.json and provision-baseline/, restore by hand or run ns provision rollback after fixing the target, then Start again"
  fi
else
  ok "provision none pending"
fi

# ---------------------------------------------------------- tonight's policy
# The snapshot reads the same on every host: jq or python3 where one is installed, and the
# bounded reader where neither is. Only a host without awk either has nothing left to read it.
if ns_policy_json_tool >/dev/null 2>&1 || ns_rules_awk_bin >/dev/null 2>&1; then
  POLICY_OUT="$(ns_policy_read_shift "$WORKSPACE")"
  case "$?" in
    2)
      refuse "policy shift-policy.json is malformed: $POLICY_OUT"
      repair "repair the named field in $NS/shift-policy.json, or delete the file so the next Start writes safe defaults" ;;
    *)
      if [ -f "$NS/shift-policy.json" ]; then
        ok "policy resolved"
      else
        warn "policy absent; write one from the remembered project default before arming"
      fi
      ;;
  esac
else
  refuse "policy no reader for tonight's snapshot on this host"
  repair "restore a POSIX text environment, or install jq or python3; a shift never arms on a policy nothing here can read"
fi

# ------------------------------------------------------- work and deadline
ok "punch-list open=$OPEN ticked=$TICKED"
ORDERS="$(ns_open_boxes_file "$NS/work-orders.md")"
DRAFTS="$(ns_open_drafts "$NS/drafting-table.md")"
ok "staged orders=$ORDERS drafts=$DRAFTS"
if [ "$OPEN" -eq 0 ]; then
  if [ "$ORDERS" -gt 0 ] || [ "$DRAFTS" -gt 0 ]; then
    warn "punch-list empty - offer the staged orders and drafts, and cut the owner's choice"
  else
    warn "punch-list empty and nothing is staged - Setup, Hunt, or a hand-written item is the next step"
  fi
fi

# Whether an unattended revival could happen at all, said before the night rather than discovered
# after it. Inheriting means reproducing the scope the session was started under, and a host that
# names none leaves nothing to inherit — so the owner hears now that recovery will refuse, and how
# to authorize one.
RECOVERY_SCOPE="$(ns_recovery_effective_scope "$WORKSPACE" "$HOST_NAME" 2>/dev/null)" || RECOVERY_SCOPE=""
case "$RECOVERY_SCOPE" in
  unavailable:*)
    warn "recovery $(ns_recovery_refusal "$RECOVERY_SCOPE") - an unattended revival will refuse rather than launch at permissions it cannot show are no broader. Set recovery.launchScope to host-default or host-grant in .nightshift/rules.json to authorize one."
    ;;
  '') ;;
  *) ok "recovery revival scope $RECOVERY_SCOPE" ;;
esac

# A shift that asked for filing at clock-out and ended before it could. The next explicit Archive
# is where it gets picked up; Start neither files nor clears it.
if [ -f "$NS/.pending-filing" ] && [ ! -L "$NS/.pending-filing" ]; then
  warn "pending-filing the last shift asked for filing at clock-out and ended before it could - the next explicit Archive picks it up from .nightshift/.pending-filing"
fi

OPEN_ENDED=0
if [ -f "$NS/punch-list.md" ] && [ ! -L "$NS/punch-list.md" ]; then
  ns_items_section "$NS/punch-list.md" | grep -qF 'Ending: open-ended' && OPEN_ENDED=1
fi

DEADLINE_FILE=""
if [ -f "$NS/deadline" ] && [ ! -L "$NS/deadline" ]; then
  DEADLINE_FILE="$(tr -d '[:space:]' <"$NS/deadline" 2>/dev/null || true)"
  case "$DEADLINE_FILE" in '' | *[!0-9]*) DEADLINE_FILE="" ;; esac
fi
POLICY_DEADLINE="$(ns_policy_deadline_epoch "$WORKSPACE" 2>/dev/null)" || POLICY_DEADLINE=""
case "$POLICY_DEADLINE" in *[!0-9]*) POLICY_DEADLINE="" ;; esac

if [ -n "$POLICY_DEADLINE" ]; then
  ok "deadline $POLICY_DEADLINE (policy - write it to $NS/deadline)"
elif [ -n "$DEADLINE_FILE" ]; then
  ok "deadline $DEADLINE_FILE (file - keep it and adopt it as the policy deadlineEpoch)"
elif [ "$OPEN_ENDED" -eq 1 ]; then
  refuse "deadline an open-ended item has no clock, and a walkthrough with no clock never ends"
  repair "compose the shift through Hunt, which asks for hours; never invent a number"
else
  ok "deadline none (finite list - the last tick is the natural end)"
fi

# --------------------------------------------------------------- journal
if [ "$DRY_RUN" -eq 0 ] && [ -f "$NS/shift-log.md" ] && [ ! -L "$NS/shift-log.md" ]; then
  LOG_BYTES="$(wc -c <"$NS/shift-log.md" 2>/dev/null | tr -d '[:space:]')"
  case "$LOG_BYTES" in '' | *[!0-9]*) LOG_BYTES=0 ;; esac
  if [ "$LOG_BYTES" -gt 512000 ]; then
    DAY="$(date +%Y-%m-%d)"
    if mkdir -p "$NS/archive/$DAY" 2>/dev/null && mv "$NS/shift-log.md" "$NS/archive/$DAY/shift-log.md" 2>/dev/null; then
      printf '# Shift log\n' >"$NS/shift-log.md"
      ok "journal rotated to archive/$DAY/shift-log.md"
    fi
  fi
fi

# ------------------------------------------------- host permission mode
case "$HOST_NAME" in
  claude)
    GRANT=0
    for f in "$HOST_ROOT/.claude/settings.local.json" "$HOST_ROOT/.claude/settings.json"; do
      [ -f "$f" ] || continue
      if grep -q 'bypassPermissions\|"allow"' "$f" 2>/dev/null; then GRANT=1; break; fi
    done
    if [ "$GRANT" -eq 1 ]; then
      ok "permissions frictionless permissions are granted at $HOST_ROOT"
    else
      warn "permissions no frictionless grant in $HOST_ROOT/.claude - a permission prompt mid-shift freezes the night and a headless revival is denied outright; Setup offers the fix"
    fi
    ;;
  codex)
    warn "permissions approvals are per launch - an unattended shift is started codex -a never -s danger-full-access, and the workspace-write sandbox blocks git commit; a contract that only ticks needs only workspace-write" ;;
  cursor)
    warn "permissions arm the Cursor watchman only; revival mints or resumes a CLI worker in .shift-worker and never passes the IDE conversation id to agent --resume" ;;
  *)
    ok "permissions host unknown - no permission-mode note" ;;
esac

[ "$REFUSED" -eq 0 ] || exit 1
exit 0
