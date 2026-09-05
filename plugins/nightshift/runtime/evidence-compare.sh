#!/usr/bin/env bash
# evidence-compare.sh — score one baseline against the ledger as it stands now.
#
#   evidence-compare.sh --project DIR --baseline ID [--json|--md]
#
# Reruns nothing and measures nothing. It reads $NS/evidence/findings.jsonl, takes the baseline
# record carrying that id, and classifies every finding of the baseline's source — the records
# whose sourceClass is the baseline's, plus the deduped records that keep it in sources[] — as
# one of eight classes, by id and digest against the state the baseline recorded in
# details.observed[]. The verdict is the completion mode's, and the mode comes from tonight's
# shift policy through the one resolver.
#
# Two things speak for a finding now: its own latest record, and the latest baseline record of
# the same source — a re-measurement, whose details.observed[] is what the source reports today.
# A record wins wherever one exists. Without one, an id is cleared only when a re-measurement no
# longer reports it; with no re-measurement at all it is unavailable, because nothing has looked
# since the baseline.
#
# The classes, and what decides each one:
#   human-only          status human-only
#   unavailable         status unavailable, unsupported or unmeasured; an id with no record that
#                       no re-measurement speaks for; or the source itself is unavailable, which
#                       overrides every class below
#   cleared             status fixed, or a re-measurement of the source no longer reports the id
#                       (never when the environment moved — that absence is unavailable)
#   rejected-duplicate  status rejected with disposition duplicate or rejected-duplicate
#   parked              disposition parked, or any other rejected record
#   new                 reported now, and the baseline did not see it
#   unchanged           still reported, with the digest the baseline recorded
#   regressed           still reported, with a digest the baseline did not record
#
# Above all of them, the source itself. It is unavailable when a record of it at or after the
# baseline reports status unavailable, or when the latest environment digest recorded for it is
# not the baseline's. Then every row is unavailable: a tool that failed, a source that went away
# and an environment that moved are never rendered as improvement. status unsupported and
# unmeasured stay with the one finding that carries them — they describe a surface, not the tool.
# Dedupe never erases an originating tool either: a row's sources[] is the union of the record's
# sources[] and its own sourceClass, in byte order.
#
# Modes: clear-all passes when the source itself is available and no row is new, unchanged,
# regressed or unavailable. The source is judged on its own, not through its rows, so a tool that
# failed or an environment that moved fails the mode even when the baseline had seen nothing to
# report. `sourceStatus` carries that answer in both renderings; no row is invented to hold it.
# no-regression-plus-selected-debt passes when no row is regressed and every selected debt id
# this baseline covers is cleared; an id it does not cover is scored by that source's own
# comparison.
#
# The comparison is read-only: no ledger write, no rerun, no file of its own.
# Exit: 0 rendered — the verdict is the pass field, not this code · 1 usage, or a ledger line
#       that is not JSON · 2 contract failure
#
# The logic is bash. jq (preferred) or python3 covers exactly one job: turning the ledger's JSON
# Lines into a flat fact stream, every value carried both as its own compact JSON and as display
# text. Ids and digests are compared as JSON texts, so nothing has to be unescaped, and the two
# halves emit the same bytes for the same ledger.
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
EC_JQ="$(ns_native_display_path "$_here/evidence-compare.jq")"

EC_NL='
'
EC_TAB=$(printf '\t')
EC_CR=$(printf '\r')
EC_VT=$(printf '\013')
EC_FF=$(printf '\014')
EC_FS=$(printf '\037')
EC_RS=$(printf '\036')

# The class names, in byte order. The summary object and the mode's blocking
# set all read this one list, so no two of them can name a different set of classes.
EC_CLASSES="cleared
human-only
new
parked
regressed
rejected-duplicate
unavailable
unchanged"

usage() {
  printf 'usage: evidence-compare.sh --project DIR --baseline ID [--json|--md]\n' >&2
  exit 1
}

die() {
  printf 'evidence-compare: %s\n' "$1" >&2
  exit "$2"
}

# ---------------------------------------------------------------- small helpers

# _ec_strip TEXT -> STRIPPED, mirroring str.strip() over ASCII whitespace.
_ec_strip() {
  local s="$1"
  while [ -n "$s" ]; do
    case "$s" in
      " "* | "$EC_TAB"* | "$EC_NL"* | "$EC_CR"* | "$EC_VT"* | "$EC_FF"*) s="${s#?}" ;;
      *) break ;;
    esac
  done
  while [ -n "$s" ]; do
    case "$s" in
      *" " | *"$EC_TAB" | *"$EC_NL" | *"$EC_CR" | *"$EC_VT" | *"$EC_FF") s="${s%?}" ;;
      *) break ;;
    esac
  done
  STRIPPED="$s"
}

