#!/usr/bin/env bash
# provision-recover.sh — finish or undo a provisioning transaction, natively.
#
#   provision-recover.sh --project DIR [--budget-seconds N]
#   provision-recover.sh --project DIR --rollback [--budget-seconds N]
#   provision-recover.sh --project DIR --diagnose
#
# Reads .nightshift/run/provision-transaction.json and settles it. A failed transaction, or one
# that stopped at authorize, capture-baseline, apply, smoke, or rollback, returns every
# recorded path to its captured baseline and the restore is then proven: each file that
# existed matches its baseline digest, and each path the install created is gone. Only a
# proven restore clears the blob store and the transaction. A transaction that reached record
# or commit-tooling finishes those two stages here — the inventory row and the tooling commit.
# --rollback undoes a transaction whatever stage it reached. --diagnose writes nothing and
# prints one tab-separated diagnosis line for Doctor.
#
# Output is one line of compact JSON with sorted keys, so every host prints the same bytes.
# Exit: 0 ok · 1 usage or runtime failure · 2 malformed transaction, naming the field
#       · 3 the restore is unproven — baseline, blob store, and transaction are left in place
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

TAB=$(printf '\t')

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0" >&2
  exit 1
}

die() {
  printf 'provision-recover: %s\n' "$1" >&2
  exit "$2"
}

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
MODE=recover
BUDGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || usage
      PROJECT="$2"
      shift 2
      ;;
    --budget-seconds)
      [ $# -ge 2 ] || usage
      BUDGET="$2"
      shift 2
      ;;
    --rollback)
      MODE=rollback
      shift
      ;;
    --diagnose)
      MODE=diagnose
      shift
      ;;
    -h | --help) usage ;;
    *)
      printf 'provision-recover: unknown argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done

# The budget bounds recipe commands. Recovery runs none of them, so it is checked and
# carried no further; a caller may still pass it on the same command line as apply.
case "$BUDGET" in
  '') ;;
  *[!0-9]*) usage ;;
esac

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || die "cannot cd to $PROJECT" 1
WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" ||
    die 'invalid .nightshift-link — Nightshift will not guess a workspace' 1
fi
NS="$WORKSPACE/.nightshift"
declare TX STORE INV
ns_layout_set TX "$NS" provision-transaction
ns_layout_set STORE "$NS" provision-baseline
ns_layout_set INV "$NS" capabilities

# ---------------------------------------------------------------- JSON reading

# One fact program reads both documents this helper needs: the transaction, and the recipe the
# transaction names. Every payload travels as a JSON text, so no value can carry a tab or a
# newline and the stream stays line-safe. The two halves emit the same bytes.
FACTS_JQ='
def p: tojson;
if type != "object" then "k\tother"
else
  "k\tobject",
  ("s\t" + (.stage | p)),
  ("c\t" + (.capabilityId | p)),
  ("w\t" + (.workTarget | p)),
  ("f\t" + (.failed | p)),
  ("r\t" + (.recipePath | p)),
  ("g\t" + (.touched | type)),
  (if (.touched | type) == "array" then (.touched[] | "u\t" + p) else empty end),
  ("a\t" + (.allowedFiles | type)),
  (if (.allowedFiles | type) == "array" then (.allowedFiles[] | "p\t" + p) else empty end),
  ("b\t" + (.baseline | type)),
  (if (.baseline | type) == "object"
   then (.baseline | to_entries | sort_by(.key)[]
         | "e\t" + (.key | p) + "\t" + (.value | type) + "\t"
           + (if (.value | type) == "object" then (.value.existed | p) else "null" end) + "\t"
           + (if (.value | type) == "object" then (.value.digest | p) else "null" end) + "\t"
           + (if (.value | type) == "object" then (.value.blob | p) else "null" end) + "\t"
           + (if (.value | type) == "object"
              then (if (.value.content | type) == "string" and (.value.content | length) > 0
                    then "1" else "0" end)
              else "0" end))
   else empty end)
end'

FACTS_PY='import json, sys


def jtype(v):
    if v is None:
        return "null"
    if v is True or v is False:
        return "boolean"
    if isinstance(v, str):
        return "string"
    if isinstance(v, dict):
        return "object"
    if isinstance(v, list):
        return "array"
    return "number"


def p(v):
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
out = []
if not isinstance(d, dict):
    out.append("k\tother")
