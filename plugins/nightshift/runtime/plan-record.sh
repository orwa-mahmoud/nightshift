#!/usr/bin/env bash
# plan-record.sh — who did what to a plan, and whether the revision that would run is approved.
#
#   plan-record.sh [--project DIR] --plan NAME
#   plan-record.sh [--project DIR] --plan NAME --action proposed|approved|reviewed [--by NAME] [--run RUN] [--note TEXT]
#
# With no action, prints the plan's revision, whether the team needs an approval, its state, and
# every line of its record with the name on it (`unknown` for a line written without one). With an
# action, appends one attributed line to staging/records/<key>.md at the plan's current revision.
# The name is --by, or the Git user name of the work target. An approval is refused when the team's
# rules do not let that name's role approve this plan; nothing is written then.
#
# Prints one verdict per line: `ok`, or `refuse` followed by its `repair`.
# Exit: 0 printed or recorded · 1 refused · 2 usage
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
_here="$(cd -P "$_here" && pwd)" || exit 2
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-$PWD}}}"
PLAN=""
ACTION=""
BY=""
RUN_NAME=""
NOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project | --plan | --action | --by | --run | --note)
      [ $# -ge 2 ] || { printf 'plan-record: %s needs a value\n' "$1" >&2; exit 2; }
      case "$1" in
        --project) PROJECT="$2" ;;
        --plan) PLAN="$2" ;;
        --action) ACTION="$2" ;;
        --by) BY="$2" ;;
        --run) RUN_NAME="$2" ;;
        --note) NOTE="$2" ;;
      esac
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 2
      ;;
    *) printf 'plan-record: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$PLAN" ] || { printf 'plan-record: --plan is required\n' >&2; exit 2; }
case "$ACTION" in
  '' | proposed | approved | reviewed) ;;
  *) printf 'plan-record: --action must be proposed, approved or reviewed\n' >&2; exit 2 ;;
esac

ok() { printf 'ok %s\n' "$1"; }
refuse() {
  printf 'refuse %s\n' "$1"
  [ -z "${2:-}" ] || printf 'repair %s\n' "$2"
  exit 1
}

WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || refuse "workspace no workspace at $PROJECT" "run Setup in the project first"
NS="$WORKSPACE/.nightshift"
KEY="$(ns_receipt_slug "$PLAN")"
[ -n "$KEY" ] || refuse "plan $PLAN has no letters or digits to name it by"
ns_plan_record_file "$NS" "$KEY" >/dev/null ||
  refuse "layout this workspace keeps no plan records" "preview the move to run folders with ns migrate-state, make it with --apply"
STATE="$(ns_plan_state "$WORKSPACE" "$KEY")" ||
  refuse "plan no plan named $PLAN in $(ns_layout_name "$NS" plans)" "list the waiting plans with ns plan-enter"

if [ -z "$ACTION" ]; then
  printf '%s\n' "$STATE"
  ns_plan_record_lines "$(ns_plan_record_file "$NS" "$KEY")" |
    awk -F '\t' '{ printf "record %s by %s at %s\n", $1, $2, ($4 == "" ? "unknown" : $4) }'
  exit 0
fi

if [ -z "$BY" ]; then
  TARGET="$(ns_work_target "$WORKSPACE" 2>/dev/null)" || TARGET="$WORKSPACE"
  BY="$(git -C "$TARGET" config user.name 2>/dev/null)" || BY=""
fi
BY="$(printf '%s' "$BY" | tr -d '\r\n')"
[ -n "${BY//[[:space:]]/}" ] || refuse "name no --by and no Git user name to record" "pass --by with the name to put on the record"
case "$BY" in *" · "*) refuse "name $BY holds the record's separator" "pass a name without ' · '" ;; esac

if [ "$ACTION" = approved ]; then
  PROPOSER="$(ns_plan_record_lines "$(ns_plan_record_file "$NS" "$KEY")" | awk -F '\t' '$1 == "proposed" { p = $2 } END { print p }')"
  if ! ns_plan_may_approve "$WORKSPACE" "$BY" "$PROPOSER"; then
    ROLE="$(ns_team_role "$WORKSPACE" "$BY")"
    refuse "approve $BY (${ROLE:-no role}) may not approve this plan; the team's approvers are $(ns_team_list "$WORKSPACE" approvers | paste -sd ',' -)" \
      "ask one of them to approve it"
  fi
fi

EXTRA=()
[ -z "$RUN_NAME" ] || EXTRA+=("run $RUN_NAME")
[ -z "$NOTE" ] || EXTRA+=("note $(printf '%s' "$NOTE" | tr -d '\r\n')")
ns_plan_record_add "$WORKSPACE" "$KEY" "$ACTION" "$BY" ${EXTRA[@]+"${EXTRA[@]}"} ||
  refuse "record could not write $(ns_layout_name "$NS" plan-records)/$KEY.md" "check that .nightshift/ is writable, then run this again"
ok "record $ACTION by $BY at revision $(printf '%s\n' "$STATE" | sed -n 's/^revision //p')"
exit 0
