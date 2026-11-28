#!/usr/bin/env bash
# normalize-output.sh — one tool's raw output as one compact, comparable summary.
#
#   normalize-output.sh --format <fmt> --input <file> [--top N] [--json]
#
# Formats: eslint-json, tsc, coverage-summary, sarif, npm-audit, junit, lcov.
# pytest-junit is an alias of junit: pytest writes JUnit XML, so the two parse
# identically and both report as junit.
#
# Reads the named file and nothing else. Writes nothing, installs nothing, asks
# nothing. The summary is deterministic: the same file always yields the same
# bytes, so two nights diff against each other and `evidence.sh append` can
# carry the result as a finding of domain tool-output.
#
# Two digests travel with a summary. `digest` covers the result — the format, the
# headline and the counts — so a rerun that reports the same numbers keeps one
# digest and a ledger comparison reads it as unchanged. `source` covers the raw
# file byte for byte, which is what anchors the summary to the output it read.
#
# A percentage needs a denominator: a metric whose total is zero reports
# `unmeasured` in the headline, the table and the JSON, never 100%.
#
# Text is reduced to printable ASCII, runs of spaces collapse, and a detail
# longer than 100 characters ends in an ellipsis. Rows sort by severity
# descending, then file, line, code and detail ascending.
#
# Exit: 0 summary · 1 usage · 3 unavailable
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

FORMAT=""
INPUT=""
TOP=10
MODE=md

usage() {
  printf 'usage: normalize-output.sh --format <fmt> --input <file> [--top N] [--json]\n' >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --format)
      [ $# -ge 2 ] || { printf 'normalize-output: --format needs a value\n' >&2; exit 1; }
      FORMAT="$2"
      shift 2
      ;;
    --input)
      [ $# -ge 2 ] || { printf 'normalize-output: --input needs a value\n' >&2; exit 1; }
      INPUT="$2"
      shift 2
      ;;
    --top)
      [ $# -ge 2 ] || { printf 'normalize-output: --top needs a value\n' >&2; exit 1; }
      TOP="$2"
      shift 2
      ;;
    --json)
      MODE=json
      shift
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'normalize-output: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[ -n "$FORMAT" ] || usage
[ -n "$INPUT" ] || usage
case "$TOP" in
  '' | *[!0-9]*) printf 'normalize-output: --top takes a whole number\n' >&2; exit 1 ;;
esac

case "$FORMAT" in
  pytest-junit) FORMAT=junit ;;
esac
case "$FORMAT" in
  eslint-json | tsc | coverage-summary | sarif | npm-audit | junit | lcov) ;;
  *) printf 'normalize-output: unknown format: %s\n' "$FORMAT" >&2; exit 1 ;;
esac

# unavail REASON — the one line a caller reads when nothing was parsed. Never a
# zero-finding summary: a tool that did not report is not a tool that found
# nothing.
unavail() {
  printf 'unavailable %s: %s\n' "$FORMAT" "$1"
  exit 3
}

if [ ! -f "$INPUT" ] || [ ! -r "$INPUT" ]; then
  unavail 'the input is not a readable file'
fi

SOURCE_DIGEST="$(ns_policy_sha256_text <"$INPUT")" ||
  unavail 'no sha256 tool on this host, so the summary cannot be anchored'

TMPD=""
# shellcheck disable=SC2317,SC2329 # trap EXIT invokes this
_cleanup() { [ -z "$TMPD" ] || rm -rf -- "$TMPD"; }
trap _cleanup EXIT
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/nightshift-normalize.XXXXXX")" ||
  unavail 'no writable temporary directory'

# ---------------------------------------------------------------- the parsers

# One program per format sits beside lib.sh (lib/normalize-<name>.jq or .awk), resolved from
# this script's own path. Each prints the stream the renderer reads: one headline line, one
# count line per number worth diffing, one files line, and one item line per row. A shape the
# program does not recognize prints a single error line instead.
PROGRAMS="$_here/../lib"

# ---------------------------------------------------------------- the stream

need_jq() {
  command -v jq >/dev/null 2>&1 ||
    unavail 'jq is required to read this format and is not on PATH'
}