else:
    out.append("k\tobject")
    for tag, key in (("s", "stage"), ("c", "capabilityId"), ("w", "workTarget"),
                     ("f", "failed"), ("r", "recipePath")):
        out.append("%s\t%s" % (tag, p(d.get(key))))
    for tag, key, mark in (("g", "touched", "u"), ("a", "allowedFiles", "p")):
        seq = d.get(key)
        out.append("%s\t%s" % (tag, jtype(seq)))
        if isinstance(seq, list):
            out.extend("%s\t%s" % (mark, p(x)) for x in seq)
    b = d.get("baseline")
    out.append("b\t%s" % jtype(b))
    if isinstance(b, dict):
        for rel in sorted(b):
            v = b[rel]
            if isinstance(v, dict):
                has = "1" if isinstance(v.get("content"), str) and v.get("content") else "0"
                row = (p(rel), "object", p(v.get("existed")), p(v.get("digest")),
                       p(v.get("blob")), has)
            else:
                row = (p(rel), jtype(v), "null", "null", "null", "0")
            out.append("e\t%s" % "\t".join(row))
sys.stdout.write("".join(line + "\n" for line in out))
'

CONTENT_PY='import base64, json, sys
d = json.load(open(sys.argv[1]))
b = d.get("baseline")
if not isinstance(b, dict):
    b = {}
v = b.get(sys.argv[2])
if not isinstance(v, dict):
    v = {}
c = v.get("content")
if not isinstance(c, str):
    c = ""
sys.stdout.buffer.write(base64.b64decode(c.encode("ascii")))
'

STAGE_PY='import json, sys
d = json.load(open(sys.argv[1]))
d["stage"] = "commit-tooling"
d["updatedAt"] = sys.argv[2]
sys.stdout.write(json.dumps(d, indent=2, sort_keys=True))
'

# shellcheck disable=SC2016 # jq program; $recipe/$cap/$now must not expand in bash
INVENTORY_JQ='
($recipe[0]) as $r
| (if ($r.smoke | type) == "object"
   then (if (($r.smoke.command // "") | tostring) != "" then $r.smoke.command
         elif (($r.smoke.cmd // "") | tostring) != "" then $r.smoke.cmd
         else "" end)
   elif ($r.smoke | type) == "string" then $r.smoke
   else "" end) as $command
| {capability: $cap, command: $command, source: "recipe", verifiedAt: $now,
   configFiles: (if ($r.allowedFiles | type) == "array" then $r.allowedFiles else [] end),
   recipeVersion: $r.recipeVersion, setupCommit: $setup} as $item
| (if ($base | type) == "object" then $base else {items: []} end)
| .items = (((if (.items | type) == "array" then .items else [] end)
             | map(select((type == "object") and (.capability != $cap)))) + [$item])
| .schemaVersion = 1
| .updatedAt = $now
| .tickProof = false'

INVENTORY_PY='import json, sys
recipe_path, now, cap, setup, base_text = sys.argv[1:6]
r = json.load(open(recipe_path))
if not isinstance(r, dict):
    raise SystemExit(1)
smoke = r.get("smoke")
command = ""
if isinstance(smoke, dict):
    command = smoke.get("command") or smoke.get("cmd") or ""
elif isinstance(smoke, str):
    command = smoke
allowed = r.get("allowedFiles")
if not isinstance(allowed, list):
    allowed = []
item = {"capability": cap, "command": command, "source": "recipe", "verifiedAt": now,
        "configFiles": list(allowed), "recipeVersion": r.get("recipeVersion"),
        "setupCommit": setup}
doc = json.loads(base_text)
if not isinstance(doc, dict):
    doc = {"items": []}
items = doc.get("items")
if not isinstance(items, list):
    items = []
doc["items"] = [i for i in items if isinstance(i, dict) and i.get("capability") != cap] + [item]
doc["schemaVersion"] = 1
doc["updatedAt"] = now
doc["tickProof"] = False
sys.stdout.write(json.dumps(doc, indent=2, sort_keys=True))
'

# _facts <file> — the fact stream on stdout. Status 1 when the file is not JSON.
_facts() {
  local tool
  tool="$(ns_policy_json_tool)" || return 2
  if [ "$tool" = jq ]; then
    jq -r "$FACTS_JQ" "$1" 2>/dev/null || return 1
  else
    python3 -c "$FACTS_PY" "$1" 2>/dev/null || return 1
  fi
}

F_TYPE=""
F_STAGE=null
F_CAP=null
F_TARGET=null
F_FAILED=null
F_RECIPE=null
F_TOUCHED_TYPE=null
F_TOUCHED_N=0
F_ALLOWED_TYPE=null
F_ALLOWED_N=0
F_BASELINE_TYPE=null
F_E_N=0
F_U=()
F_P=()
F_E_REL=()
F_E_VTYPE=()
F_E_EXISTED=()
F_E_DIGEST=()
F_E_BLOB=()
F_E_CONTENT=()

# _parse_facts <stream> — load one document's facts into the F_* view.
_parse_facts() {
  local tag a b c d e f
  F_TYPE=""
  F_STAGE=null
  F_CAP=null
  F_TARGET=null
  F_FAILED=null
  F_RECIPE=null
  F_TOUCHED_TYPE=null
  F_TOUCHED_N=0
  F_ALLOWED_TYPE=null
  F_ALLOWED_N=0
  F_BASELINE_TYPE=null
  F_E_N=0
  F_U=()
  F_P=()
  F_E_REL=()
  F_E_VTYPE=()
  F_E_EXISTED=()
  F_E_DIGEST=()
  F_E_BLOB=()
  F_E_CONTENT=()
  while IFS="$TAB" read -r tag a b c d e f; do
    case "$tag" in
      k) F_TYPE="$a" ;;
      s) F_STAGE="$a" ;;
      c) F_CAP="$a" ;;
      w) F_TARGET="$a" ;;
      f) F_FAILED="$a" ;;
      r) F_RECIPE="$a" ;;
      g) F_TOUCHED_TYPE="$a" ;;
      a) F_ALLOWED_TYPE="$a" ;;
      u)
        F_U[F_TOUCHED_N]="$a"
        F_TOUCHED_N=$((F_TOUCHED_N + 1))
        ;;
      p)
        F_P[F_ALLOWED_N]="$a"
        F_ALLOWED_N=$((F_ALLOWED_N + 1))
        ;;
      b) F_BASELINE_TYPE="$a" ;;
      e)
        F_E_REL[F_E_N]="$a"
        F_E_VTYPE[F_E_N]="$b"
        F_E_EXISTED[F_E_N]="$c"
        F_E_DIGEST[F_E_N]="$d"
        F_E_BLOB[F_E_N]="$e"
        F_E_CONTENT[F_E_N]="$f"
        F_E_N=$((F_E_N + 1))
        ;;
    esac
  done <<<"$1"
}

