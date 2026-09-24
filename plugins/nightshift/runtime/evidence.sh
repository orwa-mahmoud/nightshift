#!/usr/bin/env bash
# evidence.sh — versioned findings ledger (JSON Lines).
#
#   evidence.sh --project DIR init|validate|append|disposition|render|export-tsv|migrate
#
# Validates records. Does not verify a Nightshift tick or interpret domain meaning.
# Exit: 0 ok · 1 usage · 2 contract failure
#
# The ledger logic is bash. jq (preferred) or python3 covers exactly two jobs: reading the
# JSON inputs (the v1 schema, the --record argument, every ledger line) and writing a record
# back as compact canonical JSON. Every decision — which defaults apply, which contract
# errors fire and in what order, which record a disposition touches, what a render prints —
# happens here. A record travels as its own canonical JSON text, one line each, so the
# ledger on disk and the ledger in hand are the same bytes.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/layout.sh
. "$_here/../lib/layout.sh"
SCHEMA_PATH="$_here/../skills/nightshift/references/schemas/v1/finding.json"
EMIT_JQ="$_here/evidence-emit.jq"

NL='
'
TAB=$(printf '\t')
CR=$(printf '\r')
VT=$(printf '\013')
FF=$(printf '\014')
FS=$(printf '\037')
RS=$(printf '\036')

# Field slots in the fact stream. The order is the slot number; evidence-emit.jq is told the
# same list, so both halves agree without either hard-coding the other.
FIELDS="id
severity
confidence
impact
status
ladder
locator
untrusted
promoteBy
source
sourceCommand
sourceClass
sourceTool"

# Keys whose absence — not their emptiness — makes append supply a default.
HKEYS="schemaVersion
firstSeen
lastChecked
digest
action
fix
verificationLocator
disposition
rollback"

# The export column set, in order. The render table draws six of these.
COLS="id
domain
sourceClass
source
scope
severity
confidence
impact
status
ladder
locator
host"

LADDER_NAMES='"declared"
"observed"
"reproduced"
"measured"
"verified-after-change"
"human-accepted"'

usage() {
  printf 'usage: evidence.sh --project DIR {init|validate|append|disposition|render|export-tsv|migrate} ...\n' >&2
  exit 1
}

# ---------------------------------------------------------------- small helpers

# _join DIR NAME -> JOINED. NAME is always a leaf, never a path: an absolute
# NAME stays under DIR. os.path.join's "rooted second argument wins" rule is
# how an evidence id such as /tmp/nightshift-proof escaped .nightshift/.
_join() {
  case "$1" in
    "" | */) JOINED="$1$2" ;;
    *) JOINED="$1/$2" ;;
  esac
}

# Evidence ids: a leading [A-Za-z0-9], then [A-Za-z0-9_-]* only.
_valid_evidence_id() {
  case "$1" in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  case "$1" in
    [A-Za-z0-9]*) return 0 ;;
  esac
  return 1
}

# _contained_raw ID -> RAWPATH, RAWABS under .nightshift/. Resolves the parent
# directory before the caller writes. Rejects anything that would escape.
_contained_raw() {
  local id="$1" parent ns_real dest_parent
  _valid_evidence_id "$id" || return 1
  _join "$EVREL" raw
  _join "$JOINED" "$id.txt"
  RAWPATH="$JOINED"
  case "$RAWPATH" in
    /* | *\\* | *..*) return 1 ;;
  esac
  _join "$NS" "$RAWPATH"
  parent="${JOINED%/*}"
  mkdir -p "$RAWDIR" || return 1
  ns_real="$(cd -P "$NS" && pwd)" || return 1
  dest_parent="$(cd -P "$parent" && pwd)" || return 1
  case "$dest_parent" in
    "$ns_real" | "$ns_real"/*) ;;
    *) return 1 ;;
  esac
  RAWABS="$dest_parent/$id.txt"
}

# _strip_ws TEXT -> STRIPPED, mirroring str.strip() over ASCII whitespace.
_strip_ws() {
  local s="$1"
  while [ -n "$s" ]; do
    case "$s" in
      " "*|"$TAB"*|"$NL"*|"$CR"*|"$VT"*|"$FF"*) s="${s#?}" ;;
      *) break ;;
    esac
  done
  while [ -n "$s" ]; do
    case "$s" in
      *" "|*"$TAB"|*"$NL"|*"$CR"|*"$VT"|*"$FF") s="${s%?}" ;;
      *) break ;;
    esac
  done
  STRIPPED="$s"
}

# _normpath PATH -> NORMPATH, mirroring posixpath.normpath.
_normpath() {
  local path="$1" initial rest comp stack tail joined
  if [ -z "$path" ]; then
    NORMPATH="."
    return 0
  fi
  case "$path" in
    ///*) initial=1 ;;
    //*) initial=2 ;;
    /*) initial=1 ;;
    *) initial=0 ;;
  esac
  stack="$NL"
  rest="$path/"
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    rest="${rest#*/}"
    [ -n "$comp" ] || continue
    [ "$comp" = "." ] && continue
    if [ "$comp" != ".." ]; then
      stack="$stack$comp$NL"
      continue
    fi
    if [ "$stack" = "$NL" ]; then
      [ "$initial" -eq 0 ] && stack="$stack..$NL"
      continue
    fi
    tail="${stack%"$NL"}"
    if [ "${tail##*"$NL"}" = ".." ]; then
      stack="$stack..$NL"
    else
      stack="${tail%"$NL"*}$NL"
    fi
  done
  joined=""
  tail="${stack#"$NL"}"
  while [ -n "$tail" ]; do
    comp="${tail%%"$NL"*}"
    tail="${tail#*"$NL"}"
    if [ -z "$joined" ]; then joined="$comp"; else joined="$joined/$comp"; fi
  done
  case "$initial" in
    1) joined="/$joined" ;;
    2) joined="//$joined" ;;
  esac
  [ -n "$joined" ] || joined="."
  NORMPATH="$joined"
}