# _ec_is_str JSONTEXT — status 0 when the text encodes a JSON string.
_ec_is_str() {
  case "$1" in
    '"'*'"') return 0 ;;
  esac
  return 1
}

_ec_mktmp() {
  local base="${TMPDIR:-/tmp}" n=0 d
  if command -v mktemp >/dev/null 2>&1; then
    TMPD="$(mktemp -d "${base%/}/ns-compare.XXXXXX")" || die 'cannot create a temporary directory' 2
  else
    case "$base" in
      */) base="${base%/}" ;;
    esac
    while [ "$n" -lt 64 ]; do
      d="$base/ns-compare-$$-$n"
      if mkdir "$d" 2>/dev/null; then
        TMPD="$d"
        break
      fi
      n=$((n + 1))
    done
    [ -n "${TMPD:-}" ] || die 'cannot create a temporary directory' 2
  fi
  chmod 700 "$TMPD" || {
    rm -rf "$TMPD"
    TMPD=""
    die 'cannot create a temporary directory' 2
  }
}

# shellcheck disable=SC2317,SC2329 # trap EXIT invokes this
_ec_cleanup() { [ -z "${TMPD:-}" ] || rm -rf "$TMPD"; }

# ---------------------------------------------------------------- the fact stream

# One inline program per half. The python half writes what the jq half writes, byte for byte:
# non-ASCII stays raw, so a ledger written by either tool compares the same either way.
PY='
import json, re, sys

FS, RS = sys.argv[1], sys.argv[2]
CTRL = re.compile(r"[\x00-\x1f\x7f]")
out = []


def enc(v):
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def txt(v):
    return CTRL.sub(" ", v if isinstance(v, str) else enc(v))


def field(r, k):
    return r.get(k) if isinstance(r, dict) else None


def obj(v):
    return v if isinstance(v, dict) else {}


def arr(v):
    return v if isinstance(v, list) else []


def frame(fields):
    out.append(FS.join(fields) + RS)


text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
lines = [one for one in text.split("\n") if one != ""]
for i, line in enumerate(lines):
    n = str(i)
    try:
        rec = json.loads(line)
    except ValueError:
        frame(["b", n])
        continue
    d = obj(field(rec, "details"))
    frame(["f", n,
           enc(field(rec, "domain")), enc(field(rec, "sourceClass")),
           enc(field(rec, "status")), enc(field(rec, "disposition")),
           enc(field(rec, "duplicateOf")),
           enc(field(rec, "id")), enc(field(rec, "digest")), enc(field(rec, "locator")),
           txt(field(rec, "id")), txt(field(rec, "digest")), txt(field(rec, "locator")),
           txt(field(rec, "sourceClass")), txt(field(rec, "source"))])
    for k, one in enumerate(arr(field(rec, "sources"))):
        frame(["s", n, str(k), "s" if isinstance(one, str) else "x", enc(one), txt(one)])
    if isinstance(d.get("environmentDigest"), str):
        frame(["e", n, enc(d["environmentDigest"])])
    for k, one in enumerate(arr(d.get("seen"))):
        entry = obj(one)
        frame(["o", n, str(k),
               enc(entry.get("id")), enc(entry.get("digest")),
               txt(entry.get("id")), txt(entry.get("digest"))])
sys.stdout.write("".join(out))
'

# Records live in the R_ arrays, the baseline's observed entries in the OBS_ arrays, both indexed
# the way the fact stream indexes them: R_ by ledger line, OBS_ by arrival.
NLINE=0
NREC=0
NOBS=0
BADLINE=""
LNO=()
R_DOMAIN=()
R_CLASSJ=()
R_CLASST=()
R_STATUS=()
R_DISP=()
R_DUPOF=()
R_IDJ=()
R_IDT=()
R_DIGJ=()
R_DIGT=()
R_LOCJ=()
R_LOCT=()
R_SOURCE=()
R_SRC=()
R_BADSRC=()
R_ENVJ=()
EXTRA_SRC=()
OBS_IDX=()
OBS_IDJ=()
OBS_DIGJ=()
OBS_IDT=()
OBS_DIGT=()

