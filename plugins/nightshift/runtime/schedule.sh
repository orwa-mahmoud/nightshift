#!/usr/bin/env bash
# schedule.sh — print the config your OS needs to start a shift at a fixed time.
#
# nightshift does not wait for a clock, and never will: a process that sleeps for hours dies to a
# closed lid, a logout, or a reboot, which is exactly the problem launchd and cron already solve.
# This generates their config, filled in for one project, and prints the single command that
# installs it. It registers nothing itself.
#
#   schedule.sh [--project DIR] [--at HH:MM] [--agent CMD] [--target KIND]
#               [--list] [--remove] [--preflight]
#
#   --at HH:MM   24-hour local time. Required unless --list, --remove, or --preflight.
#   --agent CMD  the headless runner the entry invokes (default: claude -p).
#                Codex projects pass: --agent 'codex exec -s danger-full-access'
#   --target     launchd | cron | systemd. Default is launchd on macOS, cron elsewhere.
#                systemd is generate-only: Nightshift never runs systemctl.
#   --list       what is already registered for this project, and nothing else
#   --remove     print the command that unregisters it
#   --preflight  check the site and both hosts; print a report; write nothing
#                (no --at required). Exit 0 when the shared site is schedulable.
#
# It runs offline and spends no model tokens — a session that has exhausted its credit can still
# register the run that starts when the credit returns.
#
# Exit: 0 printed · 1 usage or a missing project · 3 already registered (nothing printed to install)
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="$PWD"
AT=""
AGENT="claude -p"
MODE="generate"
TARGET=""

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
  exit 1
}
need_value() { [ "$2" -ge 2 ] || { printf 'schedule: %s needs a value\n' "$1" >&2; usage; }; }

# Generated entries are shell source. Quote every value Nightshift supplies; --agent deliberately
# remains an owner-supplied shell command (it may contain its own arguments and redirections).
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project) need_value "$1" $#; PROJECT="$2"; shift 2 ;;
    --at) need_value "$1" $#; AT="$2"; shift 2 ;;
    --agent) need_value "$1" $#; AGENT="$2"; shift 2 ;;
    --target) need_value "$1" $#; TARGET="$2"; shift 2 ;;
    --list) MODE="list"; shift ;;
    --remove) MODE="remove"; shift ;;
    --preflight) MODE="preflight"; shift ;;
    -h | --help) usage ;;
    *) printf 'schedule: unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

cd "$PROJECT" 2>/dev/null || { printf 'schedule: cannot cd to %s\n' "$PROJECT" >&2; exit 1; }
HOST="$(pwd)"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  if ! PROJECT="$(ns_workspace_root "$HOST")"; then
    printf 'schedule: invalid .nightshift-link at %s — Nightshift will not guess a workspace\n' "$HOST" >&2
    exit 1
  fi
else
  PROJECT="$HOST"
fi
[ -d "$PROJECT/.nightshift" ] || {
  printf 'schedule: no .nightshift at %s — run Setup first (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex)\n' "$PROJECT" >&2
  exit 1
}
STATE_KIND="$(ns_state_kind "$PROJECT")"
case "$STATE_KIND" in
  malformed | future)
    printf 'schedule: %s\n' "$(ns_state_refuse_message "$STATE_KIND")" >&2
    exit 1
    ;;
esac

# One id per project PATH, not per folder name: two checkouts called "api" must not collide, and
# the same project must always produce the same id so a second run recognises its own entry.
slug="$(basename "$PROJECT" | tr -c 'A-Za-z0-9' '-' | sed 's/-*$//')"
hash="$(printf '%s' "$PROJECT" | cksum | cut -d' ' -f1)"
ID="${slug}-${hash}"
LABEL="com.nightshift.${ID}"
MARKER="# nightshift:${ID}"
declare LOG PUNCH WORK_ORDERS DRAFTING_TABLE WORK_MODE_FILE
ns_layout_set LOG "$PROJECT/.nightshift" scheduled-log
ns_layout_set PUNCH "$PROJECT/.nightshift" punch-list
ns_layout_set WORK_ORDERS "$PROJECT/.nightshift" work-orders
ns_layout_set DRAFTING_TABLE "$PROJECT/.nightshift" drafting-table
ns_layout_set WORK_MODE_FILE "$PROJECT/.nightshift" work-mode
QPROJECT="$(shell_quote "$PROJECT")"
QSTART="$(shell_quote '/nightshift:start')"
QLOG="$(shell_quote "$LOG")"
RUN="cd $QPROJECT && $AGENT $QSTART >> $QLOG 2>&1"
RUN_XML="$(xml_escape "$RUN")"

