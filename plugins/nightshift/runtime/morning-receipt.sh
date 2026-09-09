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
# archived snapshot), the resolved policy, the punch list, the parking lot, the opportunity map,
# and the shift markers. It measures nothing, reruns nothing, and never renders a check the owner
# disabled as one that passed. Six sections in a fixed order, each omitted when it is empty; the
# view chooses which of them a reader gets:
#
#   owner     every section
#   reviewer  2 and 3
#   release   1, and 3 filtered to regressions
#   artifact  1, 4, 5 and 6, in the vocabulary of a site rather than a repository
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
COMPARE="${NIGHTSHIFT_COMPARE_HELPER:-$_here/evidence-compare.sh}"

NL='
'
FS=$(printf '\037')
RS=$(printf '\036')
DASH=$(printf '\xe2\x80\x94')

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
MAP="$NS/opportunity-map.md"
STOP="$NS/STOP"

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

# _log_end -> LOG_END: the last shift-log stamp, as written.
_log_end() {
  LOG_END=""
  [ -f "$NS/shift-log.md" ] && [ ! -L "$NS/shift-log.md" ] || return 0
  LOG_END="$(sed -n 's/^\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\).*/\1/p' \
    "$NS/shift-log.md" | tail -n 1)"
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
  [ -n "$P_CREATEDAT" ] || return 0
  target="$(ns_work_target "$WORKSPACE" 2>/dev/null)" || target=""
  [ -n "$target" ] || return 0
  target="$(ns_msys_path "$target")"
  count="$(cd -P "$target" 2>/dev/null && git rev-list --count --since "$P_CREATEDAT" HEAD)" || return 0
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

_receipts_line() {
  local punch="$NS/punch-list.md" line label base
  printf 'Receipts: [index](./README.md)'
  [ -f "$punch" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      '- [x] '*) label="${line#'- [x] '}" ;;
      '- [X] '*) label="${line#'- [X] '}" ;;
      *) continue ;;
    esac
    label="${label#\*\*}"
    label="$(printf '%s' "$label" | awk '{
      sub(/[[:space:]]+—.*$/, "")
      sub(/[[:space:]]+-[[:space:]].*$/, "")
      sub(/\*\*.*$/, "")
      gsub(/[[:space:]]+$/, "")
      print
    }')"
    [ -n "$label" ] || continue
    base="$(ns_receipt_basename "$label")"
    [ -n "$base" ] || continue
    printf ', [%s](./%s.md)' "$label" "$base"
  done <<NSITEMS
$(ns_items_section "$punch" 2>/dev/null || :)
NSITEMS
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

# _open_items -> $TMPD/open-items: `<line>\t<title>` per open box below the Items heading. The
# heading is the same boundary the gate and the watchman count from.
_open_items() {
  : >"$TMPD/open-items"
  [ -f "$PUNCH" ] && [ ! -L "$PUNCH" ] || return 0
  sed 's/[[:cntrl:]]/ /g' "$PUNCH" | awk -v tab="$(printf '\t')" '
    /^## Items[[:space:]]*$/ { items = 1; next }
    items && /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/ {
      title = $0
      sub(/^[[:space:]]*-[[:space:]]*\[[[:space:]]\][[:space:]]*/, "", title)
      sub(/[[:space:]]*$/, "", title)
      print NR tab title
    }
  ' >"$TMPD/open-items"
}

# _parked -> P_COUNT and P_TITLE[], P_DEFAULT[], P_ROLLBACK[]: entries below the rule line.
P_COUNT=0
P_TITLE=()
P_DEFAULT=()
P_ROLLBACK=()