# _ec_read_ledger — the ledger's non-blank lines, with the line number each one came from.
_ec_read_ledger() {
  local line="" i=0
  {
    while IFS= read -r line || [ -n "$line" ]; do
      i=$((i + 1))
      _ec_strip "$line"
      [ -n "$STRIPPED" ] || continue
      LNO[NLINE]="$i"
      NLINE=$((NLINE + 1))
      printf '%s\n' "$STRIPPED"
    done <"$JSONL"
  } >"$TMPD/lines"
}

# _ec_load — the fact stream into the arrays.
_ec_load() {
  local tag x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 i
  if [ "$JSON_TOOL" = jq ]; then
    jq -Rsj -f "$EC_JQ" --arg FS "$EC_FS" --arg RS "$EC_RS" <"$TMPD/lines" >"$TMPD/facts" ||
      die 'cannot read the ledger' 2
  else
    python3 -c "$PY" "$EC_FS" "$EC_RS" <"$TMPD/lines" >"$TMPD/facts" ||
      die 'cannot read the ledger' 2
  fi
  while IFS="$EC_FS" read -r -d "$EC_RS" \
    tag x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14; do
    i="$x1"
    case "$tag" in
      f)
        R_DOMAIN[i]="$x2"
        R_CLASSJ[i]="$x3"
        R_STATUS[i]="$x4"
        R_DISP[i]="$x5"
        R_DUPOF[i]="$x6"
        R_IDJ[i]="$x7"
        R_DIGJ[i]="$x8"
        R_LOCJ[i]="$x9"
        R_IDT[i]="$x10"
        R_DIGT[i]="$x11"
        R_LOCT[i]="$x12"
        R_CLASST[i]="$x13"
        R_SOURCE[i]="$x14"
        R_SRC[i]=""
        R_BADSRC[i]=""
        R_ENVJ[i]=""
        NREC=$((i + 1))
        ;;
      s)
        [ "$x3" = s ] || R_BADSRC[i]=1
        R_SRC[i]="${R_SRC[$i]}$x4$EC_TAB$x5$EC_NL"
        ;;
      e) R_ENVJ[i]="$x2" ;;
      o)
        OBS_IDX[NOBS]="$i"
        OBS_IDJ[NOBS]="$x3"
        OBS_DIGJ[NOBS]="$x4"
        OBS_IDT[NOBS]="$x5"
        OBS_DIGT[NOBS]="$x6"
        NOBS=$((NOBS + 1))
        ;;
      b) [ -n "$BADLINE" ] || BADLINE="$i" ;;
    esac
  done <"$TMPD/facts"
  [ -z "$BADLINE" ] ||
    die "malformed JSON on line ${LNO[$BADLINE]}" 1
}

# ---------------------------------------------------------------- scope

# _ec_is_finding I — status 0 unless the record is a lifecycle record rather than a finding.
_ec_is_finding() {
  case "${R_DOMAIN[$1]}" in
    '"baseline"' | '"checkpoint"') return 1 ;;
  esac
  return 0
}

# _ec_in_scope I — status 0 when the record belongs to the baseline's source: its own
# sourceClass is the baseline's, or it kept the baseline's tool in sources[] after a dedupe.
_ec_in_scope() {
  [ "${R_CLASSJ[$1]}" != "$BCLASSJ" ] || return 0
  case "$EC_NL${R_SRC[$1]}" in
    *"$EC_NL$BCLASSJ$EC_TAB"*) return 0 ;;
  esac
  return 1
}

# _ec_find_baseline — the first baseline record carrying the id, and the source it baselines. The
# first, because the state that record wrote down is the reference; a later record of the same
# source, id or no id, is a re-measurement of it.
_ec_find_baseline() {
  local i=0 seen=0
  BPOS=-1
  while [ "$i" -lt "$NREC" ]; do
    if [ "${R_IDT[$i]}" = "$BASELINE" ]; then
      seen=1
      if [ "${R_DOMAIN[$i]}" = '"baseline"' ] && [ "$BPOS" -lt 0 ]; then
        BPOS="$i"
      fi
    fi
    i=$((i + 1))
  done
  if [ "$BPOS" -lt 0 ]; then
    [ "$seen" -eq 0 ] || die "$BASELINE is not a baseline record" 2
    die "no baseline record with id $BASELINE" 2
  fi
  BIDJ="${R_IDJ[$BPOS]}"
  BIDT="${R_IDT[$BPOS]}"
  BCLASSJ="${R_CLASSJ[$BPOS]}"
  BCLASST="${R_CLASST[$BPOS]}"
  BCOMMANDT="${R_SOURCE[$BPOS]}"
  _ec_is_str "$BCLASSJ" || die "baseline $BASELINE records no sourceClass" 2
}