case "$(uname -s)" in
  Darwin) OS="macos"; PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist" ;;
  *) OS="cron" ;;
esac
case "$TARGET" in
  '') ;;
  launchd) OS="macos"; PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist" ;;
  cron) OS="cron" ;;
  systemd) OS="systemd" ;;
  *) printf 'schedule: --target must be launchd, cron, or systemd\n' >&2; exit 1 ;;
esac
UNIT="nightshift-${ID}"
SDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE="$SDIR/${UNIT}.service"
TIMER="$SDIR/${UNIT}.timer"
systemd_escape() { printf '%s' "$1" | sed 's/%/%%/g'; }

# Registered already? Two entries for one project means two agents on one punch list — the
# failure the shift's own one-session rule exists to prevent, arriving from outside it.
registered() {
  if [ "$OS" = "macos" ]; then
    [ -f "$PLIST" ] && return 0
    launchctl list 2>/dev/null | grep -qF "$LABEL"
  elif [ "$OS" = "systemd" ]; then
    [ -f "$SERVICE" ] || [ -f "$TIMER" ]
  else
    crontab -l 2>/dev/null | grep -qF "$MARKER"
  fi
}

show_registered() {
  if [ "$OS" = "macos" ]; then
    [ ! -f "$PLIST" ] || printf '  plist:    %s\n' "$PLIST"
    launchctl list 2>/dev/null | grep -F "$LABEL" | sed 's/^/  launchd:  /'
  elif [ "$OS" = "systemd" ]; then
    [ ! -f "$SERVICE" ] || printf '  service:  %s\n' "$SERVICE"
    [ ! -f "$TIMER" ] || printf '  timer:    %s\n' "$TIMER"
  else
    crontab -l 2>/dev/null | grep -F "$MARKER" | sed 's/^/  crontab:  /'
  fi
}

# Artifact notes-folder nights cannot land receipts through a planted path.
# Missing work-mode still reads as repository; a folder Setup would propose as
# artifact must not get a printed job that Start will refuse.
# Return: 0 ok · 1 unusable receipts path · 2 malformed work-mode · 3 unset artifact proposal
check_artifact_receipts() {
  local mode recv proposed
  if mode="$(ns_work_mode "$PROJECT" 2>/dev/null)"; then
    if [ ! -s "$WORK_MODE_FILE" ]; then
      proposed="$(ns_propose_work_mode "$PROJECT" 2>/dev/null)" || proposed=""
      if [ "$proposed" = artifact ]; then
        return 3
      fi
    fi
    if [ "$mode" = artifact ]; then
      recv="$(ns_receipts_dir "$PROJECT")"
      if [ -e "$recv" ] || [ -L "$recv" ]; then
        if ! ns_receipts_usable_dir "$PROJECT" >/dev/null; then
          return 1
        fi
      fi
    fi
    return 0
  fi
  return 2
}

if [ "$MODE" = "list" ]; then
  if registered; then
    printf 'Registered for %s:\n' "$PROJECT"
    show_registered
  else
    printf 'Nothing registered for %s\n' "$PROJECT"
  fi
  exit 0
fi

if [ "$MODE" = "remove" ]; then
  if ! registered; then
    printf 'Nothing registered for %s\n' "$PROJECT"
    exit 0
  fi
  printf 'To unregister:\n\n'
  if [ "$OS" = "macos" ]; then
    printf '  launchctl unload -w %s && rm %s\n\n' "$(shell_quote "$PLIST")" "$(shell_quote "$PLIST")"
  elif [ "$OS" = "systemd" ]; then
    printf '  systemctl --user disable --now %s.timer\n' "$UNIT"
    printf '  rm -f %s %s\n' "$(shell_quote "$SERVICE")" "$(shell_quote "$TIMER")"
    printf '  systemctl --user daemon-reload\n\n'
  else
    printf '  crontab -l | grep -vF %s | crontab -\n\n' "'$MARKER'"
  fi
  exit 0
