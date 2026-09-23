#!/usr/bin/env bash
# check-report.sh — validate a cited research report against its source manifest.
#
#   check-report.sh --project DIR --report PATH --manifest PATH [--output PATH...]
#
# Exit: 0 contract held · 1 usage · 2 contract failure
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
REPORT=""
MANIFEST=""
OUTPUTS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'check-report: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --report)
      [ $# -ge 2 ] || { printf 'check-report: --report needs a value\n' >&2; exit 1; }
      REPORT="$2"
      shift 2
      ;;
    --manifest)
      [ $# -ge 2 ] || { printf 'check-report: --manifest needs a value\n' >&2; exit 1; }
      MANIFEST="$2"
      shift 2
      ;;
    --output)
      [ $# -ge 2 ] || { printf 'check-report: --output needs a value\n' >&2; exit 1; }
      OUTPUTS="${OUTPUTS}${OUTPUTS:+
}$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'check-report: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'check-report: cannot cd to %s\n' "$PROJECT" >&2
  exit 1
}

fail() {
  printf 'check-report: %s\n' "$1" >&2
  exit 2
}

resolve_file() {
  case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$HOST/$1" ;; esac
}

require_file() {
  local raw="$1" abs
  abs="$(resolve_file "$raw")"
  if [ -L "$abs" ] || [ ! -f "$abs" ]; then
    fail "missing output: $raw"
  fi
  if [ "$(wc -c <"$abs" | tr -d ' ')" -eq 0 ]; then
    fail "empty output: $raw"
  fi
  printf '%s' "$abs"
}

[ -n "$REPORT" ] || { printf 'check-report: --report is required\n' >&2; exit 1; }
[ -n "$MANIFEST" ] || { printf 'check-report: --manifest is required\n' >&2; exit 1; }

REPORT_ABS="$(require_file "$REPORT")"
MANIFEST_ABS="$(require_file "$MANIFEST")"

if [ -z "$OUTPUTS" ]; then
  OUTPUTS="$REPORT"
fi
while IFS= read -r raw; do
  [ -n "$raw" ] || continue
  require_file "$raw" >/dev/null
done <<EOF
$OUTPUTS
EOF

secret_scan() {
  local f="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    if ns_secret_line "$line"; then
      fail "secret line in $(printf '%s' "$f" | sed "s#$(ns_sed_escape "$HOST")#\$PROJECT#")"
    fi
  done <"$f"
}
secret_scan "$REPORT_ABS"
secret_scan "$MANIFEST_ABS"

for heading in 'Executive summary' 'Sources' 'Observations' 'Inferences'; do
  grep -qiE "^##[[:space:]]*$heading([[:space:]]|$)" "$REPORT_ABS" \
    || fail "missing heading: ## $heading"
done

ids=""
ok_ids=""
unav_ids=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '' | '#'*) continue ;;
  esac
  status="$(printf '%s' "$line" | awk -F'\t' '{print $1}')"
  sid="$(printf '%s' "$line" | awk -F'\t' '{print $3}')"
  locator="$(printf '%s' "$line" | awk -F'\t' '{print $4}')"
  if [ -z "$status" ] || [ -z "$sid" ] || [ -z "$locator" ]; then
    fail "malformed manifest line"
  fi
  case "$sid" in
    S[0-9]*) ;;
    *) fail "manifest id must look like S1: $sid" ;;
  esac
  case "$status" in
    ok | unavailable) ;;
    *) fail "manifest status must be ok or unavailable: $status" ;;
  esac
  ids="${ids}${ids:+
}$sid"
  if [ "$status" = ok ]; then
    ok_ids="${ok_ids}${ok_ids:+
}$sid"
  else
    unav_ids="${unav_ids}${unav_ids:+
}$sid"
  fi
done <"$MANIFEST_ABS"

[ -n "$ids" ] || fail "manifest has no source records"

# Fabricated citations: [S<digits>] not listed in the manifest.
cited="$(grep -oE '\[S[0-9]+\]' "$REPORT_ABS" | tr -d '[]' | sort -u)"
known="$(printf '%s\n' "$ids" | sort -u)"
if [ -n "$cited" ]; then
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    printf '%s\n' "$known" | grep -qxF "$cid" || fail "fabricated citation: [$cid]"
  done <<EOF
$cited
EOF
fi

while IFS= read -r sid; do
  [ -n "$sid" ] || continue
  grep -qF "[$sid]" "$REPORT_ABS" || fail "uncited ok source: $sid"
done <<EOF
$ok_ids
EOF

sources_block="$(awk 'tolower($0) ~ /^##[ \t]*sources([ \t]|$)/ {p=1; next} /^## / {p=0} p' "$REPORT_ABS")"
[ -n "$sources_block" ] || fail "empty Sources section"
while IFS= read -r sid; do
  [ -n "$sid" ] || continue
  printf '%s\n' "$sources_block" | grep -qF "$sid" || fail "unavailable source not recorded: $sid"
done <<EOF
$unav_ids
EOF

exit 0
