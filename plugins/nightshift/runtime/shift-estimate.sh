#!/usr/bin/env bash
# shift-estimate.sh — size a shift from the owner's own history: the Time and Tokens totals of every
# ticked item's receipt, live and archived.
#
#   shift-estimate.sh --project DIR [--items N]
#
# Prints per-item figures — the median and the range of working time and of tokens (input plus
# output), and how many items each comes from — or says there are too few to estimate from. A
# receipt with no reading for a figure is counted as missing, never as zero. With --items N it adds
# the total for N items, a suggested deadline and a suggested item budget in the punch list's
# `Budget:` syntax. Every figure is an estimate from past receipts, never a limit. Read-only.
#
# Exit: 0 printed · 1 usage/resolve
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

# The fewest readings an estimate is made from.
NS_ESTIMATE_MIN=3

PROJECT=""
ITEMS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'shift-estimate: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --items)
      [ $# -ge 2 ] || { printf 'shift-estimate: --items needs a value\n' >&2; exit 1; }
      ITEMS="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'shift-estimate: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$PROJECT" ] || { printf 'shift-estimate: --project is required\n' >&2; exit 1; }
case "$ITEMS" in '' | [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) ;; *) printf 'shift-estimate: --items takes a whole number from 1 to 999\n' >&2; exit 1 ;; esac

WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || { printf 'shift-estimate: no workspace at %s\n' "$PROJECT" >&2; exit 1; }
NS="$WORKSPACE/.nightshift"
[ -d "$NS" ] && [ ! -L "$NS" ] || { printf 'shift-estimate: no .nightshift/ at %s\n' "$WORKSPACE" >&2; exit 1; }

# One `<work-seconds|-> <tokens|->` line per ticked item's receipt, live then archived.
LIVE=0
ARCHIVED=0
READINGS="$(
  ns_layout_set receipts "$NS" receipts
  ns_receipts_ticked_names "$WORKSPACE" | while IFS= read -r name; do
    [ -n "$name" ] && [ -f "$receipts/$name" ] && [ ! -L "$receipts/$name" ] || continue
    printf 'live %s\n' "$receipts/$name"
  done
  ns_layout_set archive "$NS" archive
  if [ -d "$archive" ] && [ ! -L "$archive" ]; then
    find "$archive" -type f -path '*/receipts/*.md' ! -name 'README.md' ! -name 'morning-*.md' \
      ! -name 'previous-report.md' ! -name 'x-*.md' ! -name '*.original.md' 2>/dev/null | LC_ALL=C sort |
      sed 's/^/archived /'
  fi
)"
SAMPLES=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  where="${line%% *}"
  file="${line#* }"
  cells="$(ns_receipt_usage_cells "$file")"
  IFS=$'\t' read -r in _cw _cr out _rea work _pause usage time <<<"$cells"
  if [ "$time" = '—' ] || [ "${work:-0}" -eq 0 ] 2>/dev/null; then work=-; fi
  if [ "$usage" = '—' ]; then tokens=-; else tokens=$((in + out)); fi
  SAMPLES="$SAMPLES$work $tokens
"
  if [ "$where" = live ]; then LIVE=$((LIVE + 1)); else ARCHIVED=$((ARCHIVED + 1)); fi
done <<<"$READINGS"
TOTAL=$((LIVE + ARCHIVED))

if [ "$TOTAL" -eq 0 ]; then
  printf 'estimate none: no ticked item has a receipt yet\n'
  exit 0
fi
printf 'estimate from %s ticked items: %s live, %s archived\n' "$TOTAL" "$LIVE" "$ARCHIVED"

# stats <column> — `<count> <median> <min> <max>` over the readings in that column, `0` when none.
stats() {
  printf '%s' "$SAMPLES" | awk -v c="$1" '$c != "-" && $c != "" { print $c }' | LC_ALL=C sort -n | awk '
    { v[++n] = $1 }
    END {
      if (n == 0) { print 0; exit }
      if (n % 2) m = v[(n + 1) / 2]
      else m = int((v[n / 2] + v[n / 2 + 1]) / 2)
      print n, m, v[1], v[n]
    }'
}