# _plain <json-text> -> PLAIN. A path or an identifier this engine wrote needs no JSON
# escaping; refusing everything else keeps the reader exact without a second parser.
PLAIN=""
_plain() {
  local s="$1"
  case "$s" in
    '"'*'"') ;;
    *) return 1 ;;
  esac
  s="${s#\"}"
  s="${s%\"}"
  # shellcheck disable=SC1003 # matching a literal backslash, not escaping a quote
  case "$s" in
    *'\'* | *'"'*) return 1 ;;
  esac
  PLAIN="$s"
}

_hex64() {
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 64 ]
}

# _rel_ok <rel> — a baseline key this helper is willing to touch: relative, no traversal,
# and never one of the owner's own state files.
_rel_ok() {
  local rel="$1" base
  [ -n "$rel" ] || return 1
  case "$rel" in /*) return 1 ;; esac
  case "/$rel/" in *'/../'* | *'/./'* | *'//'*) return 1 ;; esac
  base="${rel##*/}"
  case "$base" in
    punch-list.md | parking-lot.md | drafting-table.md | work-orders.md | \
      capability-policy.json | shift-policy.json | shift-defaults.json) return 1 ;;
  esac
}

# ---------------------------------------------------------------- byte helpers

NS_B64=""

b64_kind() {
  if command -v base64 >/dev/null 2>&1; then
    if base64 --decode </dev/null >/dev/null 2>&1; then
      printf 'long'
      return 0
    fi
    if base64 -D </dev/null >/dev/null 2>&1; then
      printf 'short'
      return 0
    fi
  fi
  if command -v openssl >/dev/null 2>&1; then
    printf 'openssl'
    return 0
  fi
  return 1
}

b64_decode() {
  [ -n "$NS_B64" ] || NS_B64="$(b64_kind)" || return 1
  case "$NS_B64" in
    long) base64 --decode ;;
    short) base64 -D ;;
    openssl) openssl base64 -d -A ;;
    *) return 1 ;;
  esac
}