# _ec_find_recheck — the latest baseline record of the source at or after the chosen one. A later
# one is a re-measurement, and its observed list is what the source reports today.
_ec_find_recheck() {
  local i
  RPOS="$BPOS"
  RECHECKED=0
  i=$((BPOS + 1))
  while [ "$i" -lt "$NREC" ]; do
    if [ "${R_DOMAIN[$i]}" = '"baseline"' ] && _ec_in_scope "$i"; then
      RPOS="$i"
      RECHECKED=1
    fi
    i=$((i + 1))
  done
}

# _ec_obs REC IDJSON -> OBSK: that record's observed entry for the id, or -1.
_ec_obs() {
  local k=0
  OBSK=-1
  while [ "$k" -lt "$NOBS" ]; do
    if [ "${OBS_IDX[$k]}" = "$1" ] && [ "${OBS_IDJ[$k]}" = "$2" ]; then
      OBSK="$k"
    fi
    k=$((k + 1))
  done
}

# _ec_check_scope — the contract the comparison needs from the records it is about to read.
_ec_check_scope() {
  local i=0 k=0 idx
  while [ "$i" -lt "$NREC" ]; do
    if _ec_in_scope "$i"; then
      [ -z "${R_BADSRC[$i]}" ] ||
        die "line ${LNO[$i]} records a source that is not a string" 2
      if _ec_is_finding "$i"; then
        _ec_is_str "${R_IDJ[$i]}" || die "line ${LNO[$i]} carries no string id" 2
      fi
    fi
    i=$((i + 1))
  done
  while [ "$k" -lt "$NOBS" ]; do
    idx="${OBS_IDX[$k]}"
    if [ "$idx" = "$BPOS" ] || [ "$idx" = "$RPOS" ]; then
      _ec_is_str "${OBS_IDJ[$k]}" ||
        die "line ${LNO[$idx]} records an observed entry with no string id" 2
    fi
    k=$((k + 1))
  done
}

# _ec_environment_moved — 1 when another baseline of the same source class was taken in a
# different environment. Matches PowerShell: only cleared rows downgrade, not every row.
_ec_environment_moved() {
  local i=0 other
  ENV_MOVED=0
  [ -n "$BENVJ" ] || return 0
  while [ "$i" -lt "$NREC" ]; do
    if [ "$i" != "$BPOS" ] && [ "${R_DOMAIN[$i]}" = '"baseline"' ] && _ec_in_scope "$i"; then
      other="${R_ENVJ[$i]}"
      if [ -n "$other" ] && [ "$other" != "$BENVJ" ]; then
        ENV_MOVED=1
        return 0
      fi
    fi
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------- rows

C_CLEARED=0
C_HUMAN_ONLY=0
C_NEW=0
C_PARKED=0
C_REGRESSED=0
C_REJECTED_DUPLICATE=0
C_UNAVAILABLE=0
C_UNCHANGED=0

_ec_bump() {
  case "$1" in
    cleared) C_CLEARED=$((C_CLEARED + 1)) ;;
    human-only) C_HUMAN_ONLY=$((C_HUMAN_ONLY + 1)) ;;
    new) C_NEW=$((C_NEW + 1)) ;;
    parked) C_PARKED=$((C_PARKED + 1)) ;;
    regressed) C_REGRESSED=$((C_REGRESSED + 1)) ;;
    rejected-duplicate) C_REJECTED_DUPLICATE=$((C_REJECTED_DUPLICATE + 1)) ;;
    unavailable) C_UNAVAILABLE=$((C_UNAVAILABLE + 1)) ;;
    unchanged) C_UNCHANGED=$((C_UNCHANGED + 1)) ;;
  esac
}

# _ec_count CLASS -> COUNT
_ec_count() {
  case "$1" in
    cleared) COUNT="$C_CLEARED" ;;
    human-only) COUNT="$C_HUMAN_ONLY" ;;
    new) COUNT="$C_NEW" ;;
    parked) COUNT="$C_PARKED" ;;
    regressed) COUNT="$C_REGRESSED" ;;
    rejected-duplicate) COUNT="$C_REJECTED_DUPLICATE" ;;
    unavailable) COUNT="$C_UNAVAILABLE" ;;
    unchanged) COUNT="$C_UNCHANGED" ;;
    *) COUNT=0 ;;
  esac
}