# _abspath PATH -> ABSPATH, mirroring os.path.abspath.
_abspath() {
  local p="$1" cwd
  case "$p" in
    /*) ;;
    *)
      cwd=$(pwd -P)
      case "$cwd" in
        */) p="$cwd$p" ;;
        *) p="$cwd/$p" ;;
      esac
      ;;
  esac
  _normpath "$p"
  ABSPATH="$NORMPATH"
}

# _has_line LIST ENTRY — exact membership in a newline-terminated list.
_has_line() {
  case "$NL$1" in
    *"$NL$2$NL"*) return 0 ;;
  esac
  return 1
}

# _py_truthy JSONTEXT — the truthiness Python gives the value that text encodes.
_py_truthy() {
  case "$1" in
    null|false|0|-0|0.0|-0.0|'""'|'[]'|'{}') return 1 ;;
  esac
  return 0
}

# _ladder_rank JSONTEXT -> LRANK, -1 when the value is not a rung.
_ladder_rank() {
  local rest name n=0
  LRANK=-1
  rest="$LADDER_NAMES$NL"
  while [ -n "$rest" ]; do
    name="${rest%%"$NL"*}"
    rest="${rest#*"$NL"}"
    [ -n "$name" ] || continue
    if [ "$name" = "$1" ]; then
      LRANK="$n"
      return 0
    fi
    n=$((n + 1))
  done
}

# _ends_nl FILE — str.endswith("\n") over the file, so an empty file is false.
_ends_nl() {
  local last
  last=$(tail -c1 "$1"; printf x)
  case "$last" in
    "$NL"x) return 0 ;;
  esac
  return 1
}

_mktmp() {
  local base="${TMPDIR:-/tmp}" n=0 d
  if command -v mktemp >/dev/null 2>&1; then
    TMPD="$(mktemp -d "${base%/}/ns-evidence.XXXXXX")" || {
      printf 'evidence: cannot create a temporary directory\n' >&2
      exit 2
    }
  else
    case "$base" in
      */) base="${base%/}" ;;
    esac
    while [ "$n" -lt 64 ]; do
      d="$base/ns-evidence-$$-$n"
      if mkdir "$d" 2>/dev/null; then
        TMPD="$d"
        break
      fi
      n=$((n + 1))
    done
    [ -n "${TMPD:-}" ] || {
      printf 'evidence: cannot create a temporary directory\n' >&2
      exit 2
    }
  fi
  chmod 700 "$TMPD" || {
    rm -rf "$TMPD"
    TMPD=""
    printf 'evidence: cannot create a temporary directory\n' >&2
    exit 2
  }
}

_cleanup() { [ -z "${TMPD:-}" ] || rm -rf "$TMPD"; }

# ---------------------------------------------------------------- digests

SHA_TOOL=""

_pick_sha() {
  [ -z "$SHA_TOOL" ] || return 0
  if command -v sha256sum >/dev/null 2>&1; then
    SHA_TOOL=sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    SHA_TOOL=shasum
  elif command -v openssl >/dev/null 2>&1; then
    SHA_TOOL=openssl
  else
    printf 'evidence: sha256sum, shasum or openssl is required to digest a record\n' >&2
    exit 2
  fi
}

# _sha256_file FILE -> DIGEST, lowercase hex.
_sha256_file() {
  local line
  _pick_sha
  case "$SHA_TOOL" in
    sha256sum) line=$(sha256sum <"$1"); DIGEST="${line%% *}" ;;
    shasum) line=$(shasum -a 256 <"$1"); DIGEST="${line%% *}" ;;
    *) line=$(openssl dgst -sha256 <"$1"); DIGEST="${line##* }" ;;
  esac
}

_utcnow() {
  if [ -n "${NIGHTSHIFT_EVIDENCE_NOW:-}" ]; then
    NOW="$NIGHTSHIFT_EVIDENCE_NOW"
    return 0
  fi
  NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
}

# ---------------------------------------------------------------- JSON bridge

JSON_TOOL=""

_pick_json_tool() {
  if command -v jq >/dev/null 2>&1; then
    JSON_TOOL=jq
  elif command -v python3 >/dev/null 2>&1; then
    JSON_TOOL=python3
  else
    printf 'evidence: JSON parser unavailable; write the receipt in the skill\n' >&2
    exit 2
  fi
}

