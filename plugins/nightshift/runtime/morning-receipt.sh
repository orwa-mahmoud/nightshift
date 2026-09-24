#!/usr/bin/env bash
# morning-receipt.sh — the compact receipt for one shift, in Markdown.
#
#   morning-receipt.sh --project DIR [--view owner|reviewer|release|artifact] [--out PATH]
#
# Without --view, the owner's handoff.view decides; handoff.sections picks and orders the
# documented sections when it is not empty. Presentation only: a section the owner dropped
# changes what the page shows, never what was measured.
#
# Renders from records only: the findings ledger, the shift policy that ran (the live file or the
# archived snapshot), the resolved policy, the punch list, the usage marks, the shift log, the
# parking lot, the snag log, the opportunity map, the work target's history and the shift markers.
# It measures nothing, reruns nothing, and never renders a check the owner disabled as one that
# passed. Eleven sections in a fixed order, each omitted when it is empty; the view chooses which
# of them a reader gets:
#
#   owner     every section
#   reviewer  review first, baseline, what changed
#   release   how it ended, and what changed filtered to regressions
#   artifact  every section but baseline and what changed, in the vocabulary of a site rather
#             than a repository
#
# Without --out the Markdown goes to stdout; with it the file is written by rename and its path
# is printed. NIGHTSHIFT_COMPARE_HELPER overrides the comparison helper's path —
# a session lever for the suite, never policy.
# Exit: 0 ok · 1 usage · 2 contract failure
set -u