# _ec_ids — every id this comparison covers, once each, in byte order: what the baseline saw,
# what a re-measurement reports, and what the source's records carry.
_ec_ids() {
  local k idx
  {
    k=0
    while [ "$k" -lt "$NOBS" ]; do
      idx="${OBS_IDX[$k]}"
      if [ "$idx" = "$BPOS" ] || [ "$idx" = "$RPOS" ]; then
        printf '%s\n' "${OBS_IDJ[$k]}"
      fi
      k=$((k + 1))
    done
    k=0
    while [ "$k" -lt "$NREC" ]; do
      if _ec_is_finding "$k" && _ec_in_scope "$k"; then
        printf '%s\n' "${R_IDJ[$k]}"
      fi
      k=$((k + 1))
    done
  } | LC_ALL=C sort -u >"$TMPD/ids"
}

# _ec_record_source_lines I — every originating tool line for one record, tab-separated json+text.
_ec_record_source_lines() {
  local i cls src
  i="$1"
  cls="${R_CLASST[$i]:-}"
  src="${R_SOURCE[$i]:-}"
  if [ -n "${R_SRC[$i]}" ]; then
    printf '%s' "${R_SRC[$i]}"
    return 0
  fi
  if [ -n "$src" ] && [ -n "$cls" ] && [ "$src" = "${cls} ." ]; then
    printf '%s%s%s\n' "$(_ec_json_string "$cls")" "$EC_TAB" "$cls"
  elif [ -n "$src" ]; then
    printf '%s%s%s\n' "$(_ec_json_string "$src")" "$EC_TAB" "$src"
  elif [ -n "$cls" ]; then
    printf '%s%s%s\n' "$(_ec_json_string "$cls")" "$EC_TAB" "$cls"
  fi
}

# _ec_build_extra_sources — a rejected duplicate's tools join the survivor's row.
_ec_build_extra_sources() {
  local i=0 j=0
  while [ "$i" -lt "$NREC" ]; do
    if _ec_is_finding "$i" && _ec_in_scope "$i" && _ec_is_str "${R_DUPOF[$i]}"; then
      j=0
      while [ "$j" -lt "$NREC" ]; do
        if _ec_is_finding "$j" && _ec_in_scope "$j" && [ "${R_IDJ[$j]}" = "${R_DUPOF[$i]}" ]; then
          EXTRA_SRC[j]="${EXTRA_SRC[j]:-}$(_ec_record_source_lines "$i")"
          break
        fi
        j=$((j + 1))
      done
    fi
    i=$((i + 1))
  done
}

# _ec_json_string TEXT -> QUOTED: one JSON string literal for splicing into arrays.
_ec_json_string() {
  local s="$1" out="" i=0 c=""
  out='"'
  while [ "$i" -lt "${#s}" ]; do
    c="${s:$i:1}"
    case "$c" in
      \\) out="${out}\\\\" ;;
      \") out="${out}\\\"" ;;
      *) out="${out}${c}" ;;
    esac
    i=$((i + 1))
  done
  printf '%s"' "$out"
}

# _ec_source_unavailable — 1 when a baseline of this source at or after the chosen one failed.
_ec_source_unavailable() {
  local i="$BPOS"
  SOURCE_UNAVAILABLE=0
  while [ "$i" -lt "$NREC" ]; do
    if [ "${R_DOMAIN[$i]}" = '"baseline"' ] && _ec_in_scope "$i"; then
      case "${R_STATUS[$i]}" in
        '"unavailable"') SOURCE_UNAVAILABLE=1; return 0 ;;
      esac
    fi
    i=$((i + 1))
  done
}