# _content_bytes <rel> — the entry's baseline bytes on stdout, from the base64 fallback.
_content_bytes() {
  local tool
  tool="$(ns_policy_json_tool)" || return 1
  if [ "$tool" = python3 ]; then
    python3 -c "$CONTENT_PY" "$TX" "$1" || return 1
  else
    jq -j --arg rel "$1" '.baseline[$rel].content // ""' "$TX" 2>/dev/null | b64_decode
  fi
}

# ---------------------------------------------------------------- output

malformed() { # <field>
  if [ "$MODE" = diagnose ]; then
    printf 'malformed%sprovision-transaction.json is malformed (%s)\n' "$TAB" "$1"
    exit 0
  fi
  JSON_TOOL="$(ns_policy_json_tool)" || {
    printf '{"detail":"malformed transaction: (unprintable)","malformed":true,"ok":false,"recovered":false}\n'
    exit 2
  }
  # shellcheck disable=SC2016 # jq program; $field is a jq --arg
  "$JSON_TOOL" -n --arg field "$1" \
    '{detail: ("malformed transaction: " + $field), malformed: true, ok: false, recovered: false}'
  exit 2
}

unproven() { # <detail>
  printf '{"detail":"%s","ok":false,"proven":false,"rolledBack":false}\n' "$1"
  exit 3
}

_touched_json() {
  local i=0 out=""
  while [ "$i" -lt "$TOUCHED_N" ]; do
    out="$out${out:+,}\"${TOUCHED[i]}\""
    i=$((i + 1))
  done
  printf '[%s]' "$out"
}

# ---------------------------------------------------------------- read the transaction

if [ -L "$TX" ]; then
  malformed document
fi
if [ ! -f "$TX" ]; then
  if [ "$MODE" = diagnose ]; then
    exit 0
  fi
  printf '{"detail":"no transaction","ok":true,"recovered":false}\n'
  exit 0
fi

ns_policy_json_tool >/dev/null || die 'JSON parser unavailable; restore from provision-surface or by hand' 1

FACTS="$(_facts "$TX")" || malformed document
_parse_facts "$FACTS"
[ "$F_TYPE" = object ] || malformed document

_plain "$F_STAGE" || malformed stage
STAGE="$PLAIN"
case "$STAGE" in
  authorize | capture-baseline | apply | smoke | record | commit-tooling | rollback) ;;
  *) malformed stage ;;
esac

_plain "$F_CAP" || malformed capabilityId
CAP="$PLAIN"
[ -n "$CAP" ] || malformed capabilityId

case "$F_FAILED" in
  null | false) FAILED=0 ;;
  true) FAILED=1 ;;
  *) malformed failed ;;
esac

if [ "$F_TARGET" = null ]; then
  TARGET="$(ns_work_target "$WORKSPACE" 2>/dev/null)" || TARGET="$WORKSPACE"