_ns_src="${BASH_SOURCE[0]//\\//}"
case "$_ns_src" in
  [A-Za-z]:/*)
    _ns_drive=$(printf '%s' "${_ns_src%"${_ns_src#?}"}" | tr '[:upper:]' '[:lower:]')
    _ns_src="/${_ns_drive}${_ns_src#?:}"
    ;;
esac
_here="$(cd -P -- "$(dirname -- "$_ns_src")" && pwd)" || exit 2
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

EMIT_JQ="$_here/morning-receipt-emit.jq"
# Native Windows jq.exe cannot open a /d/... program path. The display form is
# the Windows path here and the same POSIX path everywhere else.
EMIT_JQ="$(ns_native_display_path "$EMIT_JQ")"
# The text half: it reads the Markdown records, the shift log and the history into rows.
READ_AWK="$_here/morning-receipt-read.awk"
COMPARE="${NIGHTSHIFT_COMPARE_HELPER:-$_here/evidence-compare.sh}"

NL='
'
FS=$(printf '\037')
RS=$(printf '\036')
DASH=$(printf '\xe2\x80\x94')
ARROW=$(printf '\xe2\x86\x92')
MIDDOT=$(printf '\xc2\xb7')

# The ledger cells the receipt draws, in slot order. morning-receipt-emit.jq is handed the same
# list, so neither half hard-codes the other.
RFIELDS="id
domain
sourceClass
source
scope
status
ladder
locator
rawDigest
lastChecked
action
fix
verificationLocator
host
digest"

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0" >&2
  exit 1
}

die() {
  printf 'morning-receipt: %s\n' "$1" >&2
  exit "$2"
}

# ---------------------------------------------------------------- arguments

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
VIEW=""
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || usage
      PROJECT="$2"
      shift 2
      ;;
    --view)
      [ $# -ge 2 ] || usage
      VIEW="$2"
      shift 2
      ;;
    --out)
      [ $# -ge 2 ] || usage
      OUT="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    *)
      printf 'morning-receipt: unknown argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done

# An explicit --view wins; without one the owner's configured reader decides, and that is
# resolved after the workspace is known.
case "${VIEW:-owner}" in
  owner | reviewer | release | artifact) ;;
  *) die 'view must be owner, reviewer, release, or artifact' 1 ;;
esac

PROJECT="$(ns_msys_path "$PROJECT")"
HOST_DIR="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || die "cannot cd to $PROJECT" 1
WORKSPACE="$HOST_DIR"
if [ -e "$HOST_DIR/.nightshift-link" ] || [ -L "$HOST_DIR/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)" ||
    die 'invalid .nightshift-link — Nightshift will not guess a workspace' 2
fi
NS="$WORKSPACE/.nightshift"
[ -d "$NS" ] || die "no .nightshift/ at $WORKSPACE — run setup first" 2

JSONL="$NS/evidence/findings.jsonl"
PUNCH="$NS/punch-list.md"
LOT="$NS/parking-lot.md"
SNAGS="$NS/snag-log.md"
LOG="$NS/shift-log.md"
MAP="$NS/opportunity-map.md"
STOP="$NS/STOP"
RECEIPTS_DIR="$(ns_receipts_dir "$WORKSPACE")"

JSON_TOOL=""
if command -v jq >/dev/null 2>&1; then
  JSON_TOOL=jq
elif command -v python3 >/dev/null 2>&1; then
  JSON_TOOL=python3
else
  die 'JSON parser unavailable; write the morning receipt in the skill' 2
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/ns-receipt.XXXXXX")" || die 'cannot create a temporary directory' 2
chmod 700 "$TMPD" || {
  rm -rf "$TMPD"
  die 'cannot create a temporary directory' 2
}
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------- small helpers

# _scrub TEXT -> SCRUBBED: control characters become spaces, the ends are trimmed. Ledger cells
# arrive scrubbed already; owner-authored Markdown comes through here.
_scrub() {
  SCRUBBED="$(printf '%s' "$1" | sed 's/[[:cntrl:]]/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
}

# _order KEYFILE -> ORDER: the positions in KEYFILE, byte-ordered by its sort key. Every table
# is drawn from one of these, so no table can come out in filesystem order.
_order() {
  ORDER=""
  [ -s "$1" ] || return 0
  ORDER="$(LC_ALL=C sort "$1" | cut -d "$FS" -f2)"
}

# _join_sorted FILE SEP -> JOINED: the file's lines, byte-ordered, de-duplicated, joined.
_join_sorted() {
  local line out=""
  JOINED=""
  [ -s "$1" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -z "$out" ] || out="$out$2"
    out="$out$line"
  done <<EOF
$(LC_ALL=C sort -u "$1")
EOF
  JOINED="$out"
}

JOINER=" $DASH "
SOURCE_SEP=', '
NONE='none'
GATES_FROM='punch list'
NO_POLICY='no shift policy was written'
POLICY_MALFORMED='the policy file is present but unreadable or fails the schema'
POLICY_KIND=absent
REVIEW_ARTIFACT='Does not apply: an artifact shift is reviewed through its receipts.'

# _short_digest FULL -> SHORT_DIGEST: the first twelve hex chars PowerShell shows.
_short_digest() {
  SHORT_DIGEST=""
  [ -n "$1" ] || return 0
  if [ "${#1}" -le 12 ]; then
    SHORT_DIGEST="$1"
  else
    SHORT_DIGEST="${1:0:12}"
  fi
}

# _md_cell TEXT -> MD_CELL: one comparison-table cell; empty reads as an em dash.
_md_cell() {
  if [ -z "$1" ]; then
    MD_CELL="$DASH"
  else
    MD_CELL="${1//|/\\|}"
  fi
}

# _utc_stamp EPOCH -> UTC_STAMP: that moment in UTC to the second, zone included.
_utc_stamp() {
  UTC_STAMP=""
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  UTC_STAMP="$(date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
    date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  [ -n "$UTC_STAMP" ]
}

# _count N NOUN -> COUNTED: "1 file", "3 files".
_count() {
  if [ "$1" = 1 ]; then COUNTED="1 $2"; else COUNTED="$1 $2s"; fi
}

# _item_link LABEL ID -> ITEM_LINK: the label, linked to its item receipt when that file exists.
_item_link() {
  local base
  ITEM_LINK="$1"
  base="$(ns_receipt_base "$WORKSPACE" "$1" "$2")"
  [ -n "$base" ] && [ -n "$RECEIPTS_DIR" ] || return 0
  [ -f "$RECEIPTS_DIR/$base.md" ] && [ ! -L "$RECEIPTS_DIR/$base.md" ] || return 0
  ITEM_LINK="[$1](./$base.md)"
}

# _shift_log_lines interruptions|handover — shift-log lines written since the last `shift started`:
# every interruption the runtime recorded, or the last handover line.
_shift_log_lines() {
  [ -f "$LOG" ] && [ ! -L "$LOG" ] || return 0
  sed 's/[[:cntrl:]]/ /g' "$LOG" | awk -v op="$1" -f "$READ_AWK"
}

# _gate_commands -> $TMPD/gates: backtick commands under ## Gates, byte-ordered.
_gate_commands() {
  local in_gates=0 line rest cmd
  : >"$TMPD/gates"
  [ -f "$PUNCH" ] && [ ! -L "$PUNCH" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "## Gates"*) in_gates=1; continue ;;
      "## "*) [ "$in_gates" -eq 1 ] && break; continue ;;
    esac
    [ "$in_gates" -eq 1 ] || continue
    rest="$line"
    while [ -n "$rest" ]; do
      case "$rest" in
        *'`'*)
          rest="${rest#*\`}"
          cmd="${rest%%\`*}"
          rest="${rest#*\`}"
          [ -n "$cmd" ] && printf '%s\n' "$cmd" >>"$TMPD/gates"
          ;;
        *) break ;;
      esac
    done
  done <"$PUNCH"
}

# _commit_count -> COMMIT_COUNT: commits on the work target since the shift started.
_commit_count() {
  local target count
  COMMIT_COUNT=""
  [ -n "$SHIFT_SINCE" ] || return 0
  target="$(ns_work_target "$WORKSPACE" 2>/dev/null)" || target=""
  [ -n "$target" ] || return 0
  target="$(ns_msys_path "$target")"
  count="$(cd -P "$target" 2>/dev/null && git rev-list --count --since "$SHIFT_SINCE" HEAD)" || return 0
  case "$count" in
    '' | *[!0-9]*) return 0 ;;
  esac
  COMMIT_COUNT="$count"
}

# _session_host -> SESSION_HOST: the bound session, else the last record host.
_session_host() {
  local i host
  SESSION_HOST=""
  if [ -f "$NS/.shift-session" ] && [ ! -L "$NS/.shift-session" ]; then
    host="$(ns_session_line "$NS" 5 2>/dev/null | tr -d '[:space:]')"
    [ -n "$host" ] && SESSION_HOST="$host" && return 0
  fi
  i=0
  while [ "$i" -lt "$NREC" ]; do
    [ -n "${R_HOST[$i]}" ] && SESSION_HOST="${R_HOST[$i]}"
    i=$((i + 1))
  done
}

# _policy_profile -> POLICY_PROFILE: the defaults profile, or fast when unset.
_policy_profile() {
  POLICY_PROFILE=fast
  if ns_policy_read_defaults "$WORKSPACE" >/dev/null 2>&1; then
    POLICY_PROFILE="${NS_POLICY_DEF_PROFILE#\"}"
    POLICY_PROFILE="${POLICY_PROFILE%\"}"
    [ -n "$POLICY_PROFILE" ] || POLICY_PROFILE=fast
  fi
}

# ---------------------------------------------------------------- JSON bridge

PY='
import json, re, sys

OP = sys.argv[1]


def scrub(s):
    return re.sub(r"[\x00-\x1f\x7f]", " ", s)


def canon(v):
    return json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def cell(v):
    if v is None:
        text = ""
    elif isinstance(v, str):
        text = v
    elif v is True:
        text = "true"
    elif v is False:
        text = "false"
    else:
        text = canon(v)
    return scrub(text)


def field(rec, key):
    return rec.get(key) if isinstance(rec, dict) else None


def firstof(rec, keys):
    for key in keys:
        value = field(rec, key)
        if value is not None:
            return value
    return None


def parse(line):
    try:
        return json.loads(line)
    except ValueError:
        return None


text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
out = sys.stdout

if OP == "recs":
    fields = [x for x in sys.argv[2].split("\n") if x]
    FS, RS = sys.argv[3], sys.argv[4]
    for i, line in enumerate([x for x in text.split("\n") if x]):
        rec = parse(line)
        if isinstance(rec, dict):
            out.write("r" + FS + "".join(cell(field(rec, k)) + FS for k in fields))
        else:
            out.write("u" + FS + "".join("" + FS for k in fields))
        out.write(str(i) + RS)
elif OP == "details":
    FS, RS = sys.argv[2], sys.argv[3]
    for i, line in enumerate([x for x in text.split("\n") if x]):
        d = field(parse(line), "details")
        if not isinstance(d, dict):
            continue
        for key in sorted(d):
            out.write("%d%s%s%s%s%s" % (i, FS, scrub(key), FS, cell(d[key]), RS))
elif OP == "policy":
    FS, RS = sys.argv[2], sys.argv[3]
    doc = json.loads(text)
    if not isinstance(doc, dict):
        doc = {}
    head = ["shiftId", "createdAt", "source", "verificationLevel", "toolingPolicy",
            "completionMode"]
    debt = field(doc, "selectedDebt")
    if not isinstance(debt, list):
        debt = []
    out.write("h" + FS + "".join(cell(field(doc, k)) + FS for k in head))
    out.write(", ".join(cell(x) for x in debt) + RS)
    allowances = field(doc, "allowances")
    if not isinstance(allowances, list):
        allowances = []
    for one in allowances:
        if not isinstance(one, dict):
            continue
        out.write("a" + FS + cell(field(one, "category")) + FS + cell(field(one, "scope"))
                  + FS + cell(field(one, "provenance")) + RS)
elif OP == "compare":
    FS, RS = sys.argv[2], sys.argv[3]
    doc = json.loads(text)
    rows = None
    if isinstance(doc, list):
        rows = doc
    elif isinstance(doc, dict):
        for key in ("rows", "findings", "comparison", "entries"):
            if isinstance(doc.get(key), list):
                rows = doc[key]
                break
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        sources = firstof(row, ["sources", "sourceClass", "source"])
        if isinstance(sources, list):
            sources = ", ".join(cell(x) for x in sources)
        else:
            sources = cell(sources)
        out.write(cell(firstof(row, ["id", "finding", "recordId"])) + FS
                  + cell(firstof(row, ["class", "classification", "state"])) + FS
                  + cell(firstof(row, ["digest"])) + FS + sources + FS
                  + cell(firstof(row, ["locator", "at"])) + RS)
'

# jq resolves every $name at compile time, so one program file means one argument set whichever
# operation is being asked for.
_jq_args() {
  JQARGS=(--arg op "$1" --arg fields "$RFIELDS" --arg FS "$FS" --arg RS "$RS")
}

# _emit_recs FILE — the ledger's cells, one group per line, on stdout.
_emit_recs() {
  if [ "$JSON_TOOL" = jq ]; then
    _jq_args recs
    jq -Rsj -f "$EMIT_JQ" "${JQARGS[@]}" <"$1"
  else
    python3 -c "$PY" recs "$RFIELDS" "$FS" "$RS" <"$1"
  fi
}

# _emit_details FILE — every details pair in the ledger, on stdout.
_emit_details() {
  if [ "$JSON_TOOL" = jq ]; then
    _jq_args details
    jq -Rsj -f "$EMIT_JQ" "${JQARGS[@]}" <"$1"
  else
    python3 -c "$PY" details "$FS" "$RS" <"$1"
  fi
}

# _emit_policy FILE — the shift policy's header and allowances, on stdout.
_emit_policy() {
  if [ "$JSON_TOOL" = jq ]; then
    _jq_args policy
    jq -j -f "$EMIT_JQ" "${JQARGS[@]}" <"$1"
  else
    python3 -c "$PY" policy "$FS" "$RS" <"$1"
  fi
}

# _emit_compare FILE — one comparison row per group, on stdout.
_emit_compare() {
  if [ "$JSON_TOOL" = jq ]; then
    _jq_args compare
    jq -j -f "$EMIT_JQ" "${JQARGS[@]}" <"$1"
  else
    python3 -c "$PY" compare "$FS" "$RS" <"$1"
  fi
}

# ---------------------------------------------------------------- the ledger

NREC=0
NDET=0
ULINES=0
R_ID=()
R_DOMAIN=()
R_SCLASS=()
R_SOURCE=()
R_SCOPE=()
R_STATUS=()
R_LADDER=()
R_LOCATOR=()
R_RAWDIGEST=()
R_FIX=()
R_VERIF=()
R_HOST=()
R_DIGEST=()
R_INDEX=()
D_IDX=()
D_KEY=()
D_VAL=()

_load_ledger() {
  local kind c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 idx key val
  [ -f "$JSONL" ] && [ ! -L "$JSONL" ] || return 0
  _emit_recs "$JSONL" >"$TMPD/recs" 2>/dev/null || die "cannot read $JSONL" 2
  while IFS="$FS" read -r -d "$RS" \
    kind c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 idx; do
    if [ "$kind" != r ]; then
      ULINES=$((ULINES + 1))
      continue
    fi
    R_ID[NREC]="$c0"
    R_DOMAIN[NREC]="$c1"
    R_SCLASS[NREC]="$c2"
    R_SOURCE[NREC]="$c3"
    R_SCOPE[NREC]="$c4"
    R_STATUS[NREC]="$c5"
    R_LADDER[NREC]="$c6"
    R_LOCATOR[NREC]="$c7"
    R_RAWDIGEST[NREC]="$c8"
    : "$c9" "$c10"
    R_FIX[NREC]="$c11"
    R_VERIF[NREC]="$c12"
    R_HOST[NREC]="$c13"
    R_DIGEST[NREC]="$c14"
    R_INDEX[NREC]="$idx"
    NREC=$((NREC + 1))
  done <"$TMPD/recs"
  _emit_details "$JSONL" >"$TMPD/details" 2>/dev/null || return 0
  while IFS="$FS" read -r -d "$RS" idx key val; do
    D_IDX[NDET]="$idx"
    D_KEY[NDET]="$key"
    D_VAL[NDET]="$val"
    NDET=$((NDET + 1))
  done <"$TMPD/details"
}

# _detail INDEX KEY -> DVAL: one details value, empty when the record does not carry the key.
_detail() {
  local i=0
  DVAL=""
  while [ "$i" -lt "$NDET" ]; do
    if [ "${D_IDX[$i]}" = "$1" ] && [ "${D_KEY[$i]}" = "$2" ]; then
      DVAL="${D_VAL[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------- the policy that ran

POLICY_FILE=""
P_SHIFTID=""
P_CREATEDAT=""
NALLOW=0
A_CATEGORY=()
A_SCOPE=()
A_PROVENANCE=()

# The snapshot the shift ran under is the live file until the clock-out gate files it, and the
# dated archive copy afterwards. A receipt rendered either side of that move says the same thing.
_find_policy() {
  local cand
  if [ -f "$NS/shift-policy.json" ] && [ ! -L "$NS/shift-policy.json" ]; then
    POLICY_FILE="$NS/shift-policy.json"
    return 0
  fi
  [ -d "$NS/archive" ] && [ ! -L "$NS/archive" ] || return 0
  cand="$(find "$NS/archive" -maxdepth 2 -type f -name 'shift-policy-*.json' -print 2>/dev/null |
    LC_ALL=C sort | tail -n 1)"
  [ -n "$cand" ] || return 0
  POLICY_FILE="$cand"
}

_classify_policy() {
  POLICY_KIND=absent
  [ -n "$POLICY_FILE" ] || return 0
  _ns_policy_load_shift_file "$POLICY_FILE" >/dev/null 2>&1
  case "$NS_POLICY_SHIFT_STATE" in
    ok) POLICY_KIND=accepted ;;
    absent) POLICY_KIND=absent ;;
    *) POLICY_KIND=malformed ;;
  esac
}

_load_policy() {
  local kind h1 h2 h3 h4 h5 h6 h7
  [ -n "$POLICY_FILE" ] || return 0
  [ "$POLICY_KIND" = accepted ] || return 0
  _emit_policy "$POLICY_FILE" >"$TMPD/policy" 2>/dev/null || return 0
  while IFS="$FS" read -r -d "$RS" kind h1 h2 h3 h4 h5 h6 h7; do
    case "$kind" in
      h)
        P_SHIFTID="$h1"
        P_CREATEDAT="$h2"
        : "$h3" "$h4" "$h5" "$h6" "$h7"
        ;;
      a)
        A_CATEGORY[NALLOW]="$h1"
        A_SCOPE[NALLOW]="$h2"
        A_PROVENANCE[NALLOW]="$h3"
        NALLOW=$((NALLOW + 1))
        ;;
    esac
  done <"$TMPD/policy"
}

# _resolved NAME -> RVALUE, RSOURCE: one row of the resolved view. Every helper that needs a
# policy answer reads the same resolver, so the receipt cannot report a different one. RSOURCE
# is `one-shift` only when tonight's policy set the value, which is how the receipt tells an
# owner's choice apart from the built-in floor a shift that wrote no policy runs on.
_resolved() {
  local line rest meta
  RVALUE=""
  RSOURCE=""
  while IFS= read -r line; do
    case "$line" in
      "$1="*) ;;
      *) continue ;;
    esac
    rest="${line#"$1="}"
    case "$rest" in
      *" ("*)
        meta="${rest##*" ("}"
        RVALUE="${rest%" ($meta"}"
        RSOURCE="${meta%%,*}"
        RSOURCE="${RSOURCE%)}"
        ;;
      *) RVALUE="$rest" ;;
    esac
    return 0
  done <"$TMPD/resolved"
}

# ---------------------------------------------------------------- owner-authored files

# _parked -> P_COUNT and P_TITLE[], P_DEFAULT[], P_ROLLBACK[]: every decision below the parking
# lot's rule that still waits for the owner, whole. An entry is a `### ` heading and everything
# under it, a top-level bullet and its wrapped and nested lines, or a paragraph; its Default and
# Rollback lines are kept apart. Filed pointers, runtime notices and answered entries are skipped.
P_COUNT=0
P_TITLE=()
P_DEFAULT=()
P_ROLLBACK=()

_parked() {
  local title def rb kind
  P_COUNT=0
  [ -f "$LOT" ] && [ ! -L "$LOT" ] || return 0
  sed 's/[[:cntrl:]]/ /g' "$LOT" | awk -v op=parked -v fs="$FS" -v dot="$MIDDOT" -f "$READ_AWK" \
    >"$TMPD/parked-parse"
  while IFS="$FS" read -r kind title def rb; do
    [ "$kind" = E ] || continue
    [ -n "$title" ] || continue
    P_TITLE[P_COUNT]="$title"
    P_DEFAULT[P_COUNT]="$def"
    P_ROLLBACK[P_COUNT]="$rb"
    P_COUNT=$((P_COUNT + 1))
  done <"$TMPD/parked-parse"
}

# _snags -> $TMPD/snags: `<finding> FS <disposition>` for each snag-log entry of this shift whose
# disposition is not fixed. An entry is `finding · evidence · disposition · date`; one without a
# disposition is open. This shift's entries are the ones dated on or after the day it started.
_snags() {
  : >"$TMPD/snags"
  [ -f "$SNAGS" ] && [ ! -L "$SNAGS" ] || return 0
  sed 's/[[:cntrl:]]/ /g' "$SNAGS" |
    awk -v op=snags -v fs="$FS" -v dot="$MIDDOT" -v day="$SHIFT_DAY" -f "$READ_AWK" >"$TMPD/snags"
}

# _building -> BUILD_TITLE, BUILD_PHASE, BUILD_NEXT: the one opportunity the map
# marks `Status: building`. The template's own illustration sits in an HTML comment and is not
# a live entry, so comment blocks are skipped.
_building() {
  local kind value
  BUILD_TITLE=""
  BUILD_PHASE=""
  BUILD_NEXT=""
  [ -f "$MAP" ] && [ ! -L "$MAP" ] || return 0
  sed 's/[[:cntrl:]]/ /g' "$MAP" | awk -v tab="$(printf '\t')" '
    /<!--/ { comment = 1 }
    /-->/ { comment = 0; next }
    comment { next }
    /^###[[:space:]]+/ {
      title = $0
      sub(/^###[[:space:]]+/, "", title)
      sub(/[[:space:]]*$/, "", title)
      tline = NR
      building = 0
      next
    }
    /^Status:[[:space:]]*building[[:space:]]*$/ {
      building = 1
      print "T" tab tline tab title
      next
    }
    building && /^Current phase:[[:space:]]*/ {
      value = $0
      sub(/^Current phase:[[:space:]]*/, "", value)
      print "P" tab NR tab value
      next
    }
    building && /^Next:[[:space:]]*/ {
      value = $0
      sub(/^Next:[[:space:]]*/, "", value)
      print "N" tab NR tab value
      next
    }
  ' >"$TMPD/building"
  while IFS="$(printf '\t')" read -r kind _ value; do
    case "$kind" in
      T)
        [ -z "$BUILD_TITLE" ] || continue
        BUILD_TITLE="$value"
        ;;
      P) [ -n "$BUILD_PHASE" ] || BUILD_PHASE="$value" ;;
      N) [ -n "$BUILD_NEXT" ] || BUILD_NEXT="$value" ;;
    esac
  done <"$TMPD/building"
}