# _ec_sources I -> SRCJSON, SRCTEXT: every originating tool of the row, in byte order. I is -1
# for a finding the baseline saw and no record carries now, whose only tool is the baseline's.
_ec_sources() {
  local i="$1" line tool
  SRCJSON=""
  SRCTEXT=""
  {
    if [ "$i" -ge 0 ]; then
      _ec_record_source_lines "$i"
      printf '%s' "${EXTRA_SRC[$i]:-}"
    elif [ -n "$BCOMMANDT" ]; then
      printf '%s%s%s\n' "$(_ec_json_string "$BCOMMANDT")" "$EC_TAB" "$BCOMMANDT"
    else
      printf '%s%s%s\n' "$BCLASSJ" "$EC_TAB" "$BCLASST"
    fi
  } | LC_ALL=C sort -u >"$TMPD/src"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tool="${line#*"$EC_TAB"}"
    [ -n "$tool" ] || continue
    SRCJSON="$SRCJSON${SRCJSON:+,}$(_ec_json_string "$tool")"
    SRCTEXT="$SRCTEXT${SRCTEXT:+, }$tool"
  done <"$TMPD/src"
  SRCJSON="[$SRCJSON]"
}

ROW_IDJ=()
ROW_IDT=()
ROW_CLASS=()
ROW_DIGJ=()
ROW_DIGT=()
ROW_LOCJ=()
ROW_LOCT=()
ROW_SRCJ=()
ROW_SRCT=()
NROW=0
NOUT=0
OUTSTANDING_IDJ=()
OUTSTANDING_IDT=()

# _ec_row IDJSON — one classified row, appended to the ROW_ arrays.
_ec_row() {
  local idj="$1" cur=-1 obs=-1 now=-1 i=0 k class
  while [ "$i" -lt "$NREC" ]; do
    if _ec_is_finding "$i" && _ec_in_scope "$i" && [ "${R_IDJ[$i]}" = "$idj" ]; then
      cur="$i"
    fi
    i=$((i + 1))
  done
  _ec_obs "$BPOS" "$idj"
  obs="$OBSK"
  if [ "$RECHECKED" -eq 1 ]; then
    _ec_obs "$RPOS" "$idj"
    now="$OBSK"
  fi
  if [ "$cur" -lt 0 ]; then
    if [ "$RECHECKED" -ne 1 ]; then
      class=unavailable
    elif [ "$now" -lt 0 ]; then
      if [ "$ENV_MOVED" -eq 1 ]; then class=unavailable; else class=cleared; fi
    elif [ "$obs" -lt 0 ]; then
      class=new
    elif [ "${OBS_DIGJ[$now]}" = "${OBS_DIGJ[$obs]}" ] && _ec_is_str "${OBS_DIGJ[$now]}"; then
      class=unchanged
    else
      class=regressed
    fi
    k="$obs"
    [ "$now" -lt 0 ] || k="$now"
    ROW_IDT[NROW]="${OBS_IDT[$k]}"
    ROW_DIGJ[NROW]="${OBS_DIGJ[$k]}"
    ROW_DIGT[NROW]="${OBS_DIGT[$k]}"
    ROW_LOCJ[NROW]='""'
    ROW_LOCT[NROW]=""
    _ec_sources -1
  else
    case "${R_STATUS[$cur]}" in
      '"human-only"') class=human-only ;;
      '"unavailable"' | '"unsupported"' | '"unmeasured"') class=unavailable ;;
      '"fixed"')
        if [ "$ENV_MOVED" -eq 1 ]; then class=unavailable; else class=cleared; fi
        ;;
      '"rejected"')
        if _ec_is_str "${R_DUPOF[$cur]}"; then
          class=rejected-duplicate
        else
          case "${R_DISP[$cur]}" in
            '"duplicate"' | '"rejected-duplicate"') class=rejected-duplicate ;;
            *) class=parked ;;
          esac
        fi
        ;;
      *)
        if [ "${R_DISP[$cur]}" = '"parked"' ]; then
          class=parked
        elif [ "$obs" -lt 0 ]; then
          class=new
        elif [ "${R_DIGJ[$cur]}" = "${OBS_DIGJ[$obs]}" ] && _ec_is_str "${R_DIGJ[$cur]}"; then
          class=unchanged
        else
          class=regressed
        fi
        ;;
    esac
    ROW_IDT[NROW]="${R_IDT[$cur]}"
    ROW_DIGJ[NROW]="${R_DIGJ[$cur]}"
    ROW_DIGT[NROW]="${R_DIGT[$cur]}"
    ROW_LOCJ[NROW]="${R_LOCJ[$cur]}"
    ROW_LOCT[NROW]="${R_LOCT[$cur]}"
    _ec_sources "$cur"
  fi
  if [ "$SOURCE_UNAVAILABLE" -eq 1 ]; then
    class=unavailable
  fi
  ROW_IDJ[NROW]="$idj"
  ROW_CLASS[NROW]="$class"
  ROW_SRCJ[NROW]="$SRCJSON"
  ROW_SRCT[NROW]="$SRCTEXT"
  _ec_bump "$class"
  NROW=$((NROW + 1))
}