PY='
import json, sys

OP = sys.argv[1]


def canon(o):
    return json.dumps(o, sort_keys=True, separators=(",", ":"))


def names(s):
    return [x for x in s.split("\n") if x]


def tname(v):
    if v is None:
        return "null"
    if v is True or v is False:
        return "boolean"
    if isinstance(v, (int, float)):
        return "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    return "object"


def presence(rec, keys):
    return "".join("1" if isinstance(rec, dict) and k in rec else "0" for k in keys)


def field(rec, key):
    return rec.get(key) if isinstance(rec, dict) else None


text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
lines = text.split("\n")
if lines and lines[-1] == "":
    lines.pop()
out = []

if OP == "canon":
    try:
        sys.stdout.write(canon(json.loads(text)) + "\n")
    except ValueError:
        sys.exit(1)
elif OP == "check":
    for line in lines:
        try:
            json.loads(line)
            out.append("1")
        except ValueError:
            out.append("0")
elif OP == "canonlines":
    for line in lines:
        out.append(canon(json.loads(line)))
elif OP == "tojson":
    sys.stdout.write(canon(text))
elif OP == "schema":
    doc = json.loads(text)
    for key in doc["required"]:
        out.append("R\t" + key)
    for tag, name in (
        ("S", "severity"),
        ("C", "confidence"),
        ("I", "impact"),
        ("T", "status"),
        ("L", "ladder"),
    ):
        for value in doc[name]:
            out.append(tag + "\t" + canon(value))
elif OP == "facts":
    req, hkeys, fields, sep = (
        names(sys.argv[2]),
        names(sys.argv[3]),
        names(sys.argv[4]),
        sys.argv[5],
    )
    for i, line in enumerate(lines):
        rec = json.loads(line)
        head = sep + str(i) + sep
        out.append("t" + head + tname(rec))
        out.append("q" + head + presence(rec, req))
        out.append("h" + head + presence(rec, hkeys))
        out.append("s" + head + ("1" if field(rec, "schemaVersion") == 1 else "0"))
        for slot, key in enumerate(fields):
            out.append("v" + head + str(slot) + sep + canon(field(rec, key)))
elif OP == "rows":
    cols, sep, term = names(sys.argv[2]), sys.argv[3], sys.argv[4]
    for line in lines:
        rec = json.loads(line)
        row = "".join(str(field(rec, c)) + sep for c in cols)
        sys.stdout.write(row + presence(rec, cols) + term)
elif OP == "edit":
    assign, sep, term = sys.argv[2], sys.argv[3], sys.argv[4]
    rec = json.loads(text)
    for one in assign.split(term):
        if not one:
            continue
        f = one.split(sep)
        if f[1] == "s":
            rec[f[0]] = f[2]
        elif f[1] == "n":
            rec[f[0]] = json.loads(f[2])
        else:
            rec[f[0]] = rec[f[2]]
    sys.stdout.write(canon(rec) + "\n")

if out:
    sys.stdout.write("".join(line + "\n" for line in out))
'

# _jq_args OP [ASSIGNMENTS] -> JQARGS. jq resolves every $name at compile time, so one
# program file means one argument set, whichever operation is being asked for.
_jq_args() {
  JQARGS=(--arg op "$1" --arg req "${REQ_KEYS:-}" --arg hkeys "$HKEYS" \
    --arg fields "$FIELDS" --arg cols "$COLS" --arg assign "${2:-}" \
    --arg T "$TAB" --arg FS "$FS" --arg RS "$RS")
}

# _canon FILE -> CANON: the one JSON value in FILE as compact canonical JSON.
# Returns 1 when the text is not exactly one value, as json.loads would.
_canon() {
  local out
  if [ "$JSON_TOOL" = jq ]; then
    out=$(jq -caS -n --slurpfile r "$1" \
      'if ($r | length) == 1 then $r[0] else error("not one value") end' 2>/dev/null) ||
      return 1
  else
    out=$(python3 -c "$PY" canon <"$1" 2>/dev/null) || return 1
  fi
  [ -n "$out" ] || return 1
  CANON="$out"
}

# _check_lines FILE — "1" or "0" per line, on stdout, saying whether that line is one value.
_check_lines() {
  if [ "$JSON_TOOL" = jq ]; then
    jq -Rr 'if (try (fromjson | true) catch false) then "1" else "0" end' <"$1"
  else
    python3 -c "$PY" check <"$1"
  fi
}

# _canon_lines FILE — each line rewritten as compact canonical JSON, on stdout.
_canon_lines() {
  if [ "$JSON_TOOL" = jq ]; then
    jq -R -caS 'fromjson' <"$1"
  else
    python3 -c "$PY" canonlines <"$1"
  fi
}

# _json_str TEXT -> JSONSTR, the text as a JSON string, in this backend's own escaping.
_json_str() {
  printf '%s' "$1" >"$TMPD/str"
  if [ "$JSON_TOOL" = jq ]; then
    JSONSTR=$(jq -Rs . <"$TMPD/str")
  else
    JSONSTR=$(python3 -c "$PY" tojson <"$TMPD/str")
  fi
}