# ---------------------------------------------------------------- section 1 facts

# _load_marks -> NMARK, M_EPOCH[], M_LABEL[]: the usage marks in the order they were written.
NMARK=0
M_EPOCH=()
M_LABEL=()

_load_marks() {
  local file="$NS/usage/marks.tsv" at label
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS="$FS" read -r at label; do
    case "$at" in '' | *[!0-9]*) continue ;; esac
    M_EPOCH[NMARK]="$at"
    M_LABEL[NMARK]="$label"
    NMARK=$((NMARK + 1))
  done <<EOF
$(awk -F'\t' -v fs="$FS" '{ print $1 fs $2 }' "$file")
EOF
}

# _shift_times -> STARTED, SHIFT_SINCE, ENDED, ENDED_EPOCH, SHIFT_DAY. The start is the arming
# mark, or the policy's createdAt for a shift that kept no usage marks, and commits are counted
# from that same moment; the end is when the clock-out gate wrote .ended. Both are UTC with the
# zone written out.
STARTED=""
SHIFT_SINCE=""
ENDED=""
ENDED_EPOCH=""
SHIFT_DAY=""

_shift_times() {
  local at
  STARTED="$P_CREATEDAT"
  SHIFT_SINCE="$P_CREATEDAT"
  if [ "$NMARK" -gt 0 ] && _utc_stamp "${M_EPOCH[0]}"; then
    STARTED="$UTC_STAMP"
    SHIFT_SINCE="@${M_EPOCH[0]}"
  fi
  case "$STARTED" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) SHIFT_DAY="${STARTED:0:10}" ;;
  esac
  if [ -f "$NS/.ended" ] && [ ! -L "$NS/.ended" ]; then
    at="$(ns_mtime "$NS/.ended")" || at=""
    case "$at" in
      '' | *[!0-9]*) ;;
      *) _utc_stamp "$at" && ENDED_EPOCH="$at" && ENDED="$UTC_STAMP" ;;
    esac
  fi
}

