#!/usr/bin/env bash
# start-run.sh — start a named plan as a run of its own.
#
#   start-run.sh --project DIR --plan NAME --host claude|codex|cursor [--background]
#
# In a workspace that keeps runs, a plan waiting in staging/plans/ becomes a run. Its folder under
# runs/ is claimed first, named by runs.layout from the plan's title; the plan's punch list is
# written into it with the run's own paths; in repository mode the run is set to work in a git
# worktree of its own (a run rules file holding shift.isolation, unless the run already has one),
# and the Start preflight, snapshot and worktree phases run for it. Only when every step has
# succeeded does the plan leave staging, so a failed step leaves the plan staged and the owner's
# checkout and index as they were, and running this again finishes the run instead of making a
# second one. On a site that shares its plans through Git the plan stays staged as the team's record
# and the run works from its own copy; a teammate's run of the same plan, pulled through Git, is
# never taken over.
#
# Without --background, Start continues in the conversation that asked, with NIGHTSHIFT_RUN set to
# the run printed here. With --background, this arms the run, takes its lease for a headless worker
# started the way the watchman starts a fresh one, and starts the run's watchman; the conversation
# that asked stays free. A run whose lease names a live worker is never started twice.
#
# Prints one verdict per line, as the Start preflight does: `ok run <name>` names the run, then
# `ok`, `warn` or `refuse` lines for each step, each refusal followed by its `repair`.
# Exit: 0 placed (and started, with --background) · 1 refused · 2 usage
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
_here="$(cd -P "$_here" && pwd)" || exit 2
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-$PWD}}}"
PLAN=""
BACKGROUND=0
HOST_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'start-run: --project needs a value\n' >&2; exit 2; }
      PROJECT="$2"
      shift 2
      ;;
    --plan)
      [ $# -ge 2 ] || { printf 'start-run: --plan needs a value\n' >&2; exit 2; }
      PLAN="$2"
      shift 2
      ;;
    --host)
      [ $# -ge 2 ] || { printf 'start-run: --host needs a value\n' >&2; exit 2; }
      HOST_NAME="$2"
      shift 2
      ;;
    --background)
      BACKGROUND=1
      shift
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 2
      ;;
    *) printf 'start-run: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
PLAN="$(printf '%s' "$PLAN" | tr -d '\r\n')"
[ -n "${PLAN//[[:space:]]/}" ] || { printf 'start-run: --plan is required\n' >&2; exit 2; }
case "$HOST_NAME" in
  claude | codex | cursor) ;;
  *) printf 'start-run: --host must be claude, codex or cursor\n' >&2; exit 2 ;;
esac

ok() { printf 'ok %s\n' "$1"; }
warn() { printf 'warn %s\n' "$1"; }
refuse() {
  printf 'refuse %s\n' "$1"
  [ -z "${2:-}" ] || printf 'repair %s\n' "$2"
  exit 1
}

# phase <name> — one Start preflight phase for this run, its verdicts relayed; status 1 on refusal.
phase() {
  local out rc
  if [ "$1" = preflight ]; then
    out="$(bash "$_here/start-preflight.sh" --project "$WORKSPACE" --host "$HOST_NAME" 2>&1)"
  else
    out="$(bash "$_here/start-preflight.sh" --project "$WORKSPACE" --phase "$1" 2>&1)"
  fi
  rc=$?
  printf '%s\n' "$out" | grep -E '^(warn|refuse|explain|repair) ' || :
  [ "$1" != worktree ] || printf '%s\n' "$out" | grep -E '^ok worktree ' || :
  return "$rc"
}

WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || refuse "workspace no workspace at $PROJECT" "run Setup in the project first"
NS="$WORKSPACE/.nightshift"
[ -d "$NS" ] && [ ! -L "$NS" ] || refuse "workspace no .nightshift/ at $WORKSPACE" "run Setup in the project first"
ns_layout_per_run "$NS" punch-list ||
  refuse "layout this workspace keeps one shift at a time" "preview the move to run folders with ns migrate-state, make it with --apply, then run this again"

KEY="$(ns_receipt_slug "$PLAN")"
[ -n "$KEY" ] || refuse "plan $PLAN has no letters or digits to name it by"
PLAN_FILE="$(ns_layout_path "$NS" plans)/$KEY.md"
STAGED=0
if [ -f "$PLAN_FILE" ] && [ ! -L "$PLAN_FILE" ]; then STAGED=1; fi