else
  _plain "$F_TARGET" || malformed workTarget
  TARGET="$PLAIN"
  case "$TARGET" in /*) ;; *) malformed workTarget ;; esac
fi
TARGET="$(cd -P "$TARGET" 2>/dev/null && pwd)" || malformed workTarget

TOUCHED=()
TOUCHED_N=0
case "$F_TOUCHED_TYPE" in
  null) ;;
  array)
    i=0
    while [ "$i" -lt "$F_TOUCHED_N" ]; do
      _plain "${F_U[i]}" || malformed touched
      TOUCHED[i]="$PLAIN"
      i=$((i + 1))
    done
    TOUCHED_N="$F_TOUCHED_N"
    ;;
  *) malformed touched ;;
esac

E_N=0
E_REL=()
E_EXISTED=()
E_DIGEST=()
E_BLOB=()
E_CONTENT=()
case "$F_BASELINE_TYPE" in
  null) ;;
  object)
    i=0
    while [ "$i" -lt "$F_E_N" ]; do
      _plain "${F_E_REL[i]}" || malformed baseline
      rel="$PLAIN"
      [ "${F_E_VTYPE[i]}" = object ] || malformed "baseline[\"$rel\"]"
      _rel_ok "$rel" || malformed "baseline[\"$rel\"]"
      case "${F_E_EXISTED[i]}" in
        true) E_EXISTED[i]=1 ;;
        false) E_EXISTED[i]=0 ;;
        *) malformed "baseline[\"$rel\"].existed" ;;
      esac
      if [ "${E_EXISTED[i]}" -eq 1 ]; then
        _plain "${F_E_DIGEST[i]}" || malformed "baseline[\"$rel\"].digest"
        [ -n "$PLAIN" ] || malformed "baseline[\"$rel\"].digest"
        E_DIGEST[i]="$PLAIN"
      else
        E_DIGEST[i]=""
      fi
      if [ "${F_E_BLOB[i]}" = null ]; then
        E_BLOB[i]=""
      else
        _plain "${F_E_BLOB[i]}" || malformed "baseline[\"$rel\"].blob"
        _hex64 "$PLAIN" || malformed "baseline[\"$rel\"].blob"
        E_BLOB[i]="$PLAIN"
      fi
      E_CONTENT[i]="${F_E_CONTENT[i]}"
      E_REL[i]="$rel"
      i=$((i + 1))
    done
    E_N="$F_E_N"
    ;;
  *) malformed baseline ;;
esac

# ---------------------------------------------------------------- rollback

# A restore lands by rename, so a symlink an install left behind cannot redirect the write
# outside the work target.
_restore() { # <index> <rel> <abs>
  local i="$1" rel="$2" abs="$3" parent tmp blob
  parent="${abs%/*}"
  if [ -d "$abs" ] && [ ! -L "$abs" ]; then
    return 0
  fi
  [ -d "$parent" ] || mkdir -p "$parent" 2>/dev/null || return 0
  tmp="$abs.ns-restore.$$"
  blob="${E_BLOB[i]}"
  if [ -n "$blob" ] && [ -f "$STORE/$blob" ]; then
    cat "$STORE/$blob" >"$tmp" 2>/dev/null || {
      rm -f "$tmp"
      return 0
    }
  elif [ "${E_CONTENT[i]}" = 1 ]; then
    _content_bytes "$rel" >"$tmp" 2>/dev/null || {
      rm -f "$tmp"
      return 0
    }
    [ -s "$tmp" ] || {
      rm -f "$tmp"
      return 0
    }
  else
    # Neither source survives. Leave what is on disk for the owner to read; the proof
    # reports the mismatch rather than replacing their file with an empty one.
    return 0
  fi
  if [ -L "$abs" ]; then
    rm -f "$abs" 2>/dev/null || true
  fi
  mv "$tmp" "$abs" 2>/dev/null || rm -f "$tmp"
}

# Prune up to, and never including, the work target.
_prune() { # <directory>
  local parent="$1"
  while [ "$parent" != "$TARGET" ]; do
    case "$parent" in
      "$TARGET"/*) ;;
      *) return 0 ;;
    esac
    rmdir "$parent" 2>/dev/null || return 0
    parent="${parent%/*}"
  done
}

_remove() { # <abs>
  if [ -L "$1" ] || [ -f "$1" ]; then
    rm -f "$1" 2>/dev/null || true
  fi
  _prune "${1%/*}"
}

PROOF_DETAIL=""

# The restore is worth nothing unless it is checked. Entries are proven in sorted order, so
# the first mismatch this reports is the same one every host reports.
_prove() {
  local i=0 rel abs got
  while [ "$i" -lt "$E_N" ]; do
    rel="${E_REL[i]}"
    abs="$TARGET/$rel"
    if [ "${E_EXISTED[i]}" -eq 1 ]; then
      if [ -d "$abs" ] && [ ! -L "$abs" ]; then
        PROOF_DETAIL="a directory blocks the baseline path: $rel"
        return 1
      fi
      if [ ! -f "$abs" ]; then
        PROOF_DETAIL="baseline file missing after restore: $rel"
        return 1
      fi
      got="$(ns_policy_sha256_text <"$abs")" || {
        PROOF_DETAIL="no sha256 tool on this host, so the restore cannot be proven"
        return 1
      }
      if [ "$got" != "${E_DIGEST[i]}" ]; then
        PROOF_DETAIL="restored bytes do not match baseline digest: $rel"
        return 1
      fi
    elif [ -e "$abs" ] || [ -L "$abs" ]; then
      PROOF_DETAIL="created path still present: $rel"
      return 1
    fi
    i=$((i + 1))
  done
}

# Both tools are checked before anything is written: a host that cannot restore or cannot
# digest must leave the owner's tree exactly as it found it.
_tools_ready() {
  local i=0 existed=0 content=0
  while [ "$i" -lt "$E_N" ]; do
    if [ "${E_EXISTED[i]}" -eq 1 ]; then
      existed=1
      if [ -z "${E_BLOB[i]}" ] || [ ! -f "$STORE/${E_BLOB[i]}" ]; then
        if [ "${E_CONTENT[i]}" = 1 ]; then
          content=1
        fi
      fi
    fi
    i=$((i + 1))
  done
  if [ "$existed" -eq 1 ]; then
    printf '' | ns_policy_sha256_text >/dev/null 2>&1 ||
      unproven 'no sha256 tool on this host, so the restore cannot be proven'
  fi
  if [ "$content" -eq 1 ] && [ "$(ns_policy_json_tool)" = jq ]; then
    b64_kind >/dev/null ||
      unproven 'no base64 decoder on this host, so the baseline content cannot be restored'
  fi
}

do_rollback() {
  local i=0 rel abs
  _tools_ready
  while [ "$i" -lt "$E_N" ]; do
    rel="${E_REL[i]}"
    abs="$TARGET/$rel"
    if [ "${E_EXISTED[i]}" -eq 1 ]; then
      _restore "$i" "$rel" "$abs"
    else
      _remove "$abs"
    fi
    i=$((i + 1))
  done
  _prove || unproven "$PROOF_DETAIL"
  rm -rf "$STORE" || die "cannot remove $STORE" 1
  rm -f "$TX" || die "cannot remove $TX" 1
  printf '{"capabilityId":"%s","ok":true,"proven":true,"rolledBack":true,"touched":%s}\n' \
    "$CAP" "$(_touched_json)"
  exit 0
}

# ---------------------------------------------------------------- late stages

RECIPE=""
R_ALLOWED=()
R_ALLOWED_N=0
SETUP=""
PATHS=()
PATHS_N=0

# The recipe was valid when apply captured the baseline. Recovery re-reads only what the two
# remaining stages need, and requires it to still name this capability.
_read_recipe() {
  local facts i=0
  facts="$(_facts "$RECIPE")" || return 1
  _parse_facts "$facts"
  [ "$F_TYPE" = object ] || return 1
  _plain "$F_CAP" || return 1
  [ "$PLAIN" = "$CAP" ] || return 1
  [ "$F_ALLOWED_TYPE" = array ] || return 1
  while [ "$i" -lt "$F_ALLOWED_N" ]; do
    _plain "${F_P[i]}" || return 1
    R_ALLOWED[i]="${PLAIN#./}"
    i=$((i + 1))
  done
  R_ALLOWED_N="$F_ALLOWED_N"
  [ "$R_ALLOWED_N" -gt 0 ]
}

_under_allowed() { # <rel>
  local rel="$1" i=0 a
  while [ "$i" -lt "$R_ALLOWED_N" ]; do
    a="${R_ALLOWED[i]%/}"
    if [ "$rel" = "$a" ]; then
      return 0
    fi
    case "$rel" in "$a"/*) return 0 ;; esac
    i=$((i + 1))
  done
  return 1
}

_inventory_base() {
  local out
  if [ -f "$INV" ] && [ ! -L "$INV" ]; then
    if out="$(ns_policy_canon_json "$INV" 2>/dev/null)"; then
      case "$out" in
        '{'*)
          printf '%s' "$out"
          return 0
          ;;
      esac
    fi
    printf '%s' '{"items":[]}'
    return 0
  fi
  printf '%s' '{"schemaVersion":1,"source":"default","items":[],"updatedAt":null,"tickProof":false}'
}

_write_inventory() { # <setupCommit>
  local setup="$1" now base out tool
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  base="$(_inventory_base)"
  tool="$(ns_policy_json_tool)" || return 1
  if [ "$tool" = jq ]; then
    out="$(jq -aS --indent 2 -n --arg cap "$CAP" --arg now "$now" --arg setup "$setup" \
      --argjson base "$base" --slurpfile recipe "$RECIPE" "$INVENTORY_JQ")" || return 1
  else
    out="$(python3 -c "$INVENTORY_PY" "$RECIPE" "$now" "$CAP" "$setup" "$base")" || return 1
  fi
  printf '%s\n' "$out" >"$INV.tmp" || return 1
  mv "$INV.tmp" "$INV" || {
    rm -f "$INV.tmp"
    return 1
  }
}

_advance_stage() {
  local now out tool
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  tool="$(ns_policy_json_tool)" || return 1
  if [ "$tool" = jq ]; then
    out="$(jq -aS --indent 2 --arg now "$now" \
      '.stage = "commit-tooling" | .updatedAt = $now' "$TX")" || return 1
  else
    out="$(python3 -c "$STAGE_PY" "$TX" "$now")" || return 1
  fi
  printf '%s\n' "$out" >"$TX.tmp" || return 1
  mv "$TX.tmp" "$TX" || {
    rm -f "$TX.tmp"
    return 1
  }
}

_commit_tooling() {
  local i=0 rel
  SETUP=""
  PATHS=()
  PATHS_N=0
  [ "$(git -C "$TARGET" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 0
  while [ "$i" -lt "$TOUCHED_N" ]; do
    rel="${TOUCHED[i]}"
    if _under_allowed "$rel"; then
      PATHS[PATHS_N]="$rel"
      PATHS_N=$((PATHS_N + 1))
    fi
    i=$((i + 1))
  done
  [ "$PATHS_N" -gt 0 ] || return 0
  i=0
  while [ "$i" -lt "$PATHS_N" ]; do
    git -C "$TARGET" add -- "${PATHS[i]}" >/dev/null 2>&1 || true
    i=$((i + 1))
  done
  if git -C "$TARGET" commit -m "chore(tooling): $CAP" -- "${PATHS[@]}" >/dev/null 2>&1; then
    SETUP="$(git -C "$TARGET" rev-parse HEAD 2>/dev/null)" || SETUP=""
    return 0
  fi
  # Nothing to commit is a finished commit stage, not a failure.
  [ -z "$(git -C "$TARGET" status --porcelain -- "${PATHS[@]}" 2>/dev/null)" ]
}

do_finish() {
  if [ "$F_RECIPE" = null ]; then
    do_rollback
  fi
  _plain "$F_RECIPE" || do_rollback
  RECIPE="$PLAIN"
  case "$RECIPE" in /*) ;; *) do_rollback ;; esac
  [ -f "$RECIPE" ] || do_rollback
  _read_recipe || do_rollback
  if [ "$STAGE" = record ]; then
    _write_inventory '' || do_rollback
    _advance_stage || do_rollback
  fi
  _commit_tooling || do_rollback
  if [ -n "$SETUP" ]; then
    _write_inventory "$SETUP" || do_rollback
  fi
  rm -rf "$STORE" || die "cannot remove $STORE" 1
  rm -f "$TX" || die "cannot remove $TX" 1
  printf '{"capabilityId":"%s","finished":true,"ok":true,"recovered":true,"setupCommit":"%s","touched":%s}\n' \
    "$CAP" "$SETUP" "$(_touched_json)"
  exit 0
}

# ---------------------------------------------------------------- diagnosis

# Read-only twin of the proof: can the recorded baseline still be restored from what is on
# disk? Digests the stored bytes rather than the tree, and writes nothing.
_diagnose_provable() {
  local i=0 rel abs got
  while [ "$i" -lt "$E_N" ]; do
    rel="${E_REL[i]}"
    abs="$TARGET/$rel"
    if [ "${E_EXISTED[i]}" -eq 1 ]; then
      if [ -d "$abs" ] && [ ! -L "$abs" ]; then
        return 1
      fi
      if [ -n "${E_BLOB[i]}" ] && [ -f "$STORE/${E_BLOB[i]}" ]; then
        got="$(ns_policy_sha256_text <"$STORE/${E_BLOB[i]}")" || return 1
      elif [ "${E_CONTENT[i]}" = 1 ]; then
        got="$(_content_bytes "$rel" | ns_policy_sha256_text)" || return 1
      else
        return 1
      fi
      [ "$got" = "${E_DIGEST[i]}" ] || return 1
    elif [ -d "$abs" ] && [ ! -L "$abs" ]; then
      return 1
    fi
    i=$((i + 1))
  done
}

do_diagnose() {
  local state=provable
  _diagnose_provable || state=unprovable
  printf '%s%sprovision transaction stage=%s capability=%s baseline=%s\n' \
    "$state" "$TAB" "$STAGE" "$CAP" "$state"
  exit 0
}

# ---------------------------------------------------------------- settle it

case "$MODE" in
  diagnose) do_diagnose ;;
  rollback) do_rollback ;;
esac

if [ "$FAILED" -eq 0 ]; then
  case "$STAGE" in
    record | commit-tooling) do_finish ;;
  esac
fi
do_rollback