ENDING=""

_ending() {
  local reason="" open=0
  if [ -f "$STOP" ] && [ ! -L "$STOP" ]; then
    reason="$(sed -n 1p "$STOP" 2>/dev/null)"
    _scrub "$reason"
    reason="$SCRUBBED"
    case "$reason" in
      *" $DASH "*) reason="${reason%% "$DASH" *}" ;;
    esac
    case "$reason" in
      deadline) ENDING=deadline ;;
      stalled) ENDING=stall ;;
      *) ENDING=stop ;;
    esac
    return 0
  fi
  if [ -f "$PUNCH" ] && [ ! -L "$PUNCH" ]; then
    if ! open="$(ns_open_boxes "$PUNCH")"; then
      ENDING=unknown
      return 0
    fi
  fi
  if [ "${open:-0}" -eq 0 ]; then
    ENDING="done"
  else
    ENDING=unknown
  fi
}

# ---------------------------------------------------------------- rendering

MD=""
add() { MD="$MD$1$NL"; }

SEC=""
sec_add() { SEC="$SEC$1$NL"; }

# sec_flush TITLE — append a non-empty section body under its heading.
sec_flush() {
  [ -n "$SEC" ] || return 1
  add ''
  add "$1"
  add ''
  MD="$MD$SEC"
  SEC=""
  return 0
}