# _edit_rec IN OUT ASSIGNMENTS — apply the assignment list, write canonical JSON.
_edit_rec() {
  if [ "$JSON_TOOL" = jq ]; then
    _jq_args edit "$3"
    jq -caS -f "$EMIT_JQ" "${JQARGS[@]}" <"$1" >"$2"
  else
    python3 -c "$PY" edit "$3" "$FS" "$RS" <"$1" >"$2"
  fi
}

# ---------------------------------------------------------------- the schema

REQ_KEYS=""
SEV_LIST=""
CONF_LIST=""
IMP_LIST=""
STAT_LIST=""
LADD_LIST=""

_load_schema() {
  local line kind rest
  if [ "$JSON_TOOL" = jq ]; then
    jq -r '(.required[] | "R\t" + .),
           (.severity[] | "S\t" + tojson),
           (.confidence[] | "C\t" + tojson),
           (.impact[] | "I\t" + tojson),
           (.status[] | "T\t" + tojson),
           (.ladder[] | "L\t" + tojson)' "$SCHEMA_PATH" >"$TMPD/schema" 2>/dev/null
  else
    python3 -c "$PY" schema <"$SCHEMA_PATH" >"$TMPD/schema" 2>/dev/null
  fi || {
    printf 'evidence: cannot read the finding schema at %s\n' "$SCHEMA_PATH" >&2
    exit 2
  }
  while IFS= read -r line; do
    kind="${line%%"$TAB"*}"
    rest="${line#*"$TAB"}"
    case "$kind" in
      R) REQ_KEYS="$REQ_KEYS$rest$NL" ;;
      S) SEV_LIST="$SEV_LIST$rest$NL" ;;
      C) CONF_LIST="$CONF_LIST$rest$NL" ;;
      I) IMP_LIST="$IMP_LIST$rest$NL" ;;
      T) STAT_LIST="$STAT_LIST$rest$NL" ;;
      L) LADD_LIST="$LADD_LIST$rest$NL" ;;
    esac
  done <"$TMPD/schema"
}

# ---------------------------------------------------------------- record store

# Records live as canonical JSON text in REC, their facts in the F_ arrays, their printable
# columns in the P_ arrays. A record the ledger has not accepted yet takes the slot one past
# the end, so validation treats it exactly like a stored one.
NREC=0
REC=()
LNO=()
F_TYPE=()
F_REQ=()
F_HAS=()
F_SV1=()
F_ID=()
F_SEVERITY=()
F_CONFIDENCE=()
F_IMPACT=()
F_STATUS=()
F_LADDER=()
F_LOCATOR=()
F_UNTRUSTED=()
F_PROMOTEBY=()
F_SOURCE=()
F_SOURCECOMMAND=()
F_SOURCECLASS=()
F_SOURCETOOL=()
P_BITS=()
P_ID=()
P_DOMAIN=()
P_SOURCECLASS=()
P_SOURCE=()
P_SCOPE=()
P_SEVERITY=()
P_CONFIDENCE=()
P_IMPACT=()
P_STATUS=()
P_LADDER=()
P_LOCATOR=()
P_HOST=()

# _read_ledger — load findings.jsonl into REC, or exit 1 naming the first malformed line.
_read_ledger() {
  local line="" i=0 flag
  NREC=0
  [ -f "$JSONL" ] || return 0
  {
    while IFS= read -r line || [ -n "$line" ]; do
      i=$((i + 1))
      _strip_ws "$line"
      [ -n "$STRIPPED" ] || continue
      LNO[NREC]="$i"
      NREC=$((NREC + 1))
      printf '%s\n' "$STRIPPED"
    done <"$JSONL"
  } >"$TMPD/lines"
  [ "$NREC" -gt 0 ] || return 0
  _check_lines "$TMPD/lines" >"$TMPD/ok"
  i=0
  while IFS= read -r flag; do
    if [ "$flag" != 1 ]; then
      printf 'evidence: malformed JSON on line %s\n' "${LNO[$i]}" >&2
      exit 1
    fi
    i=$((i + 1))
  done <"$TMPD/ok"
  _canon_lines "$TMPD/lines" >"$TMPD/canon"
  i=0
  while IFS= read -r line; do
    REC[i]="$line"
    i=$((i + 1))
  done <"$TMPD/canon"
}