fi

if [ "$MODE" = "preflight" ]; then
  fail=0
  pf() { printf '%s\n' "$1"; }
  pf "Nightshift schedule preflight"
  pf "Host:      $HOST"
  pf "Workspace: $PROJECT"
  if [ "$HOST" != "$PROJECT" ]; then
    pf "Link:      valid"
  else
    pf "Link:      none (task root is the workspace)"
  fi
  if target="$(ns_work_target "$PROJECT" 2>/dev/null)"; then
    pf "Work:      $target"
  else
    pf "Work:      unresolved (workspace itself will be the cwd)"
    pf "FAIL work target could not be resolved - a scheduled start will refuse to arm"
    fail=1
  fi
  check_artifact_receipts
  _recv_rc=$?
  if [ "$_recv_rc" -eq 1 ]; then
    pf "FAIL artifact receipts path is not a usable directory - a scheduled start will refuse to arm"
    fail=1
  elif [ "$_recv_rc" -eq 2 ]; then
    pf "FAIL work-mode is malformed"
    fail=1
  elif [ "$_recv_rc" -eq 3 ]; then
    pf "FAIL work mode is unset; Setup would propose artifact - a scheduled start will refuse to arm"
    fail=1
  fi

  ns_layout_set RULES "$PROJECT/.nightshift" rules
  if [ ! -f "$RULES" ]; then
    pf "FAIL rules.json is missing"
    fail=1
  elif command -v jq >/dev/null 2>&1 && jq -e 'type == "object"' "$RULES" >/dev/null 2>&1; then
    wm="$(rule "$PROJECT" watchMinutes "")"
    case "$wm" in
      '' | *[!0-9]*) pf "FAIL watchMinutes missing or not a whole number"; fail=1 ;;
      *)
        pf "OK   rules.json (watchMinutes $wm)"
        if [ "$wm" -gt 0 ]; then
          retry="$(rule "$PROJECT" watchRetrySeconds "${NIGHTSHIFT_WATCH_RETRY:-}")"
          resume="$(ns_expand_injected_paths "$PROJECT" "$(rule "$PROJECT" revivalPrompt "${NIGHTSHIFT_REVIVAL_PROMPT:-}")")"
          fresh="$(ns_expand_injected_paths "$PROJECT" "$(rule "$PROJECT" freshRevivalPrompt "${NIGHTSHIFT_FRESH_PROMPT:-}")")"
          if [ -z "$retry" ]; then
            pf "FAIL watchRetrySeconds is empty — watchman will refuse to arm"
            fail=1
          fi
          if [ -z "$resume" ]; then
            pf "FAIL revivalPrompt is empty — watchman will refuse to arm"
            fail=1
          fi
          if [ -z "$fresh" ]; then
            pf "FAIL freshRevivalPrompt is empty — watchman will refuse to arm"
            fail=1
          fi
        fi
        ;;
    esac
  else
    pf "FAIL rules.json is unreadable or not a JSON object"
    fail=1
  fi

  open="$(ns_open_boxes "$PUNCH")"
  if [ "$open" -eq 0 ]; then
    pf "FAIL punch list has no open items — a scheduled start promotes nothing"
    fail=1
    orders="$(ns_open_boxes_file "$WORK_ORDERS")"
    if [ "$orders" -gt 0 ]; then
      pf "NOTE $orders parked Hunt work order(s) — start will not promote them"
    fi
    drafts="$(ns_open_drafts "$DRAFTING_TABLE")"
    if [ "$drafts" -gt 0 ]; then
      pf "NOTE $drafts drafting-table item(s) — start will not promote them"
    fi
  else
    pf "OK   punch list has $open open item(s)"
  fi

  pf "OK   generated label $LABEL"
  pf "OK   run log $LOG"
  if [ "$OS" = "macos" ]; then
    pf "OK   launchd plist path $PLIST"
  else
    pf "OK   cron marker $MARKER"
  fi

  SAMPLE_RUN="cd $QPROJECT && claude -p $QSTART >> $QLOG 2>&1"
  if bash -n <<<"$SAMPLE_RUN" 2>/dev/null; then
    pf "OK   Claude shell entry parses"
  else
    pf "FAIL Claude shell entry is not valid shell"
    fail=1
  fi
  CODEX_RUN="cd $QPROJECT && codex exec -s danger-full-access $QSTART >> $QLOG 2>&1"
  if bash -n <<<"$CODEX_RUN" 2>/dev/null; then
    pf "OK   Codex shell entry parses"
  else
    pf "FAIL Codex shell entry is not valid shell"
    fail=1
  fi

  SAMPLE_XML="$(xml_escape "$SAMPLE_RUN")"
  SAMPLE_PLIST="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