# sec_field LABEL VALUE — one bullet when value is present.
sec_field() {
  [ -n "$2" ] || return 0
  sec_add "- $1: $2"
}
# ---------------------------------------------------------------- sections

_key_by_domain() { # <destination> <domain>
  local dest="$1" i=0
  : >"$dest"
  while [ "$i" -lt "$NREC" ]; do
    if [ "${R_DOMAIN[$i]}" = "$2" ]; then
      printf '%s%s%s\n' "${R_ID[$i]}" "$FS" "$i" >>"$dest"
    fi
    i=$((i + 1))
  done
}

_lines_shift() {
  local i mode ticked open level chosen tooling target gates
  SEC=""
  sec_field Shift "$P_SHIFTID"
  _session_host
  sec_field Host "$SESSION_HOST"
  target="$(ns_work_target "$WORKSPACE" 2>/dev/null)" || target=""
  target="$(ns_native_display_path "$target")"
  sec_field 'Work target' "$target"
  sec_field Started "$STARTED"
  sec_field Ended "$ENDED"
  sec_field Ending "$ENDING"
  ticked=0
  open=0
  if [ -f "$PUNCH" ] && [ ! -L "$PUNCH" ]; then
    if ticked="$(ns_ticked_boxes "$PUNCH")" && open="$(ns_open_boxes "$PUNCH")"; then
      :
    else
      sec_add "- Items: unknown"
      ticked=""
    fi
  fi
  [ -z "$ticked" ] || sec_add "- Items: $ticked ticked, $open open"
  mode="$(ns_work_mode "$WORKSPACE" 2>/dev/null)" || mode=repository
  if [ "$VIEW" = artifact ] || [ "$mode" = artifact ]; then
    sec_add "- Receipts: $(ns_receipts_count "$WORKSPACE")"
  else
    _commit_count
    sec_field Commits "$COMMIT_COUNT"
  fi
  _policy_profile
  _resolved verificationLevel
  level="$RVALUE"
  chosen="$RSOURCE"
  _resolved toolingPolicy
  tooling="$RVALUE"
  sec_add "- Policy: profile $POLICY_PROFILE, verification $level, tooling $tooling"
  : >"$TMPD/allow"
  i=0
  while [ "$i" -lt "$NALLOW" ]; do
    printf '%s (%s, %s)%s%s\n' "${A_CATEGORY[$i]}" "${A_SCOPE[$i]}" "${A_PROVENANCE[$i]}" \
      "$FS" "$i" >>"$TMPD/allow"
    i=$((i + 1))
  done
  if [ -s "$TMPD/allow" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      sec_add "- Allowance: ${line%%"$FS"*}"
    done <<EOF
$(LC_ALL=C sort "$TMPD/allow")
EOF
  fi
  : >"$TMPD/verified"
  i=0
  while [ "$i" -lt "$NREC" ]; do
    case "${R_DOMAIN[$i]}" in
      baseline | checkpoint) ;;
      *)
        if [ "${R_LADDER[$i]}" = verified-after-change ] && [ -n "${R_SOURCE[$i]}" ]; then
          printf '%s\n' "${R_SOURCE[$i]}" >>"$TMPD/verified"
        fi
        ;;
    esac
    i=$((i + 1))
  done
  _gate_commands
  _join_sorted "$TMPD/gates" "$SOURCE_SEP"
  gates="$JOINED"
  # A shift that wrote no policy runs on the built-in floor, and the punch list's own Gates
  # section is what it was told to run. Naming those commands as the shift's gate keeps the
  # receipt from crediting the owner with a decision they never made.
  if [ "$chosen" != one-shift ] && [ -n "$gates" ]; then
    sec_add "- Gates: $gates ($GATES_FROM)"
  fi
  _join_sorted "$TMPD/verified" "$SOURCE_SEP"
  if [ -n "$JOINED" ]; then
    sec_add "- Verified: $JOINED"
  elif [ "$chosen" = one-shift ]; then
    sec_add "- Verified: none $DASH verification level $level (owner)"
  elif [ "$POLICY_KIND" = malformed ]; then
    sec_add "- Verified: none $DASH $POLICY_MALFORMED"
  else
    sec_add "- Verified: none $DASH $NO_POLICY"
  fi
  if [ "$level" = none ] && [ "$chosen" = one-shift ] && [ -n "$gates" ]; then
    sec_add "- Disabled by owner: $gates"
  else
    sec_add "- Disabled by owner: $NONE"
  fi
  : >"$TMPD/unavail"
  i=0
  while [ "$i" -lt "$NREC" ]; do
    case "${R_DOMAIN[$i]}" in
      baseline | checkpoint) ;;
      *)
        case "${R_STATUS[$i]}" in
          unavailable | unsupported | unmeasured)
            [ -n "${R_SOURCE[$i]}" ] && printf '%s\n' "${R_SOURCE[$i]}" >>"$TMPD/unavail"
            ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
  _join_sorted "$TMPD/unavail" "$SOURCE_SEP"
  if [ -n "$JOINED" ]; then
    sec_add "- Unavailable: $JOINED"
  else
    sec_add "- Unavailable: $NONE"
  fi
  [ -n "$SEC" ]
}