# _load_facts FILE BASE — read the fact stream for the canonical records in FILE.
_load_facts() {
  local base="$2" line kind idx rest slot
  if [ "$JSON_TOOL" = jq ]; then
    _jq_args facts
    jq -sr -f "$EMIT_JQ" "${JQARGS[@]}" <"$1" >"$TMPD/facts"
  else
    python3 -c "$PY" facts "$REQ_KEYS" "$HKEYS" "$FIELDS" "$TAB" <"$1" >"$TMPD/facts"
  fi
  while IFS= read -r line; do
    kind="${line%%"$TAB"*}"
    rest="${line#*"$TAB"}"
    idx="${rest%%"$TAB"*}"
    rest="${rest#*"$TAB"}"
    idx=$((base + idx))
    case "$kind" in
      t) F_TYPE[idx]="$rest" ;;
      q) F_REQ[idx]="$rest" ;;
      h) F_HAS[idx]="$rest" ;;
      s) F_SV1[idx]="$rest" ;;
      v)
        slot="${rest%%"$TAB"*}"
        rest="${rest#*"$TAB"}"
        case "$slot" in
          0) F_ID[idx]="$rest" ;;
          1) F_SEVERITY[idx]="$rest" ;;
          2) F_CONFIDENCE[idx]="$rest" ;;
          3) F_IMPACT[idx]="$rest" ;;
          4) F_STATUS[idx]="$rest" ;;
          5) F_LADDER[idx]="$rest" ;;
          6) F_LOCATOR[idx]="$rest" ;;
          7) F_UNTRUSTED[idx]="$rest" ;;
          8) F_PROMOTEBY[idx]="$rest" ;;
          9) F_SOURCE[idx]="$rest" ;;
          10) F_SOURCECOMMAND[idx]="$rest" ;;
          11) F_SOURCECLASS[idx]="$rest" ;;
          12) F_SOURCETOOL[idx]="$rest" ;;
        esac
        ;;
    esac
  done <"$TMPD/facts"
}

# _load_rows FILE BASE — read the printable columns for the canonical records in FILE.
_load_rows() {
  local base="$2" i bits c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11
  if [ "$JSON_TOOL" = jq ]; then
    _jq_args rows
    jq -sj -f "$EMIT_JQ" "${JQARGS[@]}" <"$1" >"$TMPD/rows"
  else
    python3 -c "$PY" rows "$COLS" "$FS" "$RS" <"$1" >"$TMPD/rows"
  fi
  i="$base"
  while IFS="$FS" read -r -d "$RS" \
    c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 bits; do
    P_ID[i]="$c0"
    P_DOMAIN[i]="$c1"
    P_SOURCECLASS[i]="$c2"
    P_SOURCE[i]="$c3"
    P_SCOPE[i]="$c4"
    P_SEVERITY[i]="$c5"
    P_CONFIDENCE[i]="$c6"
    P_IMPACT[i]="$c7"
    P_STATUS[i]="$c8"
    P_LADDER[i]="$c9"
    P_LOCATOR[i]="$c10"
    P_HOST[i]="$c11"
    P_BITS[i]="$bits"
    i=$((i + 1))
  done <"$TMPD/rows"
}

# _write_ledger — every record, canonical, one per line, in place by rename.
_write_ledger() {
  local i=0
  {
    while [ "$i" -lt "$NREC" ]; do
      printf '%s\n' "${REC[$i]}"
      i=$((i + 1))
    done
  } >"$JSONL.tmp"
  mv "$JSONL.tmp" "$JSONL"
}

# ---------------------------------------------------------------- validation

# _validate I HASPREV PREVLADDER -> ERRORS, one contract failure per line, in schema order.
_validate() {
  local i="$1" hasprev="$2" prevladder="$3" bits key rest n=0 old new idjson
  ERRORS=""
  if [ "${F_TYPE[$i]}" != object ]; then
    ERRORS="record is not an object$NL"
    return 0
  fi
  bits="${F_REQ[$i]}"
  rest="$REQ_KEYS"
  while [ -n "$rest" ]; do
    key="${rest%%"$NL"*}"
    rest="${rest#*"$NL"}"
    [ -n "$key" ] || continue
    [ "${bits:$n:1}" = 1 ] || ERRORS="${ERRORS}missing $key$NL"
    n=$((n + 1))
  done
  [ "${F_SV1[$i]}" = 1 ] || ERRORS="${ERRORS}unsupported schemaVersion$NL"
  _has_line "$SEV_LIST" "${F_SEVERITY[$i]}" || ERRORS="${ERRORS}invalid severity$NL"
  _has_line "$CONF_LIST" "${F_CONFIDENCE[$i]}" || ERRORS="${ERRORS}invalid confidence$NL"
  _has_line "$IMP_LIST" "${F_IMPACT[$i]}" || ERRORS="${ERRORS}invalid impact$NL"
  _has_line "$STAT_LIST" "${F_STATUS[$i]}" || ERRORS="${ERRORS}invalid status$NL"
  _has_line "$LADD_LIST" "${F_LADDER[$i]}" || ERRORS="${ERRORS}invalid ladder$NL"
  case "${F_ID[$i]}" in
    '"'*)
      idjson="${F_ID[$i]}"
      idjson="${idjson#\"}"
      idjson="${idjson%\"}"
      _valid_evidence_id "$idjson" || ERRORS="${ERRORS}invalid id$NL"
      ;;
  esac
  case "${F_LOCATOR[$i]}" in
    *"://"*)
      _py_truthy "${F_UNTRUSTED[$i]}" ||
        ERRORS="${ERRORS}remote locator requires untrusted=true$NL"
      ;;
  esac
  if [ "$hasprev" = 1 ]; then
    _ladder_rank "$prevladder"
    old="$LRANK"
    _ladder_rank "${F_LADDER[$i]}"
    new="$LRANK"
    if [ "$old" -ge 0 ] && [ "$new" -gt "$old" ] &&
      [ "${F_PROMOTEBY[$i]}" = '"prose"' ]; then
      ERRORS="${ERRORS}ladder must not be promoted by prose$NL"
    fi
  fi
}