_ec_rows() {
  local idj
  _ec_ids
  while IFS= read -r idj; do
    [ -n "$idj" ] || continue
    _ec_row "$idj"
  done <"$TMPD/ids"
}

# ---------------------------------------------------------------- the verdict

# _ec_verdict -> PASS. clear-all wants every measured finding cleared, so an unavailable source
# fails it: not knowing is not the same as being clean. That holds however many rows the source
# carries — a tool that could not run, or an environment that moved, reports nothing whether or
# not the baseline had seen anything, and an empty answer from a source that never spoke is not a
# clean one. A source that did run and genuinely found nothing keeps its pass.
# no-regression-plus-selected-debt wants no regression and the owner's selected ids cleared, and
# an unavailable source clears nothing, so its own rule already covers what it promises.
_ec_verdict() {
  local i idj found cleared
  PASS=true
  NOUT=0
  if [ "$MODE" = clear-all ]; then
    if [ "$SOURCE_UNAVAILABLE" -eq 1 ] || [ "$ENV_MOVED" -eq 1 ]; then
      PASS=false
    fi
    i=0
    while [ "$i" -lt "$NROW" ]; do
      case "${ROW_CLASS[$i]}" in
        new | unchanged | regressed | unavailable) PASS=false ;;
      esac
      i=$((i + 1))
    done
  else
    i=0
    while [ "$i" -lt "$NROW" ]; do
      [ "${ROW_CLASS[$i]}" != regressed ] || PASS=false
      i=$((i + 1))
    done
  fi
  while IFS= read -r idj; do
    [ -n "$idj" ] || continue
    found=0
    cleared=0
    i=0
    while [ "$i" -lt "$NROW" ]; do
      if [ "${ROW_IDJ[$i]}" = "$idj" ]; then
        found=1
        [ "${ROW_CLASS[$i]}" != cleared ] || cleared=1
      fi
      i=$((i + 1))
    done
    if [ "$found" -eq 1 ] && [ "$cleared" -ne 1 ]; then
      OUTSTANDING_IDJ[NOUT]="$idj"
      OUTSTANDING_IDT[NOUT]="$idj"
      case "$idj" in
        \"*\") OUTSTANDING_IDT[NOUT]="${idj#\"}"; OUTSTANDING_IDT[NOUT]="${OUTSTANDING_IDT[NOUT]%\"}" ;;
      esac
      NOUT=$((NOUT + 1))
      if [ "$MODE" != clear-all ]; then
        PASS=false
      fi
    fi
  done <"$TMPD/debt"
}

# ---------------------------------------------------------------- rendering

# _ec_source_status — the source's own answer, which no row can carry when there are no rows.
# A tool that failed and an environment that moved both mean nothing looked; everything else
# means the source spoke, even if what it said was that it found nothing.
_ec_source_status() {
  if [ "$SOURCE_UNAVAILABLE" -eq 1 ] || [ "$ENV_MOVED" -eq 1 ]; then
    printf 'unavailable'
  else
    printf 'available'
  fi
}

# _ec_render_json — sorted keys, compact, one trailing newline. Every id, digest, locator and
# tool is spliced in as the compact JSON the ledger holds, so the document needs no escaper.
_ec_render_json() {
  local out i=0 class first=1 dfirst
  out="{\"baseline\":$BIDJ,\"mode\":\"$MODE\",\"pass\":$PASS,\"rows\":["
  while [ "$i" -lt "$NROW" ]; do
    [ "$i" -eq 0 ] || out="$out,"
    out="$out{\"class\":\"${ROW_CLASS[$i]}\",\"digest\":${ROW_DIGJ[$i]},\"id\":${ROW_IDJ[$i]}"
    out="$out,\"locator\":${ROW_LOCJ[$i]},\"sources\":${ROW_SRCJ[$i]}}"
    i=$((i + 1))
  done
  out="$out],\"schemaVersion\":1,\"sourceStatus\":\"$(_ec_source_status)\",\"summary\":{"
  first=1
  while IFS= read -r class; do
    [ -n "$class" ] || continue
    if [ "$class" = unavailable ]; then
      out="$out,\"selectedDebtOutstanding\":["
      i=0
      dfirst=1
      while [ "$i" -lt "$NOUT" ]; do
        [ "$dfirst" -eq 1 ] || out="$out,"
        dfirst=0
        out="$out${OUTSTANDING_IDJ[$i]}"
        i=$((i + 1))
      done
      out="$out],\"total\":$NROW"
    fi
    _ec_count "$class"
    [ "$first" -eq 1 ] || out="$out,"
    first=0
    out="$out\"$class\":$COUNT"
  done <<EOF
$EC_CLASSES
EOF
  out="$out}}"
  printf '%s\n' "$out"
}