# The whole shift, from the arming mark to the end: working time with every recorded pause listed
# by its reason, and the tokens the host reported, in its own counting. Nothing is priced, and a
# measurement the owner turned off says off.
_lines_usage() {
  local start end wall paused=0 work reason secs fields host segs dim v word
  SEC=""
  [ "$NMARK" -gt 0 ] || return 1
  start="${M_EPOCH[0]}"
  end="${ENDED_EPOCH:-${M_EPOCH[$((NMARK - 1))]}}"
  [ "$end" -ge "$start" ] || end="$start"
  if [ "$(ns_report "$WORKSPACE" duration)" = off ]; then
    sec_add '- Time: off'
  else
    wall=$((end - start))
    ns_usage_pauses_by_reason "$NS" "$start" "$end" >"$TMPD/pauses" 2>/dev/null || : >"$TMPD/pauses"
    while IFS=$'\t' read -r reason secs; do
      case "$secs" in '' | *[!0-9]*) continue ;; esac
      paused=$((paused + secs))
    done <"$TMPD/pauses"
    work=$((wall - paused))
    [ "$work" -ge 0 ] || work=0
    _utc_stamp "$start"
    v="$UTC_STAMP"
    _utc_stamp "$end"
    sec_add "- Span: $v $ARROW $UTC_STAMP"
    sec_add "- Working: $(ns_usage_duration "$work")"
    if [ "$paused" -gt 0 ]; then
      sec_add "- Paused: $(ns_usage_duration "$paused")"
      while IFS=$'\t' read -r reason secs; do
        case "$secs" in '' | *[!0-9]*) continue ;; esac
        sec_add "  - $reason: $(ns_usage_duration "$secs")"
      done <"$TMPD/pauses"
    else
      sec_add "- Paused: $NONE"
    fi
    sec_add "- Wall: $(ns_usage_duration "$wall")"
  fi
  if [ "$(ns_report "$WORKSPACE" usage)" = off ]; then
    sec_add '- Tokens: off'
  else
    fields="$(ns_usage_total "$NS")" || fields=""
    host="$(ns_usage_hosts "$NS" 2>/dev/null)" || host=""
    [ -n "$host" ] || host=unknown
    segs="$(ns_usage_segments "$NS")"
    sec_add ''
    sec_add '| Tokens | Amount |'
    sec_add '| --- | ---: |'
    for dim in $NS_USAGE_DIMENSIONS; do
      v="$(ns_usage_field "$fields" "$dim")" || v=""
      if [ -n "$v" ]; then v="$(ns_usage_scale "$v")"; else v=unavailable; fi
      sec_add "| $(ns_usage_dim_label "$dim") | $v |"
    done
    sec_add ''
    word=segments
    [ "$segs" != 1 ] || word=segment
    sec_add "$host $MIDDOT $segs $word. $(ns_usage_overlap "${host%% *}")"
  fi
  [ -n "$SEC" ]
}

# One line per item, in list order, linked to its item receipt where that file exists. The receipt
# carries the item's own cost, sessions, checks and story; this page does not copy them.
_lines_items() {
  local state label id
  SEC=""
  [ -f "$PUNCH" ] && [ ! -L "$PUNCH" ] || return 1
  while IFS=$'\t' read -r state label id || [ -n "$state" ]; do
    [ -n "$label" ] || continue
    _item_link "$label" "$id"
    sec_add "- $ITEM_LINK $DASH $state"
  done <<EOF
$(ns_item_states "$PUNCH")
EOF
  [ -n "$SEC" ]
}

# Where review should start: the three largest changes of the shift, by lines and then files, each
# charged to the item whose span its commit landed in, and the one command that shows the range.
# A commit outside every item's span stands on its own line.
_lines_review() {
  local mode target first="" last="" range lines files add del commits kind k1 k2 display n=0
  local fcount lcount ccount
  SEC=""
  mode="$(ns_work_mode "$WORKSPACE" 2>/dev/null)" || mode=repository
  if [ "$VIEW" = artifact ] || [ "$mode" = artifact ]; then
    sec_add "- $REVIEW_ARTIFACT"
    return 0
  fi
  [ -n "$SHIFT_SINCE" ] || return 1
  target="$(ns_work_target "$WORKSPACE" 2>/dev/null)" || target=""
  [ -n "$target" ] || return 1
  target="$(ns_msys_path "$target")"
  # git runs inside the target rather than being handed its path: Git for Windows cannot resolve
  # the shell's /c/... form when path conversion is off.
  (cd -P "$target" 2>/dev/null && git log --no-merges --reverse --since "$SHIFT_SINCE" \
    --format='@@%x09%h%x09%ct%x09%s' --numstat HEAD) >"$TMPD/review-log" 2>/dev/null || return 1
  [ -s "$TMPD/review-log" ] || return 1
  : >"$TMPD/review-marks"
  n=0
  while [ "$n" -lt "$NMARK" ]; do
    printf '%s%s%s\n' "${M_EPOCH[$n]}" "$FS" "${M_LABEL[$n]}" >>"$TMPD/review-marks"
    n=$((n + 1))
  done
  awk -v op=review -v fs="$FS" -f "$READ_AWK" "$TMPD/review-marks" "$TMPD/review-log" \
    >"$TMPD/review-rows" || return 1
  IFS="$FS" read -r first last <"$TMPD/review-rows" || return 1
  [ -n "$first" ] || return 1
  n=0
  while IFS="$FS" read -r lines files add del commits kind k1 k2; do
    [ "$n" -lt 3 ] || break
    n=$((n + 1))
    if [ "$kind" = i ]; then
      _item_link "$k1" "$(ns_item_id_for "$PUNCH" "$k1")"
      display="$ITEM_LINK"
    else
      display="\`$k1\` $k2"
    fi
    _count "$files" file
    fcount="$COUNTED"
    _count "$lines" line
    lcount="$COUNTED"
    _count "$commits" commit
    ccount="$COUNTED"
    sec_add "- $display $DASH $fcount, $lcount (+$add/-$del), $ccount"
  done <<EOF
$(tail -n +2 "$TMPD/review-rows" | LC_ALL=C sort -t "$FS" -k1,1nr -k2,2nr -k6)
EOF
  if (cd -P "$target" 2>/dev/null && git rev-parse --verify --quiet "$first^") >/dev/null 2>&1; then
    range="$first^..$last"
  else
    range="$last"
  fi
  sec_add "- Whole range: \`git log --stat $range\`"
  [ -n "$SEC" ]
}

# What interrupted the night, as the runtime wrote it into the shift log: revivals, API failures,
# stalls, usage limits and how it was stopped.
_lines_interruptions() {
  local line
  SEC=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sec_add "- $line"
  done <<EOF
$(_shift_log_lines interruptions)
EOF
  [ -n "$SEC" ]
}