# _print_errors PREFIX — the collected failures, one line each, on stderr.
_print_errors() {
  local rest line
  rest="$ERRORS"
  while [ -n "$rest" ]; do
    line="${rest%%"$NL"*}"
    rest="${rest#*"$NL"}"
    [ -n "$line" ] || continue
    printf 'evidence: %s%s\n' "$1" "$line" >&2
  done
}

# ---------------------------------------------------------------- commands

# _cmd_init QUIET — returns 1 when there is no workspace to hold a ledger.
_cmd_init() {
  if [ ! -d "$NS" ]; then
    printf 'evidence: no .nightshift/ at %s\n' "$PROJECT_ARG" >&2
    return 1
  fi
  mkdir -p "$RAWDIR" || return 1
  [ -f "$JSONL" ] || : >"$JSONL"
  [ -f "$VERFILE" ] || printf '1\n' >"$VERFILE"
  [ "$1" = 1 ] || printf '%s\n' "$JSONL"
  return 0
}

_cmd_validate() {
  local rc=0 i=0 j prev hasprev label
  if [ ! -f "$JSONL" ]; then
    printf 'evidence: no ledger (valid empty workspace)\n'
    exit 0
  fi
  _load_schema
  _read_ledger
  [ "$NREC" -gt 0 ] || exit 0
  _load_facts "$TMPD/canon" 0
  _load_rows "$TMPD/canon" 0
  while [ "$i" -lt "$NREC" ]; do
    hasprev=0
    prev=""
    j=0
    while [ "$j" -lt "$i" ]; do
      if [ "${F_ID[$j]}" = "${F_ID[$i]}" ] && _py_truthy "${F_ID[$j]}"; then
        hasprev=1
        prev="${F_LADDER[$j]}"
      fi
      j=$((j + 1))
    done
    _validate "$i" "$hasprev" "$prev"
    if [ -n "$ERRORS" ]; then
      rc=2
      label="?"
      if _py_truthy "${F_ID[$i]}"; then label="${P_ID[$i]}"; fi
      _print_errors "$label: "
    fi
    i=$((i + 1))
  done
  exit "$rc"
}

_cmd_append() {
  local hbits stype src srccmd srccls srctool ops i prev hasprev idstr line
  _cmd_init 1 || :
  _load_schema
  printf '%s' "$RECORD" >"$TMPD/in"
  if ! _canon "$TMPD/in"; then
    printf 'evidence: --record is not one JSON value\n' >&2
    exit 1
  fi
  printf '%s\n' "$CANON" >"$TMPD/one"
  _load_facts "$TMPD/one" 0
  stype="${F_TYPE[0]}"
  hbits="${F_HAS[0]}"
  src="${F_SOURCE[0]}"
  srccmd="${F_SOURCECOMMAND[0]}"
  srccls="${F_SOURCECLASS[0]}"
  srctool="${F_SOURCETOOL[0]}"
  if [ "$stype" != object ]; then
    printf 'evidence: record is not an object\n' >&2
    exit 1
  fi
  _utcnow
  ops=""
  [ "${hbits:0:1}" = 1 ] || ops="$ops${RS}schemaVersion${FS}n${FS}1"
  [ "${hbits:1:1}" = 1 ] || ops="$ops${RS}firstSeen${FS}s${FS}$NOW"
  [ "${hbits:2:1}" = 1 ] || ops="$ops${RS}lastChecked${FS}k${FS}firstSeen"
  _edit_rec "$TMPD/one" "$TMPD/two" "$ops"
  ops=""
  if [ "${hbits:3:1}" != 1 ]; then
    IFS= read -r line <"$TMPD/two"
    printf '%s' "$line" >"$TMPD/digest"
    _sha256_file "$TMPD/digest"
    ops="$ops${RS}digest${FS}s${FS}$DIGEST"
  fi
  [ "${hbits:4:1}" = 1 ] || ops="$ops${RS}action${FS}s${FS}"
  [ "${hbits:5:1}" = 1 ] || ops="$ops${RS}fix${FS}s${FS}"
  [ "${hbits:6:1}" = 1 ] || ops="$ops${RS}verificationLocator${FS}s${FS}"
  [ "${hbits:7:1}" = 1 ] || ops="$ops${RS}disposition${FS}s${FS}"
  [ "${hbits:8:1}" = 1 ] || ops="$ops${RS}rollback${FS}s${FS}"
  if ! _py_truthy "$src"; then
    if _py_truthy "$srccmd"; then
      ops="$ops${RS}source${FS}k${FS}sourceCommand"
    else
      ops="$ops${RS}source${FS}s${FS}"
    fi
  fi
  if ! _py_truthy "$srccls"; then
    if _py_truthy "$srctool"; then
      ops="$ops${RS}sourceClass${FS}k${FS}sourceTool"
    else
      ops="$ops${RS}sourceClass${FS}s${FS}unknown"
    fi
  fi
  _edit_rec "$TMPD/two" "$TMPD/three" "$ops"
  _read_ledger
  if [ "$NREC" -gt 0 ]; then
    _load_facts "$TMPD/canon" 0
  fi
  _load_facts "$TMPD/three" "$NREC"
  _load_rows "$TMPD/three" "$NREC"
  IFS= read -r line <"$TMPD/three"
  REC[NREC]="$line"
  hasprev=0
  prev=""
  i=0
  while [ "$i" -lt "$NREC" ]; do
    if [ "${F_ID[$i]}" = "${F_ID[$NREC]}" ]; then
      hasprev=1
      prev="${F_LADDER[$i]}"
      break
    fi
    i=$((i + 1))
  done
  _validate "$NREC" "$hasprev" "$prev"
  if [ -n "$ERRORS" ]; then
    _print_errors ""
    exit 2
  fi
  if [ -n "$RAW" ]; then
    case "${F_ID[$NREC]}" in
      '"'*) ;;
      *)
        printf 'evidence: raw output needs a string id\n' >&2
        exit 1
        ;;
    esac
    idstr="${P_ID[$NREC]}"
    if ! _contained_raw "$idstr"; then
      printf 'evidence: invalid id\n' >&2
      exit 2
    fi
    printf '%s' "$RAW" >"$TMPD/raw"
    cp "$TMPD/raw" "$RAWABS.tmp"
    _ends_nl "$TMPD/raw" || printf '\n' >>"$RAWABS.tmp"
    mv "$RAWABS.tmp" "$RAWABS"
    _sha256_file "$TMPD/raw"
    ops="${RS}rawPath${FS}s${FS}$RAWPATH${RS}rawDigest${FS}s${FS}$DIGEST"
    _edit_rec "$TMPD/three" "$TMPD/four" "$ops"
    IFS= read -r line <"$TMPD/four"
    REC[NREC]="$line"
  fi
  NREC=$((NREC + 1))
  _write_ledger
  printf '%s\n' "${P_ID[$((NREC - 1))]}"
  exit 0
}