<key>Label</key><string>${LABEL}</string>
<key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>${SAMPLE_XML}</string></array>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>5</integer></dict>
<key>RunAtLoad</key><false/>
</dict></plist>"
  if command -v plutil >/dev/null 2>&1; then
    tmp="$(mktemp -t nightshift-preflight)"
    printf '%s\n' "$SAMPLE_PLIST" >"$tmp"
    if plutil -lint "$tmp" >/dev/null 2>&1; then
      pf "OK   launchd plist syntax"
    else
      pf "FAIL launchd plist syntax"
      fail=1
    fi
    rm -f "$tmp"
  else
    if printf '%s' "$SAMPLE_PLIST" | grep -q '<key>Label</key>' \
      && printf '%s' "$SAMPLE_PLIST" | grep -q '</plist>'; then
      pf "OK   launchd plist structure"
    else
      pf "FAIL launchd plist structure"
      fail=1
    fi
  fi
  CRON_LINE="5 4 * * * ${SAMPLE_RUN}  ${MARKER}"
  if printf '%s' "$CRON_LINE" | grep -Eq '^[0-9]+ [0-9]+ \* \* \* .+ # nightshift:'; then
    pf "OK   cron line syntax"
  else
    pf "FAIL cron line syntax"
    fail=1
  fi

  pf ""
  pf "Claude Code"
  claude_bin="claude"
  if command -v "$claude_bin" >/dev/null 2>&1; then
    pf "OK   binary $(command -v "$claude_bin")"
  else
    pf "WARN claude is not on PATH — a Claude scheduled run cannot start"
  fi
  perm_ok=0
  for f in "$PROJECT/.claude/settings.local.json" "$PROJECT/.claude/settings.json" \
           "$HOST/.claude/settings.local.json" "$HOST/.claude/settings.json"; do
    [ -f "$f" ] || continue
    if grep -q 'bypassPermissions\|allow' "$f" 2>/dev/null; then perm_ok=1; break; fi
  done
  if [ "$perm_ok" -eq 1 ]; then
    pf "OK   headless permissions look granted"
  else
    pf "WARN no bypassPermissions/allow in .claude/settings*.json — a headless Claude run may stall"
  fi

  pf ""
  pf "Codex"
  if command -v codex >/dev/null 2>&1; then
    pf "OK   binary $(command -v codex)"
  else
    pf "WARN codex is not on PATH — a Codex scheduled run cannot start"
  fi
  pf "OK   recommended agent: codex exec -s danger-full-access"
  case "$AGENT" in
    *codex*)
      case "$AGENT" in
        *danger-full-access*|*bypass*) pf "OK   --agent carries a headless sandbox grant" ;;
        *) pf "WARN --agent names Codex without a headless grant; the run may stall on the first tool" ;;
      esac
      ;;
  esac

  if registered; then
    pf ""
    pf "WARN an entry is already registered for this project — generate will refuse a second one"
  fi

  pf ""
  pf "Preflight writes nothing and registers nothing."
  exit "$fail"
fi

case "$AT" in
  [0-2][0-9]:[0-5][0-9]) ;;
  *) printf 'schedule: --at needs a 24-hour HH:MM, got %s\n' "${AT:-nothing}" >&2; exit 1 ;;
esac
HH="${AT%%:*}"; MM="${AT##*:}"
[ "$HH" -le 23 ] || { printf 'schedule: %s is not a valid hour\n' "$HH" >&2; exit 1; }

if registered; then
  printf 'Already registered for this project — nothing to install.\n\n'
  show_registered
  printf '\nTwo entries would put two agents on one punch list. Use --remove first to replace it.\n'
  exit 3
fi

check_artifact_receipts
_recv_rc=$?
if [ "$_recv_rc" -eq 1 ]; then
  printf 'schedule: artifact receipts path is not a usable directory - a scheduled start will refuse to arm\n' >&2
  exit 1