_lines_baseline() {
  local pos idx sclass cmd env raw scope
  SEC=""
  _key_by_domain "$TMPD/k-baseline" baseline
  _order "$TMPD/k-baseline"
  while IFS= read -r pos; do
    [ -n "$pos" ] || continue
    idx="${R_INDEX[$pos]}"
    _detail "$idx" sourceClass
    sclass="$DVAL"
    [ -n "$sclass" ] || sclass="${R_SCLASS[$pos]}"
    _detail "$idx" command
    cmd="$DVAL"
    [ -n "$cmd" ] || cmd="${R_SOURCE[$pos]}"
    _detail "$idx" environmentDigest
    env="$DVAL"
    _short_digest "$env"
    [ -n "$SHORT_DIGEST" ] || env="$NONE"
    env="${SHORT_DIGEST:-$NONE}"
    _detail "$idx" rawDigest
    raw="$DVAL"
    [ -n "$raw" ] || raw="${R_RAWDIGEST[$pos]}"
    _short_digest "$raw"
    [ -n "$SHORT_DIGEST" ] || raw="$NONE"
    raw="${SHORT_DIGEST:-$NONE}"
    _detail "$idx" scope
    scope="$DVAL"
    [ -n "$scope" ] || scope="${R_SCOPE[$pos]}"
    [ -n "$scope" ] || scope="$NONE"
    sec_add "- ${R_ID[$pos]}: $sclass \`$cmd\` $DASH env $env raw $raw ($scope)"
  done <<EOF
$ORDER
EOF
  [ -n "$SEC" ]
}

CMP_ROWS=0
CMP_ID=()
CMP_CLASS=()
CMP_DIGEST=()
CMP_SOURCES=()
CMP_LOCATOR=()

_load_comparison_merged() {
  local pos id rc cid cclass cdig csrc cloc
  CMP_ROWS=0
  : >"$TMPD/cmp-seen-ids"
  : >"$TMPD/cmp-debt"
  _order "$TMPD/k-baseline"
  while IFS= read -r pos; do
    [ -n "$pos" ] || continue
    id="${R_ID[$pos]}"
    [ -f "$COMPARE" ] || continue
    rc=0
    bash "$COMPARE" --project "$WORKSPACE" --baseline "$id" --json \
      >"$TMPD/cmp.json" 2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
      continue
    fi
    if [ "$JSON_TOOL" = jq ]; then
      jq -r '.summary.selectedDebtOutstanding[]? // empty' <"$TMPD/cmp.json" >>"$TMPD/cmp-debt" 2>/dev/null ||
        :
    else
      python3 -c 'import json,sys
doc=json.load(open(sys.argv[1]))
for x in (doc.get("summary") or {}).get("selectedDebtOutstanding") or []:
    print(x)' "$TMPD/cmp.json" >>"$TMPD/cmp-debt" 2>/dev/null || :
    fi
    _emit_compare "$TMPD/cmp.json" >"$TMPD/cmp.rows" 2>/dev/null || continue
    while IFS="$FS" read -r -d "$RS" cid cclass cdig csrc cloc; do
      if grep -Fqx "$cid" "$TMPD/cmp-seen-ids" 2>/dev/null; then
        continue
      fi
      printf '%s\n' "$cid" >>"$TMPD/cmp-seen-ids"
      CMP_ID[CMP_ROWS]="$cid"
      CMP_CLASS[CMP_ROWS]="$cclass"
      CMP_DIGEST[CMP_ROWS]="$cdig"
      CMP_SOURCES[CMP_ROWS]="$csrc"
      CMP_LOCATOR[CMP_ROWS]="$cloc"
      CMP_ROWS=$((CMP_ROWS + 1))
    done <"$TMPD/cmp.rows"
  done <<EOF
$ORDER
EOF
}

_lines_changed() {
  local only="$1" i=0 row line cls cells nfix pos fix loc dig
  SEC=""
  _key_by_domain "$TMPD/k-baseline" baseline
  if [ ! -s "$TMPD/k-baseline" ]; then
    return 1
  fi
  _load_comparison_merged
  : >"$TMPD/cmp-order"
  i=0
  while [ "$i" -lt "$CMP_ROWS" ]; do
    if [ "$only" != 1 ] || [ "${CMP_CLASS[$i]}" = regressed ]; then
      printf '%s\n' "${CMP_ID[$i]}" >>"$TMPD/cmp-order"
    fi
    i=$((i + 1))
  done
  sec_add '| ID | Class | Digest | Sources | Locator |'
  sec_add '| --- | --- | --- | --- | --- |'
  if [ -s "$TMPD/cmp-order" ]; then
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      i=0
      while [ "$i" -lt "$CMP_ROWS" ]; do
        [ "${CMP_ID[$i]}" = "$row" ] || { i=$((i + 1)); continue; }
        _short_digest "${CMP_DIGEST[$i]}"
        _md_cell "$row"
        line="| $MD_CELL"
        _md_cell "${CMP_CLASS[$i]}"
        line="$line | $MD_CELL"
        _md_cell "${SHORT_DIGEST:-}"
        line="$line | $MD_CELL"
        _md_cell "${CMP_SOURCES[$i]}"
        line="$line | $MD_CELL"
        _md_cell "${CMP_LOCATOR[$i]}"
        line="$line | $MD_CELL |"
        sec_add "$line"
        break
      done
    done <<EOF
$(LC_ALL=C sort -u "$TMPD/cmp-order")
EOF
  else
    sec_add "| $DASH | $DASH | $DASH | $DASH | empty |"
  fi
  sec_add ''
  cells=""
  for cls in new cleared unchanged regressed unavailable rejected-duplicate parked human-only; do
    nfix=0
    i=0
    while [ "$i" -lt "$CMP_ROWS" ]; do
      if [ "$only" = 1 ] && [ "${CMP_CLASS[$i]}" != regressed ]; then
        i=$((i + 1))
        continue
      fi
      [ "${CMP_CLASS[$i]}" = "$cls" ] && nfix=$((nfix + 1))
      i=$((i + 1))
    done
    [ -n "$cells" ] && cells="$cells, "
    cells="$cells$cls $nfix"
  done
  sec_add "Summary: $cells"
  if [ -s "$TMPD/cmp-debt" ]; then
    _join_sorted "$TMPD/cmp-debt" "$SOURCE_SEP"
    [ -n "$JOINED" ] && sec_add "Selected debt outstanding: $JOINED"
  fi
  : >"$TMPD/fixed-ids"
  i=0
  while [ "$i" -lt "$NREC" ]; do
    case "${R_DOMAIN[$i]}" in
      baseline | checkpoint) ;;
      *)
        [ "${R_STATUS[$i]}" = fixed ] && printf '%s\n' "${R_ID[$i]}" >>"$TMPD/fixed-ids"
        ;;
    esac
    i=$((i + 1))
  done
  if [ -s "$TMPD/fixed-ids" ]; then
    sec_add ''
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      pos=-1
      i=0
      while [ "$i" -lt "$NREC" ]; do
        case "${R_DOMAIN[$i]}" in
          baseline | checkpoint) ;;
          *) [ "${R_ID[$i]}" = "$row" ] && pos="$i" ;;
        esac
        i=$((i + 1))
      done
      [ "$pos" -ge 0 ] || continue
      fix="${R_FIX[$pos]}"
      [ -n "$fix" ] || fix="$NONE"
      loc="${R_VERIF[$pos]}"
      [ -n "$loc" ] || loc="${R_LOCATOR[$pos]}"
      [ -n "$loc" ] || loc="$NONE"
      _short_digest "${R_DIGEST[$pos]}"
      dig="${SHORT_DIGEST:-$NONE}"
      sec_add "- $row: $fix$JOINER$loc$JOINER$dig"
    done <<EOF