_cmd_disposition() {
  local i=0 found=0 ops oldladder line
  _load_schema
  _read_ledger
  if [ "$NREC" -gt 0 ]; then
    _load_facts "$TMPD/canon" 0
  fi
  _json_str "$DISP_ID"
  _utcnow
  while [ "$i" -lt "$NREC" ]; do
    if [ "${F_ID[$i]}" != "$JSONSTR" ]; then
      i=$((i + 1))
      continue
    fi
    found=1
    oldladder="${F_LADDER[$i]}"
    ops="${RS}disposition${FS}s${FS}$DISP${RS}lastChecked${FS}s${FS}$NOW"
    [ -z "$LADDER" ] || ops="$ops${RS}ladder${FS}s${FS}$LADDER"
    printf '%s\n' "${REC[$i]}" >"$TMPD/one"
    _edit_rec "$TMPD/one" "$TMPD/two" "$ops"
    IFS= read -r line <"$TMPD/two"
    REC[i]="$line"
    _load_facts "$TMPD/two" "$i"
    _validate "$i" 1 "$oldladder"
    if [ -n "$ERRORS" ]; then
      _print_errors ""
      exit 2
    fi
    i=$((i + 1))
  done
  if [ "$found" != 1 ]; then
    printf 'evidence: unknown id %s\n' "$DISP_ID" >&2
    exit 2
  fi
  _write_ledger
  exit 0
}

_cmd_render() {
  local md i=0
  if [ -f "$JSONL" ]; then
    _read_ledger
    [ "$NREC" -eq 0 ] || _load_rows "$TMPD/canon" 0
  fi
  md="# Evidence ledger$NL"
  md="$md$NL"
  md="${md}Machine source: \`evidence/findings.jsonl\`. Helpers validate records; they do not$NL"
  md="${md}verify a Nightshift tick or interpret domain meaning.$NL"
  md="$md$NL"
  md="$md| ID | Domain | Severity | Ladder | Status | Locator |$NL"
  md="$md| --- | --- | --- | --- | --- | --- |$NL"
  while [ "$i" -lt "$NREC" ]; do
    md="$md| ${P_ID[$i]} | ${P_DOMAIN[$i]} | ${P_SEVERITY[$i]} | ${P_LADDER[$i]} |"
    md="$md ${P_STATUS[$i]} | ${P_LOCATOR[$i]} |$NL"
    i=$((i + 1))
  done
  [ "$NREC" -gt 0 ] || md="$md| — | — | — | — | — | empty |$NL"
  mkdir -p "$EVDIR"
  printf '%s' "$md" >"$MDFILE.tmp"
  mv "$MDFILE.tmp" "$MDFILE"
  printf '%s' "$md"
  exit 0
}

# _tsv_cell VALUE PRESENT -> CELL: an absent column exports as empty, a tab inside a value
# becomes a space so the column count survives.
_tsv_cell() {
  if [ "$2" = 1 ]; then
    CELL="${1//$TAB/ }"
  else
    CELL=""
  fi
}