# ---------------------------------------------------------------- the run
# The run a plan already went into in this clone is reused: its punch list carries the plan's title.
# Otherwise the folder is claimed now, before anything is written, so a second start of the same plan
# finds it.
SHARED_RECEIPTS=0
! ns_site_shares "$WORKSPACE" receipts || SHARED_RECEIPTS=1
RUN=""
while IFS= read -r r; do
  [ -n "$r" ] || continue
  f="$NS/runs/$r/punch-list.md"
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  [ "$SHARED_RECEIPTS" -eq 0 ] || ns_run_is_local "$NS" "$r" || continue
  if [ "$(ns_receipt_slug "$(ns_shift_name "$f")")" = "$KEY" ]; then
    RUN="$r"
    break
  fi
done <<RUNS
$(ns_layout_runs "$NS")
RUNS
if [ -z "$RUN" ]; then
  [ "$STAGED" -eq 1 ] ||
    refuse "plan no plan named $PLAN in $(ns_layout_name "$NS" plans)" "list the waiting plans with ns plan-enter, or open the plan room to write one"
  DIR="$(ns_run_dir "$WORKSPACE" "$(date +%Y-%m-%d)" unknown "$(ns_shift_name "$PLAN_FILE")")" ||
    refuse "run could not claim a run folder under $NS/runs" "check that .nightshift/ is writable, then run this again"
  [ -d "$DIR" ] && [ ! -L "$DIR" ] || refuse "run $DIR is not a plain folder" "move it aside, then run this again"
  RUN="${DIR##*/}"
fi
export NIGHTSHIFT_RUN="$RUN"
ok "run $RUN"

# A run already worked by a live process is not started twice, and nothing of it is redone.
if [ "$BACKGROUND" -eq 1 ] && ns_lease_valid "$NS" && [ -n "${NS_LEASE_PID:-}" ] &&
  ns_recorded_process "$NS_LEASE_PID" "${NS_LEASE_START:-}"; then
  ok "worker already running for $RUN (pid $NS_LEASE_PID)"
  exit 0
fi

# ---------------------------------------------------------------- the punch list
PUNCH="$(ns_layout_path "$NS" punch-list)"
if [ -e "$PUNCH" ] || [ -L "$PUNCH" ]; then
  [ -f "$PUNCH" ] && [ ! -L "$PUNCH" ] && [ "$(ns_receipt_slug "$(ns_shift_name "$PUNCH")")" = "$KEY" ] ||
    refuse "run $RUN already holds another punch list" "pick another plan name, or file that run with Archive first"
  ok "punch-list $(ns_layout_name "$NS" punch-list) holds the plan"
else
  TMP="$PUNCH.tmp.$$"
  # A run the team shares names its paths from the workspace root, so its punch list reads the same
  # in every clone and carries no runner's own folders into Git.
  TEMPLATE_WS="$WORKSPACE"
  [ "$SHARED_RECEIPTS" -eq 0 ] || TEMPLATE_WS=.
  if ! ns_owner_template "$PLAN_FILE" "$TEMPLATE_WS" "$TEMPLATE_WS/.nightshift/runs/$RUN" >"$TMP" 2>/dev/null || ! mv -f "$TMP" "$PUNCH"; then
    rm -f "$TMP"
    refuse "punch-list could not write $(ns_layout_name "$NS" punch-list)" "check that .nightshift/ is writable, then run this again"
  fi
  ok "punch-list the plan is written to $(ns_layout_name "$NS" punch-list)"
fi
SCAFFOLD_OUT="$(bash "$_here/scaffold.sh" --project "$WORKSPACE" 2>&1)" ||
  refuse "scaffold $(printf '%s' "$SCAFFOLD_OUT" | tail -n 1)" "check that .nightshift/ is writable, then run this again"

# ---------------------------------------------------------------- the run's worktree
# Runs share the owner's checkout only through git: each one that writes code works in a worktree
# of its own. The run's own rules file says so, where the owner can read and change it.
if [ "$(ns_work_mode "$WORKSPACE" 2>/dev/null)" != artifact ]; then
  ns_layout_rel_at RULES_REL "$NS_LAYOUT_VERSION" rules ||
    refuse "rules this layout names no rules file" "run ns doctor, then run this again"
  RUN_RULES="$NS/runs/$RUN/$RULES_REL"
  if [ ! -e "$RUN_RULES" ] && [ ! -L "$RUN_RULES" ]; then
    printf '{\n  "shift": {\n    "isolation": "worktree"\n  }\n}\n' >"$RUN_RULES" ||
      refuse "rules could not write $RUN_RULES" "check that .nightshift/ is writable, then run this again"
  fi