$(LC_ALL=C sort -u "$TMPD/fixed-ids")
EOF
  fi
  [ -n "$SEC" ]
}

_lines_parked() {
  local i=0
  SEC=""
  while [ "$i" -lt "$P_COUNT" ]; do
    sec_add "- ${P_TITLE[$i]}"
    [ -n "${P_DEFAULT[$i]}" ] && sec_add "  - Default: ${P_DEFAULT[$i]}"
    [ -n "${P_ROLLBACK[$i]}" ] && sec_add "  - Rollback: ${P_ROLLBACK[$i]}"
    i=$((i + 1))
  done
  [ -n "$SEC" ]
}

_lines_snags() {
  local finding disposition
  SEC=""
  while IFS="$FS" read -r finding disposition; do
    [ -n "$finding" ] || continue
    sec_add "- $finding $DASH $disposition"
  done <"$TMPD/snags"
  [ -n "$SEC" ]
}

_lines_unsupported() {
  local i=0 id status loc
  SEC=""
  : >"$TMPD/unsup-ids"
  i=0
  while [ "$i" -lt "$NREC" ]; do
    case "${R_DOMAIN[$i]}" in
      baseline | checkpoint) ;;
      *)
        case "${R_STATUS[$i]}" in
          human-only | unsupported | unmeasured)
            printf '%s\n' "${R_ID[$i]}" >>"$TMPD/unsup-ids"
            ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    pos=-1
    i=0
    while [ "$i" -lt "$NREC" ]; do
      [ "${R_ID[$i]}" = "$id" ] && pos="$i"
      i=$((i + 1))
    done
    [ "$pos" -ge 0 ] || continue
    status="${R_STATUS[$pos]}"
    loc="${R_LOCATOR[$pos]}"
    [ -n "$loc" ] || loc="$NONE"
    sec_add "- $id: $status$JOINER$loc"
  done <<EOF
$(LC_ALL=C sort -u "$TMPD/unsup-ids")
EOF
  [ -n "$SEC" ]
}

_lines_next() {
  local label handover
  SEC=""
  if [ -f "$PUNCH" ] && [ ! -L "$PUNCH" ]; then
    while IFS=$'\t' read -r label _ || [ -n "$label" ]; do
      [ -n "$label" ] || continue
      sec_add "- $label"
    done <<EOF
$(ns_item_rows "$PUNCH" open)
EOF
  fi
  if [ -n "$BUILD_TITLE" ] && [ -n "$BUILD_NEXT" ]; then
    sec_add "- Building: $BUILD_TITLE $DASH next: $BUILD_NEXT"
  fi
  handover="$(_shift_log_lines handover)"
  [ -z "$handover" ] || sec_add "- Handover: $handover"
  [ -n "$SEC" ]
}

# ---------------------------------------------------------------- assembly

_load_ledger
_find_policy
_classify_policy
_load_policy
ns_policy_resolve_table "$WORKSPACE" >"$TMPD/resolved" 2>/dev/null ||
  : >"$TMPD/resolved"
_load_marks
_shift_times
_parked
_snags
_building
_ending

add '# Morning receipt'
add 'Receipts:'
add '- [index](./README.md)'
case "$POLICY_KIND" in
  accepted) add "- Policy record: accepted" ;;
  malformed) add "- Policy record: malformed $DASH $POLICY_MALFORMED" ;;
  *) add "- Policy record: absent $DASH the shift wrote no policy" ;;
esac

# Without an explicit --view, the owner's configured reader decides. The sections a view renders
# are the documented factual ones; an owner list picks from those and orders them, and an empty
# list keeps the built-in order for that view.
[ -n "$VIEW" ] || VIEW="$(ns_handoff_view "$WORKSPACE")"
HANDOFF_SECTIONS="$(ns_handoff "$WORKSPACE" sections 2>/dev/null)" || HANDOFF_SECTIONS=""
case "$HANDOFF_SECTIONS" in
  '' | '[]') HANDOFF_SECTIONS="" ;;
esac

# _sections_in_order — the owner's names in the order they wrote them, else nothing.
_sections_in_order() {
  [ -n "$HANDOFF_SECTIONS" ] || return 1
  printf '%s' "$HANDOFF_SECTIONS" | tr ',' '\n' | tr -d '[]" '
}

# The release reader sees regressions only, whichever list chose the section.
REGRESSIONS_ONLY=0
[ "$VIEW" != release ] || REGRESSIONS_ONLY=1

_emit_section() { # <name>
  case "$1" in
    shift) _lines_shift && sec_flush '## How it ended' ;;
    usage) _lines_usage && sec_flush '## Time and tokens' ;;
    items) _lines_items && sec_flush '## Items' ;;
    review) _lines_review && sec_flush '## Review first' ;;
    interruptions) _lines_interruptions && sec_flush '## Interruptions' ;;
    parked) _lines_parked && sec_flush '## Decisions for you' ;;
    snags) _lines_snags && sec_flush '## Found but not fixed' ;;
    baseline) _lines_baseline && sec_flush '## Baseline' ;;
    changed) _lines_changed "$REGRESSIONS_ONLY" && sec_flush '## What changed' ;;
    unsupported) _lines_unsupported && sec_flush '## Unsupported / unmeasured' ;;
    next) _lines_next && sec_flush '## Next step' ;;
  esac
}

if [ -n "$HANDOFF_SECTIONS" ]; then
  VIEW_SECTIONS="$(_sections_in_order)"
else
  case "$VIEW" in
    owner) VIEW_SECTIONS='shift usage items review interruptions parked snags baseline changed unsupported next' ;;
    reviewer) VIEW_SECTIONS='review baseline changed' ;;
    release) VIEW_SECTIONS='shift changed' ;;
    artifact) VIEW_SECTIONS='shift usage items review interruptions parked snags unsupported next' ;;
  esac
fi
for _sec in $VIEW_SECTIONS; do
  _emit_section "$_sec"
done
# One trailing newline, whichever section came last.
while :; do
  case "$MD" in
    *"$NL$NL") MD="${MD%"$NL"}" ;;
    *) break ;;
  esac
done

if [ -n "$OUT" ]; then
  case "$OUT" in
    */*) mkdir -p "${OUT%/*}" || die "cannot write $OUT" 2 ;;
  esac
  printf '%s' "$MD" >"$OUT.tmp.$$" || {
    rm -f "$OUT.tmp.$$"
    die "cannot write $OUT" 2
  }
  mv "$OUT.tmp.$$" "$OUT" || {
    rm -f "$OUT.tmp.$$"
    die "cannot write $OUT" 2
  }
  printf '%s\n' "$OUT"
  exit 0
fi

printf '%s' "$MD"
exit 0