_cmd_export_tsv() {
  local i=0 row bits
  if [ -f "$JSONL" ]; then
    _read_ledger
    [ "$NREC" -eq 0 ] || _load_rows "$TMPD/canon" 0
  fi
  printf 'id%sdomain%ssourceClass%ssource%sscope%sseverity%sconfidence%simpact%sstatus%sladder%slocator%shost\n' \
    "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB"
  while [ "$i" -lt "$NREC" ]; do
    bits="${P_BITS[$i]}"
    _tsv_cell "${P_ID[$i]}" "${bits:0:1}"
    row="$CELL"
    _tsv_cell "${P_DOMAIN[$i]}" "${bits:1:1}"
    row="$row$TAB$CELL"
    _tsv_cell "${P_SOURCECLASS[$i]}" "${bits:2:1}"
    row="$row$TAB$CELL"
    _tsv_cell "${P_SOURCE[$i]}" "${bits:3:1}"
    row="$row$TAB$CELL"
    _tsv_cell "${P_SCOPE[$i]}" "${bits:4:1}"
    row="$row$TAB$CELL"
    _tsv_cell "${P_SEVERITY[$i]}" "${bits:5:1}"
    row="$row$TAB$CELL"
    _tsv_cell "${P_CONFIDENCE[$i]}" "${bits:6:1}"
    row="$row$TAB$CELL"
    _tsv_cell "${P_IMPACT[$i]}" "${bits:7:1}"
    row="$row$TAB$CELL"
    _tsv_cell "${P_STATUS[$i]}" "${bits:8:1}"
    row="$row$TAB$CELL"
    _tsv_cell "${P_LADDER[$i]}" "${bits:9:1}"
    row="$row$TAB$CELL"
    _tsv_cell "${P_LOCATOR[$i]}" "${bits:10:1}"
    row="$row$TAB$CELL"
    _tsv_cell "${P_HOST[$i]}" "${bits:11:1}"
    row="$row$TAB$CELL"
    printf '%s\n' "$row"
    i=$((i + 1))
  done
  exit 0
}

_cmd_migrate() {
  local version
  if [ ! -d "$EVDIR" ] && [ ! -f "$JSONL" ]; then
    printf 'evidence: nothing to migrate\n'
    exit 0
  fi
  version=0
  if [ -f "$VERFILE" ]; then
    version=$(cat "$VERFILE")
    _strip_ws "$version"
    version="$STRIPPED"
    [ -n "$version" ] || version=0
  fi
  case "$version" in
    0 | 1)
      mkdir -p "$RAWDIR"
      printf '1\n' >"$VERFILE"
      [ -f "$JSONL" ] || : >"$JSONL"
      printf 'evidence: schema-version 1\n'
      exit 0
      ;;
  esac
  printf 'evidence: unsupported evidence schema-version %s\n' "$version" >&2
  exit 2
}

# ---------------------------------------------------------------- entry point

PROJECT_ARG=""
while [ $# -gt 0 ]; do
  [ "$1" = "--project" ] || break
  [ $# -ge 2 ] || usage
  PROJECT_ARG="$2"
  shift 2
done
[ -n "$PROJECT_ARG" ] || usage
[ $# -gt 0 ] || usage

CMD="$1"
shift
RECORD=""
RAW=""
DISP_ID=""
DISP=""
LADDER=""
case "$CMD" in
  init | validate | render | export-tsv | migrate) ;;
  append)
    while [ $# -gt 0 ]; do
      case "$1" in
        --record)
          [ $# -ge 2 ] || usage
          RECORD="$2"
          shift 2
          ;;
        --raw)
          [ $# -ge 2 ] || usage
          RAW="$2"
          shift 2
          ;;
        *) usage ;;
      esac
    done
    [ -n "$RECORD" ] || usage
    ;;
  disposition)
    [ $# -ge 2 ] || usage
    DISP_ID="$1"
    DISP="$2"
    [ $# -lt 3 ] || LADDER="$3"
    ;;
  *) usage ;;
esac

_abspath "$PROJECT_ARG"
PROJECT="$ABSPATH"
_join "$PROJECT" .nightshift
NS="$JOINED"
declare EVDIR EVREL
ns_layout_set EVDIR "$NS" evidence
ns_layout_rel_set EVREL "$NS" evidence
_join "$EVDIR" findings.jsonl
JSONL="$JOINED"
_join "$EVDIR" findings.md
MDFILE="$JOINED"
_join "$EVDIR" raw
RAWDIR="$JOINED"
_join "$EVDIR" schema-version
VERFILE="$JOINED"

_pick_json_tool
TMPD=""
trap _cleanup EXIT
_mktmp

case "$CMD" in
  init)
    _cmd_init 0 || exit 1
    exit 0
    ;;
  validate) _cmd_validate ;;
  append) _cmd_append ;;
  disposition) _cmd_disposition ;;
  render) _cmd_render ;;
  export-tsv) _cmd_export_tsv ;;
  migrate) _cmd_migrate ;;
esac