_parked() {
  local title def rb kind
  P_COUNT=0
  [ -f "$LOT" ] && [ ! -L "$LOT" ] || return 0
  sed 's/[[:cntrl:]]/ /g' "$LOT" | awk -v tab="$(printf '\t')" '
    BEGIN { started = 0; title = ""; def = ""; rb = "" }
    !started { if ($0 ~ /^---[[:space:]]*$/) started = 1; next }
    /^[[:space:]]*- (Default|Rollback):[[:space:]]*/ {
      if (title == "") next
      line = $0
      sub(/^[[:space:]]*- /, "", line)
      if (line ~ /^Default:/) {
        sub(/^Default:[[:space:]]*/, "", line)
        def = line
      } else {
        sub(/^Rollback:[[:space:]]*/, "", line)
        rb = line
      }
      next
    }
    /^[[:space:]]*(Default|Rollback):[[:space:]]*/ {
      if (title == "") next
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^Default:/) {
        sub(/^Default:[[:space:]]*/, "", line)
        def = line
      } else {
        sub(/^Rollback:[[:space:]]*/, "", line)
        rb = line
      }
      next
    }
    /^[[:space:]]*- / {
      if (title != "" && title != "(empty)") print "E" tab title tab def tab rb
      line = $0
      sub(/^[[:space:]]*- /, "", line)
      sub(/[[:space:]]+$/, "", line)
      title = line
      def = ""
      rb = ""
      next
    }
    /^[[:space:]]*### / {
      if (title != "" && title != "(empty)") print "E" tab title tab def tab rb
      line = $0
      sub(/^[[:space:]]*### /, "", line)
      sub(/[[:space:]]+$/, "", line)
      title = line
      def = ""
      rb = ""
      next
    }
    END { if (title != "" && title != "(empty)") print "E" tab title tab def tab rb }
  ' >"$TMPD/parked-parse"
  while IFS="$(printf '\t')" read -r kind title def rb; do
    [ "$kind" = E ] || continue
    [ -n "$title" ] || continue
    P_TITLE[P_COUNT]="$title"
    P_DEFAULT[P_COUNT]="$def"
    P_ROLLBACK[P_COUNT]="$rb"
    P_COUNT=$((P_COUNT + 1))
  done <"$TMPD/parked-parse"
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
  sec_field Started "$P_CREATEDAT"
  _log_end
  sec_field Ended "$LOG_END"
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
  local title
  SEC=""
  while IFS="$(printf '\t')" read -r _ title; do
    [ -n "$title" ] || continue
    sec_add "- $title"
  done <"$TMPD/open-items"
  if [ -n "$BUILD_TITLE" ] && [ -n "$BUILD_NEXT" ]; then
    sec_add "- Building: $BUILD_TITLE $DASH next: $BUILD_NEXT"
  fi
  [ -n "$SEC" ]
}

# ---------------------------------------------------------------- assembly

_load_ledger
_find_policy
_classify_policy
_load_policy
ns_policy_resolve_table "$WORKSPACE" >"$TMPD/resolved" 2>/dev/null ||
  : >"$TMPD/resolved"
_open_items
_parked
_building
_ending

add '# Morning receipt'
add "$(_receipts_line)"
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

_emit_section() { # <name>
  case "$1" in
    shift) _lines_shift && sec_flush '## Shift' ;;
    baseline) _lines_baseline && sec_flush '## Baseline' ;;
    changed) _lines_changed 0 && sec_flush '## What changed' ;;
    parked) _lines_parked && sec_flush '## Parked' ;;
    unsupported) _lines_unsupported && sec_flush '## Unsupported / unmeasured' ;;
    next) _lines_next && sec_flush '## Next' ;;
  esac
}

if [ -n "$HANDOFF_SECTIONS" ]; then
  while IFS= read -r _sec; do
    [ -n "$_sec" ] || continue
    _emit_section "$_sec"
  done <<EOF
$(_sections_in_order)
EOF
else
case "$VIEW" in
  owner)
    _lines_shift && sec_flush '## Shift'
    _lines_baseline && sec_flush '## Baseline'
    _lines_changed 0 && sec_flush '## What changed'
    _lines_parked && sec_flush '## Parked'
    _lines_unsupported && sec_flush '## Unsupported / unmeasured'
    _lines_next && sec_flush '## Next'
    ;;
  reviewer)
    _lines_baseline && sec_flush '## Baseline'
    _lines_changed 0 && sec_flush '## What changed'
    ;;
  release)
    _lines_shift && sec_flush '## Shift'
    _lines_changed 1 && sec_flush '## What changed'
    ;;
  artifact)
    _lines_shift && sec_flush '## Shift'
    _lines_parked && sec_flush '## Parked'
    _lines_unsupported && sec_flush '## Unsupported / unmeasured'
    _lines_next && sec_flush '## Next'
    ;;
esac
fi
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