_ec_render_md() {
  local md dash="—" i=0 word=fail class counts="" short=""
  [ "$PASS" = true ] && word=pass
  md="# Comparison$EC_NL$EC_NL"
  md="${md}Baseline: ${BIDT} ${dash} ${BCLASST} ${dash} \`${BCOMMANDT}\`${EC_NL}"
  md="${md}Mode: ${MODE}${EC_NL}"
  md="${md}Source: $(_ec_source_status)${EC_NL}"
  md="${md}Result: ${word}${EC_NL}${EC_NL}"
  md="${md}| ID | Class | Digest | Sources | Locator |${EC_NL}"
  md="${md}| --- | --- | --- | --- | --- |${EC_NL}"
  i=0
  while [ "$i" -lt "$NROW" ]; do
    short="${ROW_DIGT[$i]}"
    if [ "${#short}" -gt 12 ]; then
      short="${short:0:12}"
    fi
    loc="${ROW_LOCT[$i]}"
    [ -n "$short" ] || short="—"
    [ -n "$loc" ] || loc="—"
    md="${md}| ${ROW_IDT[$i]} | ${ROW_CLASS[$i]} | ${short} | ${ROW_SRCT[$i]} | ${loc} |${EC_NL}"
    i=$((i + 1))
  done
  if [ "$NROW" -eq 0 ]; then
    md="${md}| — | — | — | — | $(_ec_source_status | sed 's/^available$/empty/') |${EC_NL}"
  fi
  md="${md}${EC_NL}Summary: "
  for class in new cleared unchanged regressed unavailable rejected-duplicate parked human-only; do
    _ec_count "$class"
    counts="${counts}${counts:+, }${class} ${COUNT}"
  done
  md="${md}${counts}${EC_NL}"
  if [ "$NOUT" -gt 0 ]; then
    md="${md}Selected debt outstanding: "
    i=0
    counts=""
    while [ "$i" -lt "$NOUT" ]; do
      counts="${counts}${counts:+,}${OUTSTANDING_IDT[$i]:-${OUTSTANDING_IDJ[$i]}}}"
      i=$((i + 1))
    done
    md="${md}${counts}${EC_NL}"
  fi
  printf '%s' "$md"
}

# ---------------------------------------------------------------- entry point

PROJECT_ARG=""
BASELINE=""
FORMAT=json
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || usage
      PROJECT_ARG="$2"
      shift 2
      ;;
    --baseline)
      [ $# -ge 2 ] || usage
      BASELINE="$2"
      shift 2
      ;;
    --json)
      FORMAT=json
      shift
      ;;
    --md)
      FORMAT=md
      shift
      ;;
    *) usage ;;
  esac
done
[ -n "$PROJECT_ARG" ] || usage
[ -n "$BASELINE" ] || usage

PROJECT="$(cd -P "$(ns_msys_path "$PROJECT_ARG")" 2>/dev/null && pwd)"
[ -n "$PROJECT" ] || die "cannot read $PROJECT_ARG" 2
JSONL="$PROJECT/.nightshift/evidence/findings.jsonl"
[ -f "$JSONL" ] || die "no ledger at $JSONL" 2

JSON_TOOL="$(ns_policy_json_tool)" || die 'JSON parser unavailable; compare in the skill' 2
MODE="$(ns_policy_completion_mode "$PROJECT")"

TMPD=""
trap _ec_cleanup EXIT
_ec_mktmp
ns_policy_selected_debt "$PROJECT" >"$TMPD/debt"

_ec_read_ledger
_ec_load
_ec_find_baseline
BENVJ="${R_ENVJ[$BPOS]}"
_ec_find_recheck
_ec_check_scope
_ec_build_extra_sources
_ec_source_unavailable
_ec_environment_moved
_ec_rows
_ec_verdict

case "$FORMAT" in
  json) _ec_render_json ;;
  md) _ec_render_md ;;
esac
if [ "$PASS" = true ]; then
  exit 0
fi
exit 3