fi
phase preflight || refuse "preflight the run was not started" "fix what the preflight named, then run this again"
phase snapshot || refuse "snapshot the run's shift policy could not be recorded" "run ns doctor, then run this again"
phase worktree || refuse "worktree the run has no worktree" "fix what the worktree step named, then run this again"

# unstage — the plan leaves staging, once the run holds everything it needs. A plan the team shares
# stays where teammates read and edit it.
unstage() {
  [ "$STAGED" -eq 1 ] || return 0
  if ns_site_shares "$WORKSPACE" plans; then
    ok "plan $PLAN stays in $(ns_layout_name "$NS" plans) as the team's record; the run works from its own copy"
    return 0
  fi
  rm -f "$PLAN_FILE" || refuse "plan could not take $PLAN_FILE out of staging" "remove it by hand; the run already holds it"
  ok "plan $PLAN left staging"
}

if [ "$BACKGROUND" -eq 0 ]; then
  unstage
  ok "next run Start in this conversation with NIGHTSHIFT_RUN=$RUN"
  exit 0
fi

# ---------------------------------------------------------------- the background worker
case "$HOST_NAME" in
  claude) PROJECT_ENV=CLAUDE_PROJECT_DIR ;;
  codex) PROJECT_ENV=CODEX_PROJECT_DIR ;;
  cursor) PROJECT_ENV=CURSOR_PROJECT_DIR ;;
esac
PROMPT="$(ns_expand_injected_paths "$WORKSPACE" "$(rule "$WORKSPACE" freshRevivalPrompt "${NIGHTSHIFT_FRESH_PROMPT:-}")")"
[ -n "$PROMPT" ] || refuse "rules freshRevivalPrompt is missing from $(ns_layout_name "$NS" rules)" "run Setup again, then run this again"
SCOPE="$(ns_recovery_effective_scope "$WORKSPACE" "$HOST_NAME")"
PROGRAM="$(ns_background_worker_program "$WORKSPACE" "$HOST_NAME" "$SCOPE")" ||
  refuse "worker $NS_WORKER_ERR" "$(ns_recovery_repair "$WORKSPACE" "$SCOPE" 2>/dev/null || printf 'start the run in a conversation instead')"
command -v "$PROGRAM" >/dev/null 2>&1 ||
  refuse "worker $PROGRAM is not installed or not on PATH" "install and sign in to the $HOST_NAME CLI, then run this again"
WORK="$(ns_work_target "$WORKSPACE")" || refuse "worktree the run's work target cannot be resolved" "run ns doctor, then run this again"
ARMED="$(ns_layout_path "$NS" armed)"
: >"$ARMED" || refuse "armed could not write $ARMED" "check that .nightshift/ is writable, then run this again"
OUT="$(ns_layout_path "$NS" shift-log)"
OUT="${OUT%/*}/worker-output.log"
if ! PID="$(ns_start_background_worker "$NS" "$HOST_NAME" "$WORK" "$PROJECT_ENV" "$WORKSPACE" "$OUT" "$SCOPE" "$PROMPT")"; then
  rm -f "$ARMED"
  refuse "worker the $HOST_NAME CLI could not be started headless" "check that $PROGRAM is installed and signed in, then run this again"
fi
printf '%s · shift started in the background (run %s, pid %s)\n' "$(ns_local_now second)" "$RUN" "$PID" >>"$(ns_layout_path "$NS" shift-log)"
ok "worker started for $RUN (pid $PID)"
unstage
if WM="$(bash "$_here/start-watchman.sh" --project "$WORKSPACE" --host "$HOST_NAME" 2>&1)"; then
  ok "$(printf '%s' "$WM" | tail -n 1)"
else
  warn "watchman did not arm for $RUN, so nothing revives its worker if it dies: $(printf '%s' "$WM" | tail -n 1)"
  printf 'repair run NIGHTSHIFT_RUN=%s ns start-watchman --host %s\n' "$RUN" "$HOST_NAME"
fi
exit 0
