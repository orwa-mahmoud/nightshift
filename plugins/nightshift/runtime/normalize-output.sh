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

# ---------------------------------------------------------------- jq programs

# Each program prints the stream the renderer reads: one headline line, one
# count line per number worth diffing, one files line, and one item line per row.
# A shape the program does not recognize prints a single error line instead.

# shellcheck disable=SC2016 # jq program; $e/$w/$f/$file are jq bindings
JQ_ESLINT='
def cl: (if . == null then "-" else tostring end) | gsub("[[:cntrl:]]"; " ");
def plu($n; $w): "\($n) \($w)" + (if $n == 1 then "" else "s" end);
# eslint writes severity as a number, and a few formatters write the same number
# as a string. Both mean the same level, so both read as that number.
def sevnum: if type == "number" then . elif type == "string" then (try tonumber catch -1) else -1 end;
def sev: sevnum | if . == 2 then "error" elif . == 1 then "warning" else "note" end;
if type != "array" then "error\tthe report is not a JSON array"
elif ([.[] | (type == "object" and has("messages") and ((.messages | type) == "array"))]
      | index(false)) != null then "error\tthe report is not eslint file results"
else
  ([.[] | .messages[]]) as $m
  | ([$m[] | select((.severity | sevnum) == 2)] | length) as $e
  | ([$m[] | select((.severity | sevnum) == 1)] | length) as $w
  | ([.[] | select((.messages | length) > 0) | .filePath | cl] | unique | length) as $f
  | ( ["headline\teslint: " + plu($e; "error") + ", " + plu($w; "warning")
        + " in " + plu($f; "file")]
    + ["count\terrors\t\($e)", "count\twarnings\t\($w)", "files\t\($f)"]
    + [ .[] as $file | $file.messages[]
        | "item\t" + (.severity | sev) + "\t" + ($file.filePath | cl) + "\t"
          + ((.line // 0) | tostring) + "\t" + (.ruleId | cl) + "\t" + (.message | cl) ]
    ) []
end
'

# shellcheck disable=SC2016 # jq program; $r/$t/$c/$n are jq bindings
JQ_COVERAGE='
def cl: (if . == null then "-" else tostring end) | gsub("[[:cntrl:]]"; " ");
def plu($n; $w): "\($n) \($w)" + (if $n == 1 then "" else "s" end);
# A zero denominator is not full coverage; it is no measurement, and -1 is how
# every reader of these three tells one from the other.
def bp($c; $t): if $t <= 0 then -1 else (($c * 20000 + $t) / (2 * $t) | floor) end;
def pl($c; $t): bp($c; $t) as $b
  | if $b < 0 then "unmeasured"
    else "\($b / 100 | floor).\((100 + ($b % 100)) | tostring | .[1:])%" end;
def band($c; $t): bp($c; $t) as $b
  | if $b < 0 then "info" elif $b < 5000 then "error" elif $b < 8000 then "warning"
    else "note" end;
def num($o; $k): (($o[$k] // 0) | if type == "number" then floor else 0 end);
if type != "object" then "error\tthe report is not a JSON object"
elif (has("total") | not) or ((.total | type) != "object")
     or ((.total | has("lines")) | not) then "error\tthe report has no total.lines block"
else
  . as $r
  | (.total) as $t
  | ([$r | keys[] | select(. != "total")]) as $files
  | ( ["headline\tcoverage: lines " + pl(num($t.lines; "covered"); num($t.lines; "total"))
        + ", statements " + pl(num($t.statements; "covered"); num($t.statements; "total"))
        + ", functions " + pl(num($t.functions; "covered"); num($t.functions; "total"))
        + ", branches " + pl(num($t.branches; "covered"); num($t.branches; "total"))
        + " across " + plu(($files | length); "file")]
    + [ "count\tbranchesCovered\t\(num($t.branches; "covered"))",
        "count\tbranchesTotal\t\(num($t.branches; "total"))",
        "count\tfunctionsCovered\t\(num($t.functions; "covered"))",
        "count\tfunctionsTotal\t\(num($t.functions; "total"))",
        "count\tlinesCovered\t\(num($t.lines; "covered"))",
        "count\tlinesTotal\t\(num($t.lines; "total"))",
        "count\tstatementsCovered\t\(num($t.statements; "covered"))",
        "count\tstatementsTotal\t\(num($t.statements; "total"))",
        "files\t\($files | length)" ]
    + [ $files[] as $k
        | ($r[$k].lines // {}) as $l
        | (num($l; "covered")) as $c | (num($l; "total")) as $n
        | "item\t" + band($c; $n) + "\t" + ($k | cl) + "\t0\tlines\t"
          + "\($c)/\($n) lines covered (" + pl($c; $n) + ")" ]
    ) []
end
'

# shellcheck disable=SC2016 # jq program; $res/$e/$w/$n are jq bindings
JQ_SARIF='
def cl: (if . == null then "-" else tostring end) | gsub("[[:cntrl:]]"; " ");
def plu($n; $w): "\($n) \($w)" + (if $n == 1 then "" else "s" end);
def lvl: (. // "warning") | if . == "error" or . == "warning" or . == "note" then . else "note" end;
def uri: (.locations // [])
  | if length == 0 then "-"
    else (.[0].physicalLocation.artifactLocation.uri // "-") end;
def ln: (.locations // [])
  | if length == 0 then 0 else (.[0].physicalLocation.region.startLine // 0) end;
if type != "object" then "error\tthe report is not a JSON object"
elif (has("runs") | not) or ((.runs | type) != "array")
  then "error\tthe report has no runs array"
elif (has("version") and ((.version | tostring) | startswith("2.1") | not))
  then "error\tthe report is not SARIF 2.1"
else
  ([.runs[] | .results // [] | .[]]) as $res
  | ([$res[] | select((.level | lvl) == "error")] | length) as $e
  | ([$res[] | select((.level | lvl) == "warning")] | length) as $w
  | ([$res[] | select((.level | lvl) == "note")] | length) as $n
  | ([$res[] | uri | cl] | unique | length) as $f
  | ( ["headline\tsarif: " + plu($e; "error") + ", " + plu($w; "warning") + ", "
        + plu($n; "note") + " in " + plu($f; "file")]
    + ["count\terrors\t\($e)", "count\tnotes\t\($n)", "count\twarnings\t\($w)",
       "files\t\($f)"]
    + [ $res[]
        | "item\t" + (.level | lvl) + "\t" + (uri | cl) + "\t" + (ln | tostring) + "\t"
          + (.ruleId | cl) + "\t" + ((.message.text // .message.markdown) | cl) ]
    ) []
end
'

# shellcheck disable=SC2016 # jq program; $r/$names/$c/$h are jq bindings
JQ_AUDIT='
def cl: (if . == null then "-" else tostring end) | gsub("[[:cntrl:]]"; " ");
def plu($n; $w): "\($n) \($w)" + (if $n == 1 then "" else "s" end);
def sev: (. // "info")
  | if . == "critical" or . == "high" or . == "moderate" or . == "low" then . else "info" end;
def title: (.via // [])
  | if length == 0 then "-"
    else (.[0] | if type == "object" then (.title // "-") else tostring end) end;
def fixed: if (.fixAvailable // false) == false then "none" else "available" end;
if type != "object" then "error\tthe report is not a JSON object"
elif (has("advisories") and ((has("auditReportVersion")) | not))
  then "error\tthe report predates npm audit version 7"
elif (has("auditReportVersion") | not) or ((.vulnerabilities | type) != "object")
  then "error\tthe report has no npm audit vulnerabilities object"
else
  . as $r
  | ([.vulnerabilities | keys[]]) as $names
  | ([$names[] | select(($r.vulnerabilities[.].severity | sev) == "critical")] | length) as $c
  | ([$names[] | select(($r.vulnerabilities[.].severity | sev) == "high")] | length) as $h
  | ([$names[] | select(($r.vulnerabilities[.].severity | sev) == "moderate")] | length) as $m
  | ([$names[] | select(($r.vulnerabilities[.].severity | sev) == "low")] | length) as $l
  | ([$names[] | select(($r.vulnerabilities[.].severity | sev) == "info")] | length) as $i
  | ($names | length) as $t
  | ( ["headline\tnpm-audit: " + plu($t; "vulnerable package") + ": \($c) critical, \($h) high, "
        + "\($m) moderate, \($l) low, \($i) info"]
    + ["count\tcritical\t\($c)", "count\thigh\t\($h)", "count\tinfo\t\($i)",
       "count\tlow\t\($l)", "count\tmoderate\t\($m)", "count\ttotal\t\($t)",
       "files\t\($t)"]
    + [ $names[] as $k | $r.vulnerabilities[$k]
        | "item\t" + (.severity | sev) + "\t" + ($k | cl) + "\t0\t"
          + ((.range // "-") | cl) + "\t" + (title | cl) + "; fix: " + fixed ]
    ) []
end
'

# ---------------------------------------------------------------- awk programs

# shellcheck disable=SC2016 # awk program; $0 is an awk field
AWK_TSC='
function nt(s) { gsub(/[\t\r\n]/, " ", s); return s }
BEGIN {
  items = 0; noise = 0; errors = 0; warnings = 0
  summaries = 0; counted = 0
  esc = sprintf("%c", 27)
}
{
  line = $0
  sub(/\r$/, "", line)
  # --pretty colours its diagnostics, and a report captured to a file keeps the
  # escapes. They are decoration: strip them before anything is matched.
  gsub(esc "\\[[0-9;]*[A-Za-z]", "", line)
  if (line ~ /^[ \t]*$/) next
  # file(line,col): error TS1234: message
  p = index(line, "): ")
  head = ""
  rest = ""
  if (p > 0) {
    head = substr(line, 1, p)
    rest = substr(line, p + 3)
  }
  if (p > 0 && head ~ /\([0-9]+,[0-9]+\)$/ && rest ~ /^(error|warning) TS[0-9]+: /) {
    q = 0
    for (i = length(head); i > 0; i--) {
      if (substr(head, i, 1) == "(") { q = i; break }
    }
    file = substr(head, 1, q - 1)
    lc = substr(head, q + 1, length(head) - q - 1)
    split(lc, a, ",")
    emit(rest, file, a[1] + 0)
    next
  }
  # file:line:col - error TS1234: message, which is what --pretty writes. A drive
  # letter puts colons in the path too, so the line and column are taken from the
  # end and everything before them is the file. The header starts a line; the same
  # shape indented is the tail of a diagnostic whose head this input never carried.
  d = index(line, " - ")
  if (d > 0 && line !~ /^[ \t]/) {
    head = substr(line, 1, d - 1)
    rest = substr(line, d + 3)
    if (head ~ /:[0-9]+:[0-9]+$/ && rest ~ /^(error|warning) TS[0-9]+: /) {
      n = split(head, b, ":")
      file = b[1]
      for (i = 2; i <= n - 2; i++) file = file ":" b[i]
      emit(rest, file, b[n - 1] + 0)
      next
    }
  }
  if (line ~ /^(error|warning) TS[0-9]+: /) { emit(line, "-", 0); next }
  if (line ~ /^Found [0-9]+ error/) {
    summaries++
    split(line, f, " ")
    counted = f[2] + 0
    next
  }
  # Every other non-blank line counts, indented continuations included: an input
  # of nothing but continuation lines is a report this parser did not read, not a
  # clean compile.
  noise++
}
function emit(rest, file, ln,   s1, sev, r2, s2, code, msg) {
  s1 = index(rest, " ")
  sev = substr(rest, 1, s1 - 1)
  r2 = substr(rest, s1 + 1)
  s2 = index(r2, " ")
  code = substr(r2, 1, s2 - 2)
  msg = substr(r2, s2 + 1)
  if (sev == "error") errors++; else warnings++
  items++
  printf "item\t%s\t%s\t%d\t%s\t%s\n", sev, nt(file), ln, nt(code), nt(msg)
  if (file != "-") seen[file] = 1
}
END {
  # A watch log is several reports in one file, and none of them describes the
  # whole input. Read it as unavailable rather than as the last one that ran.
  if (summaries > 1) {
    print "error\tthe input holds more than one TypeScript report"
    exit 0
  }
  if (items == 0 && summaries == 0 && noise > 0) {
    print "error\tthe input holds no TypeScript diagnostics"
    exit 0
  }
  # A report that counts its own errors is the authority on how many there were.
  # Reading fewer than it counted means diagnostics in a shape this parser does
  # not know, so the answer is unavailable — never the total rounded down to what
  # happened to parse, and never rows invented to reach the total.
  if (summaries == 1 && counted != errors) {
    printf "error\tthe report counts %d error%s and this parser read %d\n", \
      counted, (counted == 1 ? "" : "s"), errors
    exit 0
  }
  files = 0
  for (k in seen) files++
  printf "headline\ttsc: %d %s, %d %s in %d %s\n", \
    errors, (errors == 1 ? "error" : "errors"), \
    warnings, (warnings == 1 ? "warning" : "warnings"), \
    files, (files == 1 ? "file" : "files")
  printf "count\terrors\t%d\n", errors
  printf "count\twarnings\t%d\n", warnings
  printf "files\t%d\n", files
}
'

# shellcheck disable=SC2016 # awk program; $0 is an awk field
AWK_LCOV='
function nt(s) { gsub(/[\t\r\n]/, " ", s); return s }
BEGIN { sf = ""; lf = 0; lh = 0; have = 0; files = 0; tlf = 0; tlh = 0; noise = 0 }
{
  line = $0
  sub(/\r$/, "", line)
  if (line ~ /^[ \t]*$/) next
  if (line ~ /^SF:/) { sf = substr(line, 4); lf = 0; lh = 0; have = 1; next }
  if (line ~ /^LF:/) { lf = substr(line, 4) + 0; next }
  if (line ~ /^LH:/) { lh = substr(line, 4) + 0; next }
  if (line == "end_of_record") {
    if (have) { record(); have = 0 }
    next
  }
  if (line ~ /^(TN|DA|FN|FNDA|FNF|FNH|BRDA|BRF|BRH|VER):/) next
  noise++
}
# A record with no instrumented lines has nothing to be a percentage of, so -1
# marks it unmeasured for every reader below.
function bp(c, t) { return (t <= 0) ? -1 : int((c * 20000 + t) / (2 * t)) }
function pl(c, t,   b) {
  b = bp(c, t)
  return (b < 0) ? "unmeasured" : sprintf("%d.%02d%%", int(b / 100), b % 100)
}
function band(c, t,   b) {
  b = bp(c, t)
  if (b < 0) return "info"
  return (b < 5000) ? "error" : ((b < 8000) ? "warning" : "note")
}
function record() {
  files++
  tlf += lf
  tlh += lh
  printf "item\t%s\t%s\t0\tlines\t%d/%d lines covered (%s)\n", \
    band(lh, lf), nt(sf), lh, lf, pl(lh, lf)
}
END {
  if (have) record()
  if (files == 0) {
    print "error\tthe input holds no lcov SF records"
    exit 0
  }
  printf "headline\tlcov: %s lines covered, %d/%d in %d %s\n", \
    pl(tlh, tlf), tlh, tlf, files, (files == 1 ? "file" : "files")
  printf "count\tlinesCovered\t%d\n", tlh
  printf "count\tlinesTotal\t%d\n", tlf
  printf "files\t%d\n", files
}
'

# shellcheck disable=SC2016 # awk program; $0 is an awk field
AWK_JUNIT='
function nt(s) { gsub(/[\t\r\n]/, " ", s); return s }
BEGIN {
  doc = ""
  suites = 0; tests = 0; failures = 0; errs = 0; skipped = 0
  depth = 0
  cls = "-"; nm = "-"
  SQ = sprintf("%c", 39)
}
function att(tag, key,   q, v, i) {
  if (!match(tag, "[ \t\r\n]" key "=[\"" SQ "]")) return ""
  q = substr(tag, RSTART + RLENGTH - 1, 1)
  v = substr(tag, RSTART + RLENGTH)
  i = index(v, q)
  if (i == 0) return ""
  return unent(substr(v, 1, i - 1))
}
function unent(s) {
  gsub(/&lt;/, "<", s)
  gsub(/&gt;/, ">", s)
  gsub(/&quot;/, "\"", s)
  gsub("&apos;", SQ, s)
  gsub(/&amp;/, "\\&", s)
  return s
}
# A CDATA section and a comment are payload, not markup. A failure message that
# quotes a suite element would otherwise add phantom suites and phantom rows, so
# both are cut out before anything is split on a bracket. The scan runs left to
# right, which is what keeps a marker inside the other one literal.
function decontent(s,   out, ci, mi, j) {
  out = ""
  while (1) {
    ci = index(s, "<![CDATA[")
    mi = index(s, "<!--")
    if (ci == 0 && mi == 0) break
    if (mi == 0 || (ci > 0 && ci < mi)) {
      out = out substr(s, 1, ci - 1)
      s = substr(s, ci + 9)
      j = index(s, "]]>")
      if (j == 0) return out
      s = substr(s, j + 3)
    } else {
      out = out substr(s, 1, mi - 1)
      s = substr(s, mi + 4)
      j = index(s, "-->")
      if (j == 0) return out
      s = substr(s, j + 3)
    }
  }
  return out s
}
# The element text of one record, ending at the first bracket outside a quoted
# attribute value, so an attribute may carry one and the text content never
# reaches the attribute reader.
function tagtext(rec,   i, c, q) {
  q = ""
  for (i = 1; i <= length(rec); i++) {
    c = substr(rec, i, 1)
    if (q != "") {
      if (c == q) q = ""
      continue
    }
    if (c == "\"" || c == SQ) { q = c; continue }
    if (c == ">") return substr(rec, 1, i - 1)
  }
  return rec
}
# One suite leaves the stack. Only a leaf carries counts: a report that nests its
# suites states the same tests twice, once on the outer suite and once on each
# suite inside it, and adding both reports every test twice.
function pop(   d) {
  if (depth <= 0) return
  d = depth
  depth--
  if (!leaf[d]) return
  suites++
  tests += s_tests[d]
  failures += s_failures[d]
  errs += s_errors[d]
  skipped += s_skipped[d]
}
{ doc = doc $0 "\n" }
END {
  n = split(decontent(doc), rec, "<")
  for (r = 1; r <= n; r++) {
    if (rec[r] == "") continue
    tag = tagtext(rec[r])
    open = tag
    closing = 0
    if (substr(open, 1, 1) == "/") { closing = 1; open = substr(open, 2) }
    name = open
    sub(/[ \t\r\n\/].*$/, "", name)
    if (name == "testsuite") {
      if (closing) { pop(); continue }
      saw = 1
      depth++
      s_tests[depth] = att(tag, "tests") + 0
      s_failures[depth] = att(tag, "failures") + 0
      s_errors[depth] = att(tag, "errors") + 0
      s_skipped[depth] = att(tag, "skipped") + 0
      leaf[depth] = 1
      if (depth > 1) leaf[depth - 1] = 0
      if (substr(tag, length(tag), 1) == "/") pop()
      continue
    }
    if (closing) continue
    if (name == "testcase") {
      cls = att(tag, "classname")
      nm = att(tag, "name")
      if (cls == "") cls = "-"
      if (nm == "") nm = "-"
      continue
    }
    if (name == "failure" || name == "error") {
      t = att(tag, "type")
      printf "item\terror\t%s\t0\t%s\t%s%s\n", \
        nt(cls), name, nt(nm), (t == "" ? "" : " (" nt(t) ")")
      continue
    }
  }
  while (depth > 0) pop()
  if (!saw) {
    print "error\tthe input holds no JUnit testsuite element"
    exit 0
  }
  printf "headline\tjunit: %d %s, %d %s, %d %s, %d skipped in %d %s\n", \
    tests, (tests == 1 ? "test" : "tests"), \
    failures, (failures == 1 ? "failure" : "failures"), \
    errs, (errs == 1 ? "error" : "errors"), \
    skipped, suites, (suites == 1 ? "suite" : "suites")
  printf "count\terrors\t%d\n", errs
  printf "count\tfailures\t%d\n", failures
  printf "count\tskipped\t%d\n", skipped
  printf "count\ttests\t%d\n", tests
  printf "files\t%d\n", suites
}
'

# ---------------------------------------------------------------- the stream

need_jq() {
  command -v jq >/dev/null 2>&1 ||
    unavail 'jq is required to read this format and is not on PATH'
}

case "$FORMAT" in
  eslint-json)
    need_jq
    jq -r "$JQ_ESLINT" <"$INPUT" >"$TMPD/stream" 2>/dev/null ||
      unavail 'the input is not readable JSON'
    ;;
  coverage-summary)
    need_jq
    jq -r "$JQ_COVERAGE" <"$INPUT" >"$TMPD/stream" 2>/dev/null ||
      unavail 'the input is not readable JSON'
    ;;
  sarif)
    need_jq
    jq -r "$JQ_SARIF" <"$INPUT" >"$TMPD/stream" 2>/dev/null ||
      unavail 'the input is not readable JSON'
    ;;
  npm-audit)
    need_jq
    jq -r "$JQ_AUDIT" <"$INPUT" >"$TMPD/stream" 2>/dev/null ||
      unavail 'the input is not readable JSON'
    ;;
  tsc) LC_ALL=C awk "$AWK_TSC" <"$INPUT" >"$TMPD/stream" || unavail 'the input could not be read' ;;
  lcov) LC_ALL=C awk "$AWK_LCOV" <"$INPUT" >"$TMPD/stream" || unavail 'the input could not be read' ;;
  junit) LC_ALL=C awk "$AWK_JUNIT" <"$INPUT" >"$TMPD/stream" || unavail 'the input could not be read' ;;
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
RESULT_PREIMAGE="$(LC_ALL=C awk -v FORMAT="$FORMAT" -F'\t' '
$1 == "headline" { h = $2; next }
$1 == "count" { nc++; cl[nc] = $2; cv[nc] = $3 + 0; next }
END {
  for (i = 2; i <= nc; i++) {
    kl = cl[i]; kv = cv[i]; j = i - 1
    while (j >= 1 && cl[j] > kl) { cl[j + 1] = cl[j]; cv[j + 1] = cv[j]; j-- }
    cl[j + 1] = kl; cv[j + 1] = kv
  }
  printf "normalize-output\t1\t%s\t%s\n", FORMAT, h
  for (i = 1; i <= nc; i++) printf "%s\t%d\n", cl[i], cv[i]
}' <"$TMPD/stream")"
DIGEST="$(printf '%s\n' "$RESULT_PREIMAGE" | ns_policy_sha256_text)" ||
  unavail 'no sha256 tool on this host, so the summary cannot be anchored'

# ---------------------------------------------------------------- rendering

# Every row becomes one sortable line: severity rank descending first, then file,
# line, code and detail ascending. A byte sort over that key is the whole order,
# which is why the two engines agree without either sorting objects.
: >"$TMPD/meta"
LC_ALL=C awk -v META="$TMPD/meta" '
function san(s) {
  gsub(/[^ -~]/, " ", s)
  gsub(/  +/, " ", s)
  sub(/^ +/, "", s)
  sub(/ +$/, "", s)
  if (length(s) > 100) s = substr(s, 1, 97) "..."
  if (s == "") s = "-"
  return s
}
function rank(sev) {
  if (sev == "critical") return 5
  if (sev == "error" || sev == "high") return 4
  if (sev == "warning" || sev == "moderate") return 3
  if (sev == "note" || sev == "low") return 2
  if (sev == "info") return 1
  return 0
}
BEGIN { FS = "\t" }
$1 == "item" {
  sev = san($2)
  printf "%d\t%s\t%09d\t%s\t%s\t%s\n", 5 - rank(sev), san($3), $4 + 0, san($5), san($6), sev
  next
}
{ printf "%s\n", $0 > META }
' "$TMPD/stream" | LC_ALL=C sort >"$TMPD/sorted"

# shellcheck disable=SC2016 # awk program; $1..$6 are awk fields
AWK_RENDER='
function mdesc(s,   i, c, o) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "|") o = o "\\|"
    else o = o c
  }
  return o
}
function jesc(s,   i, c, o) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\"") o = o "\\\""
    else if (c == "\\") o = o "\\\\"
    else o = o c
  }
  return o
}
BEGIN { FS = "\t"; total = 0; n = 0; nc = 0; files = 0; headline = "-"
        INPUT = ENVIRON["NS_NORMALIZE_INPUT"]
        BASENAME = ENVIRON["NS_NORMALIZE_BASENAME"] }
FNR == NR {
  if ($1 == "headline") headline = $2
  else if ($1 == "files") files = $2 + 0
  else if ($1 == "count") { nc++; cl[nc] = $2; cv[nc] = $3 + 0 }
  next
}
{
  total++
  if (n < TOP) {
    n++
    sv[n] = $6; fl[n] = $2; ln[n] = ($3 + 0); cd[n] = $4; ms[n] = $5
  }
}
END {
  for (i = 2; i <= nc; i++) {
    kl = cl[i]; kv = cv[i]; j = i - 1
    while (j >= 1 && cl[j] > kl) { cl[j + 1] = cl[j]; cv[j + 1] = cv[j]; j-- }
    cl[j + 1] = kl; cv[j + 1] = kv
  }
  if (MODE == "json") {
    printf "{\"counts\":{"
    for (i = 1; i <= nc; i++) printf "%s\"%s\":%d", (i > 1 ? "," : ""), jesc(cl[i]), cv[i]
    printf "},\"digest\":\"%s\",\"files\":%d,\"format\":\"%s\",\"headline\":\"%s\"", \
      jesc(DIGEST), files, jesc(FORMAT), jesc(headline)
    printf ",\"input\":\"%s\",\"items\":[", jesc(BASENAME)
    for (i = 1; i <= n; i++) {
      printf "%s{\"code\":\"%s\",\"file\":\"%s\",\"line\":%s,\"message\":\"%s\",\"severity\":\"%s\"}", \
        (i > 1 ? "," : ""), jesc(cd[i]), jesc(fl[i]), \
        (ln[i] == 0 ? "null" : sprintf("%d", ln[i])), jesc(ms[i]), jesc(sv[i])
    }
    printf "],\"shown\":%d,\"source\":\"%s\",\"total\":%d,\"version\":1}\n", \
      n, jesc(SOURCE), total
    exit
  }
  print headline
  print ""
  if (n > 0) {
    print "| severity | file | line | code | detail |"
    print "| --- | --- | --- | --- | --- |"
    for (i = 1; i <= n; i++) {
      printf "| %s | %s | %s | %s | %s |\n", \
        mdesc(sv[i]), mdesc(fl[i]), (ln[i] == 0 ? "-" : sprintf("%d", ln[i])), \
        mdesc(cd[i]), mdesc(ms[i])
    }
    print ""
  }
  printf "showing %d of %d items\n", n, total
  printf "result: sha256:%s\n", DIGEST
  printf "source: %s sha256:%s\n", INPUT, SOURCE
}
'

# _safe_text TEXT — the printable-ASCII, single-spaced form of one line of text.
_safe_text() {
  printf '%s' "$1" | LC_ALL=C tr '\n\r' '  ' | LC_ALL=C awk '
{
  s = $0
  gsub(/[^ -~]/, " ", s)
  gsub(/  +/, " ", s)
  sub(/^ +/, "", s)
  sub(/ +$/, "", s)
  print s
}'
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
  "$AWK_RENDER" "$TMPD/meta" "$TMPD/sorted"

exit 0