elif [ "$_recv_rc" -eq 2 ]; then
  printf 'schedule: work-mode is malformed\n' >&2
  exit 1
elif [ "$_recv_rc" -eq 3 ]; then
  printf 'schedule: work mode is unset; Setup would propose artifact - a scheduled start will refuse to arm\n' >&2
  exit 1
fi
if ! ns_work_target "$PROJECT" >/dev/null 2>&1; then
  printf 'schedule: work target could not be resolved - a scheduled start will refuse to arm\n' >&2
  exit 1
fi

# The punch list is the shift: a scheduled start works what it finds and promotes nothing, so an
# empty list at %s means the run does nothing at all.
if [ "$(ns_open_boxes "$PUNCH")" -eq 0 ]; then
  printf 'Note: the punch list has no open items. A scheduled start works the list it finds and\n'
  printf 'promotes nothing, so queue the work before %s or the run will find nothing to do.\n' "$AT"
  orders="$(ns_open_boxes_file "$WORK_ORDERS")"
  if [ "$orders" -gt 0 ]; then
    printf 'Parked Hunt work orders: %s (start will not promote them).\n' "$orders"
  fi
  drafts="$(ns_open_drafts "$DRAFTING_TABLE")"
  if [ "$drafts" -gt 0 ]; then
    printf 'Drafting-table items: %s (start will not promote them).\n' "$drafts"
  fi
  printf '\n'
fi

printf 'Scheduled start for %s at %s\n\n' "$PROJECT" "$AT"

if [ "$OS" = "macos" ]; then
  cat <<PLIST_EOF
Write this to $PLIST:

<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>${RUN_XML}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>${HH#0}</integer>
    <key>Minute</key><integer>${MM#0}</integer>
  </dict>
  <key>RunAtLoad</key><false/>
</dict>
</plist>

Then install it:

  launchctl load -w $(shell_quote "$PLIST")

PLIST_EOF
  printf 'A Mac that is asleep at %s runs nothing — launchd defers the job to the next wake.\n' "$AT"
  printf 'To have the machine wake for it: sudo pmset repeat wakeorpoweron MTWRFSU %s:00\n' "$AT"
elif [ "$OS" = "systemd" ]; then
  RUN_SD="$(systemd_escape "$RUN")"
  WD="$(systemd_escape "$PROJECT")"
  QSDIR="$(shell_quote "$SDIR")"
  QSERVICE="$(shell_quote "$SERVICE")"
  QTIMER="$(shell_quote "$TIMER")"
  cat <<SYSTEMD_EOF
Proposed unit files (Nightshift writes none of these):

  $SERVICE
  $TIMER

# ${UNIT}.service
[Unit]
Description=Nightshift scheduled start

[Service]
Type=oneshot
WorkingDirectory="$WD"
ExecStart=/bin/sh -c $(shell_quote "$RUN_SD")

# ${UNIT}.timer
[Unit]
Description=Nightshift scheduled start

[Timer]
OnCalendar=*-*-* ${HH}:${MM}:00
Persistent=true

[Install]
WantedBy=timers.target

Owner actions — Nightshift runs none of these:

  mkdir -p $QSDIR
  # write the two unit files above to those paths
  systemctl --user daemon-reload
  systemctl --user enable --now ${UNIT}.timer
  systemctl --user list-timers ${UNIT}.timer
  systemctl --user disable --now ${UNIT}.timer
  rm -f $QSERVICE $QTIMER
  systemctl --user daemon-reload

SYSTEMD_EOF
else
  cat <<CRON_EOF
Add this line to your crontab (\`crontab -e\`):

  ${MM#0} ${HH#0} * * * ${RUN}  ${MARKER}

Or install it in one command:

  ( crontab -l 2>/dev/null; echo "${MM#0} ${HH#0} * * * ${RUN}  ${MARKER}" ) | crontab -

CRON_EOF
  printf 'A machine that is asleep or off at %s runs nothing — cron does not defer missed jobs.\n' "$AT"
fi

printf '\nCheck what is registered: %s --project %s --list\n' "$(shell_quote "$0")" "$(shell_quote "$PROJECT")"
printf 'Output of each run lands in %s\n' "$LOG"