case "$FORMAT" in
  eslint-json)
    need_jq
    jq -r -f "$PROGRAMS/normalize-eslint.jq" <"$INPUT" >"$TMPD/stream" 2>/dev/null ||
      unavail 'the input is not readable JSON'
    ;;
  coverage-summary)
    need_jq
    jq -r -f "$PROGRAMS/normalize-coverage.jq" <"$INPUT" >"$TMPD/stream" 2>/dev/null ||
      unavail 'the input is not readable JSON'
    ;;
  sarif)
    need_jq
    jq -r -f "$PROGRAMS/normalize-sarif.jq" <"$INPUT" >"$TMPD/stream" 2>/dev/null ||
      unavail 'the input is not readable JSON'
    ;;
  npm-audit)
    need_jq
    jq -r -f "$PROGRAMS/normalize-audit.jq" <"$INPUT" >"$TMPD/stream" 2>/dev/null ||
      unavail 'the input is not readable JSON'
    ;;
  tsc) LC_ALL=C awk -f "$PROGRAMS/normalize-tsc.awk" <"$INPUT" >"$TMPD/stream" || unavail 'the input could not be read' ;;
  lcov) LC_ALL=C awk -f "$PROGRAMS/normalize-lcov.awk" <"$INPUT" >"$TMPD/stream" || unavail 'the input could not be read' ;;
  junit) LC_ALL=C awk -f "$PROGRAMS/normalize-junit.awk" <"$INPUT" >"$TMPD/stream" || unavail 'the input could not be read' ;;
esac

REASON="$(LC_ALL=C awk -F'\t' '$1 == "error" { print $2; exit }' <"$TMPD/stream")"
[ -z "$REASON" ] || unavail "$REASON"
LC_ALL=C awk -F'\t' '$1 == "headline" { found = 1 } END { exit found ? 0 : 1 }' \
  <"$TMPD/stream" || unavail 'the input could not be summarized'

# ---------------------------------------------------------------- the digests

# The result digest covers what the run found — the format, the headline and every
# count, in label order — and nothing about the bytes it read. Two runs that report
# the same numbers therefore carry one digest, and a ledger comparison reads a
# reformatted or rerun report as unchanged rather than as a regression.
RESULT_PREIMAGE="$(LC_ALL=C awk -v FORMAT="$FORMAT" -F'\t' -f "$PROGRAMS/normalize-digest.awk" <"$TMPD/stream")"
DIGEST="$(printf '%s\n' "$RESULT_PREIMAGE" | ns_policy_sha256_text)" ||
  unavail 'no sha256 tool on this host, so the summary cannot be anchored'

# ---------------------------------------------------------------- rendering

# Every row becomes one sortable line: severity rank descending first, then file,
# line, code and detail ascending. A byte sort over that key is the whole order,
# which is why the two engines agree without either sorting objects.
: >"$TMPD/meta"
LC_ALL=C awk -v META="$TMPD/meta" -f "$PROGRAMS/normalize-rows.awk" "$TMPD/stream" | LC_ALL=C sort >"$TMPD/sorted"

# _safe_text TEXT — the printable-ASCII, single-spaced form of one line of text.
_safe_text() {
  printf '%s' "$1" | LC_ALL=C tr '\n\r' '  ' | LC_ALL=C awk -f "$PROGRAMS/normalize-text.awk"
}

# The JSON body names the file, not the path that reached it: a summary written
# from a temporary checkout has to compare against one written from a clone.
INPUT_BASENAME="${INPUT##*/}"
INPUT_BASENAME="${INPUT_BASENAME##*\\}"

SAFE_INPUT="$(_safe_text "$INPUT")"
SAFE_BASENAME="$(_safe_text "$INPUT_BASENAME")"

NS_NORMALIZE_INPUT="$SAFE_INPUT" NS_NORMALIZE_BASENAME="$SAFE_BASENAME" \
  LC_ALL=C awk -v TOP="$TOP" -v MODE="$MODE" -v FORMAT="$FORMAT" -v DIGEST="$DIGEST" \
  -v SOURCE="$SOURCE_DIGEST" \
  -f "$PROGRAMS/normalize-render.awk" "$TMPD/meta" "$TMPD/sorted"

exit 0