# ceil_minutes <seconds> — whole minutes up, as the Budget: syntax writes them: `45m`, `1h 30m`.
ceil_minutes() {
  local m=$((($1 + 59) / 60))
  [ "$m" -ge 1 ] || m=1
  if [ "$m" -ge 60 ]; then
    if [ $((m % 60)) -eq 0 ]; then printf '%sh' "$((m / 60))"; else printf '%sh %sm' "$((m / 60))" "$((m % 60))"; fi
  else
    printf '%sm' "$m"
  fi
}

# ceil_tokens <n> — tokens up to one decimal in the unit the Budget: syntax reads: `800k`, `1.3M`.
ceil_tokens() {
  awk -v n="$1" 'BEGIN {
    if (n < 1000000) { k = int((n + 999) / 1000); if (k < 1) k = 1; printf "%dk", k; exit }
    t = int((n + 99999) / 100000)
    if (t % 10) printf "%d.%dM", int(t / 10), t % 10
    else printf "%dM", t / 10
  }'
}

read -r TN TMED TMIN TMAX <<<"$(stats 1)"
read -r KN KMED KMIN KMAX <<<"$(stats 2)"
T_MISSING=$((TOTAL - TN))
K_MISSING=$((TOTAL - KN))

missing_note() { [ "$1" -eq 0 ] || printf ', %s without a reading' "$1"; }

if [ "$TN" -ge "$NS_ESTIMATE_MIN" ]; then
  printf 'time per item: median %s · range %s to %s · from %s items%s\n' \
    "$(ns_usage_duration "$TMED")" "$(ns_usage_duration "$TMIN")" "$(ns_usage_duration "$TMAX")" "$TN" "$(missing_note "$T_MISSING")"
else
  printf 'time per item: too few readings (%s of at least %s)%s\n' "$TN" "$NS_ESTIMATE_MIN" "$(missing_note "$T_MISSING")"
fi
if [ "$KN" -ge "$NS_ESTIMATE_MIN" ]; then
  printf 'tokens per item: median %s · range %s to %s · from %s items%s\n' \
    "$(ns_usage_scale "$KMED")" "$(ns_usage_scale "$KMIN")" "$(ns_usage_scale "$KMAX")" "$KN" "$(missing_note "$K_MISSING")"
else
  printf 'tokens per item: too few readings (%s of at least %s)%s\n' "$KN" "$NS_ESTIMATE_MIN" "$(missing_note "$K_MISSING")"
fi

[ -n "$ITEMS" ] || exit 0
TIME_OK=0
TOKENS_OK=0
[ "$TN" -ge "$NS_ESTIMATE_MIN" ] && TIME_OK=1
[ "$KN" -ge "$NS_ESTIMATE_MIN" ] && TOKENS_OK=1
if [ "$TIME_OK" -eq 0 ] && [ "$TOKENS_OK" -eq 0 ]; then
  printf 'for %s items: no estimate\n' "$ITEMS"
  exit 0
fi
line="for $ITEMS items:"
[ "$TIME_OK" -eq 0 ] || line="$line time $(ns_usage_duration $((TMED * ITEMS))) to $(ns_usage_duration $((TMAX * ITEMS)))"
[ "$TIME_OK" -eq 0 ] || [ "$TOKENS_OK" -eq 0 ] || line="$line ·"
[ "$TOKENS_OK" -eq 0 ] || line="$line tokens $(ns_usage_scale $((KMED * ITEMS))) to $(ns_usage_scale $((KMAX * ITEMS)))"
printf '%s\n' "$line"
# The deadline leaves a quarter over the median total for the items that run long.
[ "$TIME_OK" -eq 0 ] || printf 'suggested deadline: %s from the start\n' "$(ceil_minutes $((TMED * ITEMS * 5 / 4)))"
soft=""
hard=""
if [ "$TIME_OK" -eq 1 ]; then
  soft="$(ceil_minutes "$TMED")"
  hard="$(ceil_minutes "$TMAX")"
fi
if [ "$TOKENS_OK" -eq 1 ]; then
  soft="${soft:+$soft / }$(ceil_tokens "$KMED") tokens"
  hard="${hard:+$hard / }$(ceil_tokens "$KMAX") tokens"
fi
printf 'suggested budget: soft %s, hard %s\n' "$soft" "$hard"
