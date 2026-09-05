#!/usr/bin/env bash
# Shift policy — the one resolver.
#
# Three files, three jobs. rules.json holds the permanent project boundaries. shift-defaults.json
# holds remembered convenience choices that only prefill the one question a composition step asks;
# it is never the source of an effective value. shift-policy.json is tonight's authoritative
# snapshot, written before the gate is armed and archived at clock-out. Everything that needs a
# policy answer — hardhat, Start, Doctor, Status, the support bundle, both host adapters — reads
# ns_policy_resolve, so no two of them can render a different result.
#
# rules.json is read by the shipped subset reader — no jq or python3. jq (preferred) or python3
# still turns shift-policy.json and shift-defaults.json into a flat, tab-separated fact stream.
# Every decision — validation, precedence, defaults, allowance matching — happens in bash. Raw
# payloads are control-scrubbed before they enter the stream, so a fact line always carries
# exactly one fact, and a scalar's compact JSON is self-describing in its first byte. The
# resolved view reports the files: a session NIGHTSHIFT_* override is one guard's test lever, not
# policy, and never appears as a source.

NS_POLICY_NL='
'
NS_POLICY_TAB=$(printf '\t')

# The jq half sits next to this file, resolved without dirname so a hostile PATH cannot reach it.
NS_POLICY_EMIT_JQ="${BASH_SOURCE[0]%/*}"
[ "$NS_POLICY_EMIT_JQ" != "${BASH_SOURCE[0]}" ] || NS_POLICY_EMIT_JQ=.
NS_POLICY_EMIT_JQ="$NS_POLICY_EMIT_JQ/policy-emit.jq"

NS_POLICY_CATEGORIES="sudo
containers
global-packages
daemons
external-services"

NS_POLICY_SHIFT_FIELDS="schemaVersion
shiftId
createdAt
source
deadlineEpoch
verificationLevel
toolingPolicy
budgets
completionMode
selectedDebt
allowances
gatesDigest"

NS_POLICY_RULES_STATE=""
NS_POLICY_RULES_VALS=""
NS_POLICY_RULES_ELEV=""
NS_POLICY_RULES_PAT=""
NS_POLICY_SHIFT_STATE=""
NS_POLICY_SHIFT_ERR=""
NS_POLICY_SHIFT_ID=""
NS_POLICY_SHIFT_TYPES=""
NS_POLICY_SHIFT_KEYS=""
NS_POLICY_SHIFT_VALS=""
NS_POLICY_SHIFT_COUNTS=""
NS_POLICY_SHIFT_BUDGETS=""
NS_POLICY_SHIFT_DEBT=""
NS_POLICY_SHIFT_CMDS=""
NS_POLICY_SHIFT_CMDJSON=""
NS_POLICY_SHIFT_SURFACE=""
NS_POLICY_SHIFT_ALLOW=""
NS_POLICY_SHIFT_PLAN=""
NS_POLICY_SHIFT_PLANIDX=""
NS_POLICY_V=""
NS_POLICY_S=""
NS_POLICY_E=""
NS_POLICY_DEF_PROFILE=""
NS_POLICY_DEF_HOURS=""
NS_POLICY_DEF_TOOLING=""
NS_POLICY_DEF_EXECUTION=""
NS_POLICY_DEF_UPDATED=""
NS_PF1=""
NS_PF2=""
NS_PF3=""
NS_PF4=""
NS_PF5=""

# ns_policy_default_pattern <category> — the shipped grep -E for a category, and the list of
# categories that exist. The rules template carries this text byte for byte so the owner can see
# and edit it; this is what applies when the file does not, or when a file predates the elevation
# object. The elevation guard and the permission preflight both come here, so they cannot
# disagree, and a workspace answers the same with or without a JSON parser on PATH.
#
# Elevation gates creating system state, not reading it: a verb-scoped pattern denies `docker run`
# and `brew install` while `docker ps` and `brew list` stay ordinary work. The leading alternation
# admits a path prefix and one layer of quoting, so `/usr/bin/sudo` and an `sh -c` payload land in
# the same category as the bare command.
ns_policy_default_pattern() {
  case "$1" in
    sudo)
      printf '%s' '(^|[;&|(`]|[[:space:]]|'\''|")(/[A-Za-z0-9._-]+)*/*(sudo|d[o]as)([[:space:]]|[;&|)'\''"`]|$)'
      ;;
    containers)
      printf '%s' '(/var/run/docker\.sock|unix://[^ \t]*docker\.sock|DOCKER_HOST=)|(^|[;&|(`]|[[:space:]]|'\''|")(docker-compose)[[:space:]]+(up|run|start|build|down|create)|(^|[;&|(`]|[[:space:]]|'\''|")(docker|podman|nerdctl|colima)[[:space:]]+(run|create|start|build|compose[[:space:]]+(up|run|start|build|down|create))'
      ;;
    global-packages)
      printf '%s' '(^|[;&|(`]|[[:space:]]|'\''|")(brew|apt|apt-get|dnf|yum|pacman|choco|winget|scoop)[[:space:]]+(install|upgrade|uninstall|remove|reinstall)|npm[[:space:]]+(i|install)[[:space:]]+(-g|--global)|pnpm[[:space:]]+add[[:space:]]+-g|yarn[[:space:]]+global|(pip3?|cargo|go)[[:space:]]+install'
      ;;
    daemons)
      printf '%s' '(^|[;&|(`]|[[:space:]]|'\''|")(systemctl|launchctl|service|brew[[:space:]]+services|pg_ctl|redis-server|mongod|mysqld)([[:space:]]|$)'
      ;;
    external-services)
      printf '%s' '(^|[;&|(`]|[[:space:]]|'\''|")(gh[[:space:]]+auth[[:space:]]+login|npm[[:space:]]+login|docker[[:space:]]+login|az[[:space:]]+login|gcloud[[:space:]]+auth|aws[[:space:]]+configure)([[:space:]]|$)'
      ;;
    *) return 1 ;;
  esac
}

# ns_policy_builtin <setting> — the lowest-precedence value, as compact JSON. Nothing decides
# from a constant the resolved view does not print. verificationLevel is the shipped
# fast profile: no gate cadence unless the owner or a profile sets one.
ns_policy_builtin() {
  case "$1" in
    verificationLevel) printf '"none"' ;;
    toolingPolicy) printf '"existing-tools"' ;;
    deadlineEpoch) printf 'null' ;;
    elevation.*) printf '"deny"' ;;
    forbiddenCommands | protectedDirs | neverCommitPatterns | expectedEmail) printf '""' ;;
    stallMax) printf '0' ;;
    watchMinutes) printf '10' ;;
    *) return 1 ;;
  esac
}

# ns_policy_settings — every effective setting name, one per line, in byte order.
ns_policy_settings() {
  local c
  {
    printf 'deadlineEpoch\nexpectedEmail\nforbiddenCommands\nneverCommitPatterns\n'
    printf 'protectedDirs\nstallMax\ntoolingPolicy\nverificationLevel\nwatchMinutes\n'
    printf '%s\n' "$NS_POLICY_CATEGORIES" | while IFS= read -r c; do
      [ -n "$c" ] || continue
      printf 'elevation.%s\n' "$c"
    done
  } | LC_ALL=C sort
}

# _ns_pf_split <line> — a tab-separated fact line into NS_PF1..NS_PF5. Split by parameter
# expansion, never by read: tab is IFS whitespace, so read would collapse an empty field away.
_ns_pf_split() {
  local rest="$1"
  NS_PF1=""
  NS_PF2=""
  NS_PF3=""
  NS_PF4=""
  NS_PF5=""
  NS_PF1="${rest%%"$NS_POLICY_TAB"*}"
  case "$rest" in *"$NS_POLICY_TAB"*) rest="${rest#*"$NS_POLICY_TAB"}" ;; *) return 0 ;; esac
  NS_PF2="${rest%%"$NS_POLICY_TAB"*}"
  case "$rest" in *"$NS_POLICY_TAB"*) rest="${rest#*"$NS_POLICY_TAB"}" ;; *) return 0 ;; esac
  NS_PF3="${rest%%"$NS_POLICY_TAB"*}"
  case "$rest" in *"$NS_POLICY_TAB"*) rest="${rest#*"$NS_POLICY_TAB"}" ;; *) return 0 ;; esac
  NS_PF4="${rest%%"$NS_POLICY_TAB"*}"
  case "$rest" in *"$NS_POLICY_TAB"*) rest="${rest#*"$NS_POLICY_TAB"}" ;; *) return 0 ;; esac
  NS_PF5="$rest"
}

# _ns_policy_pick <list> <key> — the remainder of the first "key<TAB>rest" line, or status 1.
_ns_policy_pick() {
  local rest="$1" line
  while [ -n "$rest" ]; do
    line="${rest%%"$NS_POLICY_NL"*}"
    case "$rest" in *"$NS_POLICY_NL"*) rest="${rest#*"$NS_POLICY_NL"}" ;; *) rest="" ;; esac
    case "$line" in
      "$2$NS_POLICY_TAB"*)
        printf '%s' "${line#*"$NS_POLICY_TAB"}"
        return 0
        ;;
    esac
  done
  return 1
}

# _ns_policy_has <list> <exact-line> — exact membership in a newline-terminated list.
_ns_policy_has() {
  case "$NS_POLICY_NL$1" in
    *"$NS_POLICY_NL$2$NS_POLICY_NL"*) return 0 ;;
  esac
  return 1
}

# _ns_json_uint <compact-json> — status 0 when the text is a non-negative whole number.
_ns_json_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# _ns_json_hex <compact-json> <length> — status 0 for a JSON string of exactly that many
# lowercase hex characters.
_ns_json_hex() {
  local s="$1"
  case "$s" in
    '"'*'"') ;;
    *) return 1 ;;
  esac
  s="${s#\"}"
  s="${s%\"}"
  case "$s" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#s}" -eq "$2" ]
}

# ns_policy_json_tool — jq, else python3, else status 2. One place decides, so every caller
# reports the same prerequisite.
ns_policy_json_tool() {
  if command -v jq >/dev/null 2>&1; then
    printf 'jq'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf 'python3'
    return 0
  fi
  return 2
}

# ns_policy_normalize_command <text> — the normal form both halves of an exact-plan allowance
# agree on: every run of whitespace becomes one space, and the ends are trimmed.
ns_policy_normalize_command() {
  printf '%s' "$1" | tr '\t\n\v\f\r' '     ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# ns_policy_json_string <text> — the text as a JSON string, in this backend's own escaping. The
# preimage it goes into is canonicalized before it is digested, so both backends agree there.
ns_policy_json_string() {
  local tool
  tool="$(ns_policy_json_tool)" || return 1
  if [ "$tool" = jq ]; then
    printf '%s' "$1" | jq -Rs . 2>/dev/null || return 1
  else
    printf '%s' "$1" | python3 -c 'import json, sys
sys.stdout.write(json.dumps(sys.stdin.read(), ensure_ascii=False))' 2>/dev/null || return 1
  fi
}

# ns_policy_sha256_text — lowercase hex digest of stdin. Status 1 when the host has no digest
# tool, which fails an exact-plan match closed rather than waving it through.
ns_policy_sha256_text() {
  local line
  if command -v sha256sum >/dev/null 2>&1; then
    line="$(sha256sum)" || return 1
    printf '%s' "${line%% *}"
  elif command -v shasum >/dev/null 2>&1; then
    line="$(shasum -a 256)" || return 1
    printf '%s' "${line%% *}"
  elif command -v openssl >/dev/null 2>&1; then
    line="$(openssl dgst -sha256)" || return 1
    printf '%s' "${line##* }"
  else
    return 1
  fi
}


NS_POLICY_SHIFT_PY='
import json, re, sys

SCALARS = ["schemaVersion", "shiftId", "createdAt", "source", "deadlineEpoch",
           "verificationLevel", "toolingPolicy", "completionMode", "gatesDigest"]
out = []


def enc(v):
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def scrub(s):
    return re.sub(r"[\x00-\x1f\x7f]", " ", s)


def norm(s):
    return re.sub(r"[ \t\n\x0b\f\r]+", " ", s).strip(" ")


def kind(v):
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
    if isinstance(v, dict):
        return "object"
    return "invalid"


def obj(v):
    return v if isinstance(v, dict) else {}


def arr(v):
    return v if isinstance(v, list) else []


def jn(p, k):
    return k if p == "." else p + "." + k


def ty(p, v):
    out.append("ty\t%s\t%s" % (p, kind(v)))


def ks(p, v):
    if isinstance(v, dict):
        for k in v:
            out.append("k\t%s\t%s" % (p, scrub(k)))


def sc(p, v, names):
    for k in names:
        out.append("j\t%s\t%s" % (jn(p, k), enc(obj(v).get(k))))


def cnt(p, v):
    out.append("n\t%s\t%s" % (p, len(v) if isinstance(v, list) else -1))


try:
    P = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(P, dict):
    sys.stdout.write("x\t.\tnotobject\n")
    sys.exit(0)
ks(".", P)
sc(".", P, SCALARS)
ty("budgets", P.get("budgets"))
for key, value in obj(P.get("budgets")).items():
    out.append("b\t%s\t%s" % (scrub(key), enc(value)))
ty("selectedDebt", P.get("selectedDebt"))
cnt("selectedDebt", P.get("selectedDebt"))
for i, one in enumerate(arr(P.get("selectedDebt"))):
    out.append("s\t%d\t%s\t%s" % (i, "s" if isinstance(one, str) else "x", enc(one)))
ty("allowances", P.get("allowances"))
cnt("allowances", P.get("allowances"))
for i, a in enumerate(arr(P.get("allowances"))):
    ap = "allowances[%d]" % i
    ty(ap, a)
    ks(ap, a)
    sc(ap, a, ["category", "scope", "provenance"])
    plan = obj(a).get("plan")
    ty(jn(ap, "plan"), plan)
    ks(jn(ap, "plan"), obj(plan))
    sc(jn(ap, "plan"), obj(plan), ["workTarget", "digest", "expiry"])
    cs = obj(plan).get("commands")
    ty(jn(ap, "plan.commands"), cs)
    cnt(jn(ap, "plan.commands"), cs)
    for n, one in enumerate(arr(cs)):
        ok = isinstance(one, str)
        out.append("c\t%d\t%d\t%s\t%s" % (i, n, "s" if ok else "x", norm(one) if ok else ""))
        out.append("q\t%d\t%d\t%s" % (i, n, enc(norm(one)) if ok else "null"))
    ws = obj(plan).get("writeSurface")
    ty(jn(ap, "plan.writeSurface"), ws)
    for n, one in enumerate(arr(ws)):
        out.append("w\t%d\t%d\t%s" % (i, n, "s" if isinstance(one, str) else "x"))
sys.stdout.write("".join(line + "\n" for line in out))
'


NS_POLICY_DEFAULTS_PY='
import json, sys

K = ["schemaVersion", "verificationProfile", "hours", "toolingPolicy", "execution", "updatedAt"]
try:
    D = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(D, dict):
    sys.stdout.write("x\t.\tnotobject\n")
    sys.exit(0)
sys.stdout.write("".join(
    "d\t%s\t%s\t%s\n" % (k, "1" if k in D else "0",
                         json.dumps(D.get(k), ensure_ascii=False, separators=(",", ":")))
    for k in K))
'

# _ns_policy_facts <operation> <python-program> <file> — the fact stream on stdout.
# Status 1 when the file is not JSON, 2 when no parser is installed.
_ns_policy_facts() {
  local tool win bin mode
  tool="$(ns_policy_json_tool)" || {
    # The snapshot carries what the owner chose for tonight — a deadline, a verification
    # level, an elevation allowance. None of that may quietly stop applying because a host
    # has no jq and no python3, so the bounded reader emits the same fact stream.
    case "$1" in
      shift) mode=policy ;;
      defaults) mode=defaults ;;
      *) return 2 ;;
    esac
    bin="$(ns_rules_awk_bin)" || return 2
    "$bin" -v mode="$mode" -f "$_NS_RULES_AWK_FILE" <"$3" 2>/dev/null || return 1
    return 0
  }
  # Bash opens the document. jq -f still needs a path the jq binary can open:
  # Git's jq wants /d/..., native jq.exe wants D:\...
  if [ "$tool" = jq ]; then
    jq -r --arg op "$1" -f "$NS_POLICY_EMIT_JQ" <"$3" 2>/dev/null && return 0
    win="$(ns_native_display_path "$NS_POLICY_EMIT_JQ")"
    jq -r --arg op "$1" -f "$win" <"$3" 2>/dev/null || return 1
    return 0
  fi
  python3 -c "$2" "$3" 2>/dev/null && return 0
  python3 -c "$2" "$(ns_native_display_path "$3")" 2>/dev/null || return 1
}

# _ns_policy_awk_json <mode> [file] — the bounded reader as the third engine behind the two
# canonical writers. LC_ALL=C so the reader sees bytes, which is what its UTF-8 escaping needs.
_ns_policy_awk_json() {
  local bin mode="$1"
  bin="$(ns_rules_awk_bin)" || return 2
  shift
  if [ "$#" -ge 1 ]; then
    LC_ALL=C "$bin" -v mode="$mode" -f "$_NS_RULES_AWK_FILE" <"$1" 2>/dev/null || return 1
  else
    LC_ALL=C "$bin" -v mode="$mode" -f "$_NS_RULES_AWK_FILE" 2>/dev/null || return 1
  fi
}

# ns_policy_canon_json <file> — the document as compact canonical JSON: sorted keys, \uXXXX
# escaping. The one wire form the bash and PowerShell resolvers both emit.
ns_policy_canon_json() {
  local tool
  tool="$(ns_policy_json_tool)" || {
    _ns_policy_awk_json canon "$1"
    return $?
  }
  if [ "$tool" = jq ]; then
    jq -caS . <"$1" 2>/dev/null || return 1
  else
    python3 -c 'import json, sys
sys.stdout.write(json.dumps(json.load(sys.stdin), sort_keys=True, separators=(",", ":")) + "\n")' \
      <"$1" 2>/dev/null || return 1
  fi
}

# ns_policy_canon_text — compact canonical JSON of the document on stdin.
ns_policy_canon_text() {
  local tool
  tool="$(ns_policy_json_tool)" || {
    _ns_policy_awk_json canon
    return $?
  }
  if [ "$tool" = jq ]; then
    jq -caS . 2>/dev/null || return 1
  else
    python3 -c 'import json, sys
sys.stdout.write(json.dumps(json.load(sys.stdin), sort_keys=True, separators=(",", ":")) + "\n")' \
      2>/dev/null || return 1
  fi
}

# ns_policy_pretty_text — sorted, indented JSON of the document on stdin, for a file the owner
# opens and edits by hand.
ns_policy_pretty_text() {
  local tool
  tool="$(ns_policy_json_tool)" || {
    _ns_policy_awk_json pretty
    return $?
  }
  if [ "$tool" = jq ]; then
    jq -S . 2>/dev/null || return 1
  else
    python3 -c 'import json, sys
sys.stdout.write(json.dumps(json.load(sys.stdin), sort_keys=True, indent=2) + "\n")' \
      2>/dev/null || return 1
  fi
}

# ---------------------------------------------------------------- rules.json

_ns_policy_load_rules() {
  local ws="$1" f facts line rc
  NS_POLICY_RULES_STATE=""
  NS_POLICY_RULES_VALS=""
  NS_POLICY_RULES_ELEV=""
  NS_POLICY_RULES_PAT=""
  f="$ws/.nightshift/rules.json"
  if [ ! -f "$f" ]; then
    NS_POLICY_RULES_STATE=absent
    return 0
  fi
  facts="$(ns_rules_facts "$f")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    NS_POLICY_RULES_STATE=malformed
    return 0
  fi
  NS_POLICY_RULES_STATE=ok
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _ns_pf_split "$line"
    case "$NS_PF1" in
      r) NS_POLICY_RULES_VALS="$NS_POLICY_RULES_VALS$NS_PF2$NS_POLICY_TAB$NS_PF3$NS_POLICY_TAB$NS_PF4$NS_POLICY_NL" ;;
      e) NS_POLICY_RULES_ELEV="$NS_POLICY_RULES_ELEV$NS_PF2$NS_POLICY_TAB$NS_PF3$NS_POLICY_TAB$NS_PF4$NS_POLICY_NL" ;;
      p) NS_POLICY_RULES_PAT="$NS_POLICY_RULES_PAT$NS_PF2$NS_POLICY_TAB$NS_PF3$NS_POLICY_NL" ;;
    esac
  done <<EOF
$facts
EOF
}

# _ns_policy_pattern_of <category> — the one place a category's pattern is chosen. The rules must
# already be loaded. Both accessors come through here, so they cannot answer differently.
_ns_policy_pattern_of() {
  local pat
  if [ "$NS_POLICY_RULES_STATE" = ok ]; then
    pat="$(_ns_policy_pick "$NS_POLICY_RULES_PAT" "$1")" || pat=""
    if [ -n "$pat" ]; then
      printf '%s' "$pat"
      return 0
    fi
  fi
  ns_policy_default_pattern "$1"
}

# ns_policy_elevation_pattern <workspace> <category>
# The grep -E the guard and the preflight both match against: the owner's pattern when rules.json
# carries one, the shipped pattern otherwise. Status 1 on an unknown category.
# An unreadable rules file falls back to the shipped pattern; an owner pattern that grep -E will
# not accept comes back verbatim, because whether an invalid pattern denies or warns is the
# caller's decision, not this accessor's.
ns_policy_elevation_pattern() {
  ns_policy_default_pattern "$2" >/dev/null || return 1
  _ns_policy_load_rules "$1"
  _ns_policy_pattern_of "$2"
}

# ns_policy_elevation_patterns <workspace>
# Every category's pattern from ONE parse of the rules: `category<TAB>pattern`, one line each, in
# the fixed category order. A guard that has to test all five categories per command reads this
# instead of asking five times. Patterns are control-scrubbed as they are read, so a line never
# carries a tab or a newline of its own and the split is unambiguous.
ns_policy_elevation_patterns() {
  local category
  _ns_policy_load_rules "$1"
  while IFS= read -r category; do
    [ -n "$category" ] || continue
    printf '%s%s' "$category" "$NS_POLICY_TAB"
    _ns_policy_pattern_of "$category" || return 1
    printf '\n'
  done <<EOF
$NS_POLICY_CATEGORIES
EOF
}

# ---------------------------------------------------------------- shift-policy.json

# _ns_policy_shift_fail <field> <reason> — the first violation, named, and validation stops.
_ns_policy_shift_fail() {
  NS_POLICY_SHIFT_STATE=malformed
  NS_POLICY_SHIFT_ERR="$1 $2"
}

# _ns_policy_keys_ok <path> <allowed-list> — every key at that path is one of the allowed names.
_ns_policy_keys_ok() {
  local path="$1" allowed="$2" rest line key
  rest="$NS_POLICY_SHIFT_KEYS"
  while [ -n "$rest" ]; do
    line="${rest%%"$NS_POLICY_NL"*}"
    case "$rest" in *"$NS_POLICY_NL"*) rest="${rest#*"$NS_POLICY_NL"}" ;; *) rest="" ;; esac
    case "$line" in
      "$path$NS_POLICY_TAB"*)
        key="${line#*"$NS_POLICY_TAB"}"
        _ns_policy_has "$allowed$NS_POLICY_NL" "$key" || {
          NS_POLICY_SHIFT_ERR="$key"
          return 1
        }
        ;;
    esac
  done
  return 0
}

_ns_policy_check_plan() {
  local i="$1" ap="$2" rest line count seen
  _ns_policy_keys_ok "$ap.plan" "commands
workTarget
digest
writeSurface
expiry" || {
    _ns_policy_shift_fail "$ap.plan" "has an unknown field: $NS_POLICY_SHIFT_ERR"
    return 1
  }
  case "$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" "$ap.plan.workTarget")" in
    '""' | '"'*'"') ;;
    *)
      _ns_policy_shift_fail "$ap.plan.workTarget" "must be the resolved work target path"
      return 1
      ;;
  esac
  case "$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" "$ap.plan.workTarget")" in
    '""')
      _ns_policy_shift_fail "$ap.plan.workTarget" "must be the resolved work target path"
      return 1
      ;;
  esac
  _ns_json_hex "$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" "$ap.plan.digest")" 64 || {
    _ns_policy_shift_fail "$ap.plan.digest" "must be 64 lowercase hex characters"
    return 1
  }
  line="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" "$ap.plan.expiry")"
  if [ "$line" != null ] && ! _ns_json_uint "$line"; then
    _ns_policy_shift_fail "$ap.plan.expiry" "must be a UNIX epoch or null"
    return 1
  fi
  case "$(_ns_policy_pick "$NS_POLICY_SHIFT_TYPES" "$ap.plan.writeSurface")" in
    null | array) ;;
    *)
      _ns_policy_shift_fail "$ap.plan.writeSurface" "must be an array of paths"
      return 1
      ;;
  esac
  rest="$NS_POLICY_SHIFT_SURFACE"
  while [ -n "$rest" ]; do
    line="${rest%%"$NS_POLICY_NL"*}"
    case "$rest" in *"$NS_POLICY_NL"*) rest="${rest#*"$NS_POLICY_NL"}" ;; *) rest="" ;; esac
    _ns_pf_split "$line"
    [ "$NS_PF1" = "$i" ] || continue
    [ "$NS_PF3" = s ] || {
      _ns_policy_shift_fail "$ap.plan.writeSurface" "must be an array of paths"
      return 1
    }
  done
  [ "$(_ns_policy_pick "$NS_POLICY_SHIFT_TYPES" "$ap.plan.commands")" = array ] || {
    _ns_policy_shift_fail "$ap.plan.commands" "must be an array of commands"
    return 1
  }
  count="$(_ns_policy_pick "$NS_POLICY_SHIFT_COUNTS" "$ap.plan.commands")" || count=-1
  case "$count" in '' | *[!0-9]*) count=-1 ;; esac
  [ "$count" -ge 1 ] || {
    _ns_policy_shift_fail "$ap.plan.commands" "must list at least one command"
    return 1
  }
  seen=0
  rest="$NS_POLICY_SHIFT_CMDS"
  while [ -n "$rest" ]; do
    line="${rest%%"$NS_POLICY_NL"*}"
    case "$rest" in *"$NS_POLICY_NL"*) rest="${rest#*"$NS_POLICY_NL"}" ;; *) rest="" ;; esac
    _ns_pf_split "$line"
    [ "$NS_PF1" = "$i" ] || continue
    if [ "$NS_PF3" != s ] || [ -z "$NS_PF4" ]; then
      _ns_policy_shift_fail "$ap.plan.commands" "must hold non-empty command strings"
      return 1
    fi
    seen=$((seen + 1))
  done
  [ "$seen" -eq "$count" ] || {
    _ns_policy_shift_fail "$ap.plan.commands" "must hold non-empty command strings"
    return 1
  }
  return 0
}

_ns_policy_check_allowance() {
  local i="$1" category scope provenance plan
  local ap="allowances[$i]"
  [ "$(_ns_policy_pick "$NS_POLICY_SHIFT_TYPES" "$ap")" = object ] || {
    _ns_policy_shift_fail "$ap" "must be an object"
    return 1
  }
  _ns_policy_keys_ok "$ap" "category
scope
provenance
plan" || {
    _ns_policy_shift_fail "$ap" "has an unknown field: $NS_POLICY_SHIFT_ERR"
    return 1
  }
  category="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" "$ap.category")"
  case "$category" in
    '"sudo"' | '"containers"' | '"global-packages"' | '"daemons"' | '"external-services"') ;;
    *)
      _ns_policy_shift_fail "$ap.category" \
        "must be sudo, containers, global-packages, daemons, or external-services"
      return 1
      ;;
  esac
  category="${category#\"}"
  category="${category%\"}"
  scope="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" "$ap.scope")"
  case "$scope" in
    '"category"' | '"exact-plan"') ;;
    *)
      _ns_policy_shift_fail "$ap.scope" "must be category or exact-plan"
      return 1
      ;;
  esac
  provenance="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" "$ap.provenance")"
  case "$provenance" in
    '"rules"' | '"one-shift"') ;;
    *)
      _ns_policy_shift_fail "$ap.provenance" "must be rules or one-shift"
      return 1
      ;;
  esac
  provenance="${provenance#\"}"
  provenance="${provenance%\"}"
  plan="$(_ns_policy_pick "$NS_POLICY_SHIFT_TYPES" "$ap.plan")"
  if [ "$scope" = '"category"' ]; then
    [ "$plan" = null ] || {
      _ns_policy_shift_fail "$ap.plan" "belongs only to an exact-plan allowance"
      return 1
    }
    NS_POLICY_SHIFT_ALLOW="$NS_POLICY_SHIFT_ALLOW$category$NS_POLICY_TAB$provenance$NS_POLICY_NL"
    return 0
  fi
  [ "$plan" = object ] || {
    _ns_policy_shift_fail "$ap.plan" "is required by an exact-plan allowance"
    return 1
  }
  _ns_policy_check_plan "$i" "$ap" || return 1
  NS_POLICY_SHIFT_PLAN="$NS_POLICY_SHIFT_PLAN$category$NS_POLICY_TAB$provenance$NS_POLICY_NL"
  NS_POLICY_SHIFT_PLANIDX="$NS_POLICY_SHIFT_PLANIDX$category$NS_POLICY_TAB$i$NS_POLICY_NL"
  return 0
}

_ns_policy_validate_shift() {
  local rest line key val count i
  _ns_policy_keys_ok . "$NS_POLICY_SHIFT_FIELDS" || {
    _ns_policy_shift_fail "$NS_POLICY_SHIFT_ERR" "is not a shift-policy field"
    return 1
  }
  for key in schemaVersion shiftId createdAt source verificationLevel toolingPolicy; do
    _ns_policy_has "$NS_POLICY_SHIFT_KEYS" ".$NS_POLICY_TAB$key" || {
      _ns_policy_shift_fail "$key" "is missing"
      return 1
    }
  done
  [ "$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" schemaVersion)" = 1 ] || {
    _ns_policy_shift_fail schemaVersion "must be 1"
    return 1
  }
  val="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" shiftId)"
  case "$val" in
    '"'*'"')
      val="${val#\"}"
      val="${val%\"}"
      ;;
    *) val="" ;;
  esac
  case "$val" in *[!0-9a-f-]*) val="" ;; esac
  case "${#val}" in
    16 | 36) ;;
    *)
      _ns_policy_shift_fail shiftId "must be 16 lowercase hex characters or a UUID"
      return 1
      ;;
  esac
  NS_POLICY_SHIFT_ID="$val"
  case "$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" createdAt)" in
    '""' | '"'*'"') ;;
    *)
      _ns_policy_shift_fail createdAt "must be a UTC timestamp"
      return 1
      ;;
  esac
  [ "$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" createdAt)" != '""' ] || {
    _ns_policy_shift_fail createdAt "must be a UTC timestamp"
    return 1
  }
  case "$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" source)" in
    '"composition"' | '"start-defaults"') ;;
    *)
      _ns_policy_shift_fail source "must be composition or start-defaults"
      return 1
      ;;
  esac
  case "$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" verificationLevel)" in
    '"none"' | '"final"' | '"per-item"' | '"custom"') ;;
    *)
      _ns_policy_shift_fail verificationLevel "must be none, final, per-item, or custom"
      return 1
      ;;
  esac
  case "$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" toolingPolicy)" in
    '"existing-tools"' | '"review-missing"' | '"auto-add"') ;;
    *)
      _ns_policy_shift_fail toolingPolicy "must be existing-tools, review-missing, or auto-add"
      return 1
      ;;
  esac
  val="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" deadlineEpoch)"
  if [ "$val" != null ] && ! _ns_json_uint "$val"; then
    _ns_policy_shift_fail deadlineEpoch "must be a UNIX epoch or null"
    return 1
  fi
  val="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" gatesDigest)"
  if [ "$val" != null ] && [ "$val" != '""' ] && ! _ns_json_hex "$val" 64; then
    _ns_policy_shift_fail gatesDigest "must be 64 lowercase hex characters"
    return 1
  fi
  case "$(_ns_policy_pick "$NS_POLICY_SHIFT_TYPES" budgets)" in
    null | object) ;;
    *)
      _ns_policy_shift_fail budgets "must be an object of whole numbers"
      return 1
      ;;
  esac
  rest="$NS_POLICY_SHIFT_BUDGETS"
  while [ -n "$rest" ]; do
    line="${rest%%"$NS_POLICY_NL"*}"
    case "$rest" in *"$NS_POLICY_NL"*) rest="${rest#*"$NS_POLICY_NL"}" ;; *) rest="" ;; esac
    [ -n "$line" ] || continue
    _ns_pf_split "$line"
    case "$NS_PF1" in
      '' | *[!A-Za-z0-9_-]*)
        _ns_policy_shift_fail budgets "has an unusable name: $NS_PF1"
        return 1
        ;;
    esac
    _ns_json_uint "$NS_PF2" || {
      _ns_policy_shift_fail "budgets.$NS_PF1" "must be a whole number"
      return 1
    }
  done
  case "$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" completionMode)" in
    null | '"clear-all"' | '"no-regression-plus-selected-debt"') ;;
    *)
      _ns_policy_shift_fail completionMode \
        "must be clear-all or no-regression-plus-selected-debt"
      return 1
      ;;
  esac
  case "$(_ns_policy_pick "$NS_POLICY_SHIFT_TYPES" selectedDebt)" in
    null | array) ;;
    *)
      _ns_policy_shift_fail selectedDebt "must be an array of finding ids"
      return 1
      ;;
  esac
  rest="$NS_POLICY_SHIFT_DEBT"
  while [ -n "$rest" ]; do
    line="${rest%%"$NS_POLICY_NL"*}"
    case "$rest" in *"$NS_POLICY_NL"*) rest="${rest#*"$NS_POLICY_NL"}" ;; *) rest="" ;; esac
    [ -n "$line" ] || continue
    _ns_pf_split "$line"
    if [ "$NS_PF2" != s ] || [ "$NS_PF3" = '""' ]; then
      _ns_policy_shift_fail "selectedDebt[$NS_PF1]" "must be a finding id"
      return 1
    fi
  done
  case "$(_ns_policy_pick "$NS_POLICY_SHIFT_TYPES" allowances)" in
    null | array) ;;
    *)
      _ns_policy_shift_fail allowances "must be an array of allowances"
      return 1
      ;;
  esac
  count="$(_ns_policy_pick "$NS_POLICY_SHIFT_COUNTS" allowances)" || count=0
  case "$count" in '' | -* | *[!0-9]*) count=0 ;; esac
  i=0
  while [ "$i" -lt "$count" ]; do
    _ns_policy_check_allowance "$i" || return 1
    i=$((i + 1))
  done
  return 0
}

_ns_policy_load_shift_file() {
  local f="$1" facts line rc
  NS_POLICY_SHIFT_STATE=""
  NS_POLICY_SHIFT_ERR=""
  NS_POLICY_SHIFT_ID=""
  NS_POLICY_SHIFT_TYPES=""
  NS_POLICY_SHIFT_KEYS=""
  NS_POLICY_SHIFT_VALS=""
  NS_POLICY_SHIFT_COUNTS=""
  NS_POLICY_SHIFT_BUDGETS=""
  NS_POLICY_SHIFT_DEBT=""
  NS_POLICY_SHIFT_CMDS=""
  NS_POLICY_SHIFT_CMDJSON=""
  NS_POLICY_SHIFT_SURFACE=""
  NS_POLICY_SHIFT_ALLOW=""
  NS_POLICY_SHIFT_PLAN=""
  NS_POLICY_SHIFT_PLANIDX=""
  if [ ! -f "$f" ]; then
    NS_POLICY_SHIFT_STATE=absent
    return 0
  fi
  facts="$(_ns_policy_facts shift "$NS_POLICY_SHIFT_PY" "$f")"
  rc=$?
  facts="$(printf '%s' "$facts" | tr -d '\r')"
  if [ "$rc" -eq 2 ]; then
    NS_POLICY_SHIFT_STATE=noparser
    NS_POLICY_SHIFT_ERR="JSON parser unavailable; composition writes shift-policy.json and Start already has rules.json"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    NS_POLICY_SHIFT_STATE=malformed
    NS_POLICY_SHIFT_ERR="the document is not JSON"
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _ns_pf_split "$line"
    case "$NS_PF1" in
      x)
        NS_POLICY_SHIFT_STATE=malformed
        NS_POLICY_SHIFT_ERR="the document is not a JSON object"
        return 0
        ;;
      ty) NS_POLICY_SHIFT_TYPES="$NS_POLICY_SHIFT_TYPES$NS_PF2$NS_POLICY_TAB$NS_PF3$NS_POLICY_NL" ;;
      k) NS_POLICY_SHIFT_KEYS="$NS_POLICY_SHIFT_KEYS$NS_PF2$NS_POLICY_TAB$NS_PF3$NS_POLICY_NL" ;;
      j) NS_POLICY_SHIFT_VALS="$NS_POLICY_SHIFT_VALS$NS_PF2$NS_POLICY_TAB$NS_PF3$NS_POLICY_NL" ;;
      n) NS_POLICY_SHIFT_COUNTS="$NS_POLICY_SHIFT_COUNTS$NS_PF2$NS_POLICY_TAB$NS_PF3$NS_POLICY_NL" ;;
      b) NS_POLICY_SHIFT_BUDGETS="$NS_POLICY_SHIFT_BUDGETS$NS_PF2$NS_POLICY_TAB$NS_PF3$NS_POLICY_NL" ;;
      s) NS_POLICY_SHIFT_DEBT="$NS_POLICY_SHIFT_DEBT$NS_PF2$NS_POLICY_TAB$NS_PF3$NS_POLICY_TAB$NS_PF4$NS_POLICY_NL" ;;
      c) NS_POLICY_SHIFT_CMDS="$NS_POLICY_SHIFT_CMDS$NS_PF2$NS_POLICY_TAB$NS_PF3$NS_POLICY_TAB$NS_PF4$NS_POLICY_TAB$NS_PF5$NS_POLICY_NL" ;;
      q) NS_POLICY_SHIFT_CMDJSON="$NS_POLICY_SHIFT_CMDJSON$NS_PF2$NS_POLICY_TAB$NS_PF3$NS_POLICY_TAB$NS_PF4$NS_POLICY_NL" ;;
      w) NS_POLICY_SHIFT_SURFACE="$NS_POLICY_SHIFT_SURFACE$NS_PF2$NS_POLICY_TAB$NS_PF3$NS_POLICY_TAB$NS_PF4$NS_POLICY_NL" ;;
    esac
  done <<EOF
$facts
EOF
  NS_POLICY_SHIFT_STATE=ok
  _ns_policy_validate_shift || :
  return 0
}

_ns_policy_load_shift() {
  _ns_policy_load_shift_file "$1/.nightshift/shift-policy.json"
}

# ns_policy_validate_shift_file <file>
# Status 0 the document is a valid shift policy · 2 prints one diagnostic naming the offending
# field · 3 the file is absent · 4 no JSON parser is installed. Composition validates a candidate
# before it becomes tonight's policy; Doctor validates the file already on disk.
ns_policy_validate_shift_file() {
  _ns_policy_load_shift_file "$1"
  case "$NS_POLICY_SHIFT_STATE" in
    absent) return 3 ;;
    noparser) return 4 ;;
    malformed)
      printf '%s\n' "$NS_POLICY_SHIFT_ERR"
      return 2
      ;;
  esac
  return 0
}

# ns_policy_read_shift <workspace>
# Status 0 prints the policy as compact canonical JSON · 2 prints one diagnostic naming the
# offending field · 3 the file is absent · 4 no JSON parser is installed.
ns_policy_read_shift() {
  _ns_policy_load_shift "$1"
  case "$NS_POLICY_SHIFT_STATE" in
    absent) return 3 ;;
    noparser) return 4 ;;
    malformed)
      printf '%s\n' "$NS_POLICY_SHIFT_ERR"
      return 2
      ;;
  esac
  ns_policy_canon_json "$1/.nightshift/shift-policy.json" || return 2
}

# ns_policy_deadline_epoch <workspace>
# The shift policy's quitting time. Status 1 when the policy carries none: the .nightshift/deadline
# file is a projection of this value, never a second authority.
ns_policy_deadline_epoch() {
  local val
  _ns_policy_load_shift "$1"
  [ "$NS_POLICY_SHIFT_STATE" = ok ] || return 1
  val="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" deadlineEpoch)" || return 1
  _ns_json_uint "$val" || return 1
  printf '%s' "$val"
}

# ns_policy_shift_id <workspace> — the identity this shift's allowances are bound to.
ns_policy_shift_id() {
  _ns_policy_load_shift "$1"
  [ "$NS_POLICY_SHIFT_STATE" = ok ] || return 1
  [ -n "$NS_POLICY_SHIFT_ID" ] || return 1
  printf '%s' "$NS_POLICY_SHIFT_ID"
}

# ns_policy_completion_mode <workspace>
# How the evidence comparison scores tonight: clear-all, or no-regression-plus-selected-debt.
# An absent, unreadable or silent policy is clear-all — the strict mode is the floor, and a
# broken file never widens it. The mode is not a resolved setting: it scores findings, it grants
# nothing, so the resolved view does not report it.
ns_policy_completion_mode() {
  local val
  _ns_policy_load_shift "$1"
  if [ "$NS_POLICY_SHIFT_STATE" = ok ]; then
    val="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" completionMode)" || val=null
    if [ "$val" = '"no-regression-plus-selected-debt"' ]; then
      printf 'no-regression-plus-selected-debt'
      return 0
    fi
  fi
  printf 'clear-all'
}

# ns_policy_selected_debt <workspace>
# The finding ids the owner accepted as tonight's debt, one compact JSON string per line, in the
# order the policy lists them. A JSON string carries no raw newline, so the list stays line-safe
# and a caller matches an id without unescaping it. Empty when the policy names none.
ns_policy_selected_debt() {
  local rest line
  _ns_policy_load_shift "$1"
  [ "$NS_POLICY_SHIFT_STATE" = ok ] || return 0
  rest="$NS_POLICY_SHIFT_DEBT"
  while [ -n "$rest" ]; do
    line="${rest%%"$NS_POLICY_NL"*}"
    case "$rest" in *"$NS_POLICY_NL"*) rest="${rest#*"$NS_POLICY_NL"}" ;; *) rest="" ;; esac
    [ -n "$line" ] || continue
    _ns_pf_split "$line"
    [ "$NS_PF2" = s ] || continue
    printf '%s\n' "$NS_PF3"
  done
}

# ---------------------------------------------------------------- shift-defaults.json

# ns_policy_read_defaults <workspace>
# The effective remembered choices as compact canonical JSON. Status 0 when the file is absent or
# valid, 1 when it is malformed — either way the built-in defaults are printed, because these
# choices only prefill a question and must never decide anything.
ns_policy_read_defaults() {
  local ws="$1" f facts line rc bad=0
  local profile='"fast"' hours=null tooling='"existing-tools"'
  local execution='"review-first"' updated=null
  f="$ws/.nightshift/shift-defaults.json"
  if [ -f "$f" ]; then
    facts="$(_ns_policy_facts defaults "$NS_POLICY_DEFAULTS_PY" "$f")"
    rc=$?
    facts="$(printf '%s' "$facts" | tr -d '\r')"
    if [ "$rc" -ne 0 ]; then
      bad=1
    else
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        _ns_pf_split "$line"
        [ "$NS_PF1" = d ] || bad=1
        [ "$NS_PF3" = 1 ] || continue
        case "$NS_PF2" in
          schemaVersion) [ "$NS_PF4" = 1 ] || bad=1 ;;
          verificationProfile)
            case "$NS_PF4" in
              '"fast"' | '"balanced"' | '"strict"' | '"custom"') profile="$NS_PF4" ;;
              *) bad=1 ;;
            esac
            ;;
          hours)
            if [ "$NS_PF4" = null ]; then
              hours=null
            elif _ns_json_uint "$NS_PF4"; then
              hours="$NS_PF4"
            else
              bad=1
            fi
            ;;
          toolingPolicy)
            case "$NS_PF4" in
              '"existing-tools"' | '"review-missing"' | '"auto-add"') tooling="$NS_PF4" ;;
              *) bad=1 ;;
            esac
            ;;
          execution)
            case "$NS_PF4" in
              '"review-first"' | '"run-direct"') execution="$NS_PF4" ;;
              *) bad=1 ;;
            esac
            ;;
          updatedAt)
            case "$NS_PF4" in
              '"'*'"') updated="$NS_PF4" ;;
              *) bad=1 ;;
            esac
            ;;
        esac
      done <<EOF
$facts
EOF
    fi
  fi
  if [ "$bad" -ne 0 ]; then
    profile='"fast"'
    hours=null
    tooling='"existing-tools"'
    execution='"review-first"'
    updated=null
  fi
  NS_POLICY_DEF_PROFILE="$profile"
  NS_POLICY_DEF_HOURS="$hours"
  NS_POLICY_DEF_TOOLING="$tooling"
  NS_POLICY_DEF_EXECUTION="$execution"
  NS_POLICY_DEF_UPDATED="$updated"
  ns_policy_defaults_json || return 2
  [ "$bad" -eq 0 ]
}

# ns_policy_defaults_stated <workspace> <field> — the value the legacy file explicitly states
# for that field, as compact JSON. Status 1 when the file says nothing about it, which is what
# separates a remembered choice from a built-in default during a migration.
ns_policy_defaults_stated() {
  local f facts line
  f="$1/.nightshift/shift-defaults.json"
  [ -f "$f" ] || return 1
  facts="$(_ns_policy_facts defaults "$NS_POLICY_DEFAULTS_PY" "$f")" || return 1
  facts="$(printf '%s' "$facts" | tr -d '\r')"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _ns_pf_split "$line"
    [ "$NS_PF1" = d ] || continue
    [ "$NS_PF2" = "$2" ] || continue
    [ "$NS_PF3" = 1 ] || return 1
    printf '%s' "$NS_PF4"
    return 0
  done <<EOF
$facts
EOF
  return 1
}

# ns_policy_defaults_json — the NS_POLICY_DEF_* fields as compact canonical JSON.
ns_policy_defaults_json() {
  printf '{"execution":%s,"hours":%s,"schemaVersion":1,"toolingPolicy":%s,"updatedAt":%s,"verificationProfile":%s}\n' \
    "$NS_POLICY_DEF_EXECUTION" "$NS_POLICY_DEF_HOURS" "$NS_POLICY_DEF_TOOLING" \
    "$NS_POLICY_DEF_UPDATED" "$NS_POLICY_DEF_PROFILE" | ns_policy_canon_text
}

# ---------------------------------------------------------------- the resolver

# _ns_policy_setting <name> — the effective value, source, and expiry into NS_POLICY_V/S/E.
_ns_policy_setting() {
  local name="$1" category present val row
  NS_POLICY_V="$(ns_policy_builtin "$name")" || return 1
  NS_POLICY_S=built-in
  NS_POLICY_E='-'
  case "$name" in
    verificationLevel | toolingPolicy | deadlineEpoch)
      if [ "$NS_POLICY_SHIFT_STATE" = ok ]; then
        val="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" "$name")" || val=""
        if [ -n "$val" ]; then
          NS_POLICY_V="$val"
          NS_POLICY_S=one-shift
          NS_POLICY_E='shift'
        fi
      fi
      return 0
      ;;
    elevation.*)
      category="${name#elevation.}"
      row="$(_ns_policy_pick "$NS_POLICY_SHIFT_ALLOW" "$category")" || row=""
      if [ -n "$row" ]; then
        NS_POLICY_V='"allow"'
        NS_POLICY_S="$row"
        if [ "$row" = rules ]; then NS_POLICY_E=permanent; else NS_POLICY_E='shift'; fi
        return 0
      fi
      row="$(_ns_policy_pick "$NS_POLICY_SHIFT_PLAN" "$category")" || row=""
      if [ -n "$row" ]; then
        NS_POLICY_V='"exact-plan"'
        NS_POLICY_S=exact-plan
        NS_POLICY_E='shift'
        return 0
      fi
      [ "$NS_POLICY_RULES_STATE" = ok ] || return 0
      row="$(_ns_policy_pick "$NS_POLICY_RULES_ELEV" "$category")" || return 0
      present="${row%%"$NS_POLICY_TAB"*}"
      [ "$present" = 1 ] || return 0
      val="${row#*"$NS_POLICY_TAB"}"
      NS_POLICY_S=rules
      NS_POLICY_E=permanent
      [ "$val" = allow ] || return 0
      NS_POLICY_V='"allow"'
      return 0
      ;;
  esac
  [ "$NS_POLICY_RULES_STATE" = ok ] || return 0
  row="$(_ns_policy_pick "$NS_POLICY_RULES_VALS" "$name")" || return 0
  present="${row%%"$NS_POLICY_TAB"*}"
  val="${row#*"$NS_POLICY_TAB"}"
  [ "$present" = 1 ] || return 0
  NS_POLICY_V="$val"
  NS_POLICY_S=rules
  NS_POLICY_E=permanent
}

# ns_policy_resolve <workspace>
# The one resolved view, as compact canonical JSON:
#   {"schemaVersion":1,"settings":{"<name>":{"value":…,"source":…,"expiry":…}}}
# Precedence, row by row:
#   1. protected paths, never-commit patterns, the expected commit identity and forbiddenCommands
#      come from rules.json alone; no allowance lifts them.
#   2. an elevation category: a shift-policy allowance (rules or one-shift provenance) beats
#      rules.elevation, which beats the built-in deny. Either allowance alone lifts the deny.
#   3. an exact-plan allowance permits only its listed commands; a category allowance permits the
#      whole category; with both present the category applies.
#   4. shift-defaults.json is never the source of an effective value.
#   6. a malformed shift-policy.json grants nothing: the view is built-in plus rules, and the
#      caller names the field.
# A key the owner wrote is the owner's answer: a setting present in rules.json reports source
# rules and expiry permanent even when its value is an empty string or a zero, and a category
# present under rules.elevation reports rules whichever way its policy points. built-in and `-`
# mean the file says nothing at all.
# Status 2 when the resolved JSON cannot be canonicalized and no fallback table applies.
ns_policy_resolve() {
  local ws="$1" out name first=1
  _ns_policy_load_rules "$ws"
  _ns_policy_load_shift "$ws"
  if [ "$NS_POLICY_SHIFT_STATE" != ok ]; then
    NS_POLICY_SHIFT_ALLOW=""
    NS_POLICY_SHIFT_PLAN=""
    NS_POLICY_SHIFT_PLANIDX=""
  fi
  out='{"schemaVersion":1,"settings":{'
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    _ns_policy_setting "$name" || continue
    [ "$first" -eq 1 ] || out="$out,"
    first=0
    out="$out\"$name\":{\"value\":$NS_POLICY_V,\"source\":\"$NS_POLICY_S\",\"expiry\":\"$NS_POLICY_E\"}"
  done <<EOF
$(ns_policy_settings)
EOF
  out="$out}}"
  printf '%s\n' "$out" | ns_policy_canon_text || return 2
}

# ns_policy_resolve_table <workspace>
# The same resolved view as one line per setting, sorted by name:
#   <name>=<value> (<source>, <expiry>)
# Doctor, Status and the helper all print these lines, so the table can never drift from the JSON.
ns_policy_resolve_table() {
  local ws="$1" name text
  _ns_policy_load_rules "$ws"
  _ns_policy_load_shift "$ws"
  if [ "$NS_POLICY_SHIFT_STATE" != ok ]; then
    NS_POLICY_SHIFT_ALLOW=""
    NS_POLICY_SHIFT_PLAN=""
    NS_POLICY_SHIFT_PLANIDX=""
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    _ns_policy_setting "$name" || continue
    text="$(ns_json_text "$NS_POLICY_V")"
    printf '%s=%s (%s, %s)\n' "$name" "$text" "$NS_POLICY_S" "$NS_POLICY_E"
  done <<EOF
$(ns_policy_settings)
EOF
}

# _ns_policy_plan_lookup <list> <i> <n> — the value recorded for command n of allowance i.
_ns_policy_plan_lookup() {
  local rest="$1" line
  while [ -n "$rest" ]; do
    line="${rest%%"$NS_POLICY_NL"*}"
    case "$rest" in *"$NS_POLICY_NL"*) rest="${rest#*"$NS_POLICY_NL"}" ;; *) rest="" ;; esac
    case "$line" in
      "$2$NS_POLICY_TAB$3$NS_POLICY_TAB"*)
        printf '%s' "${line#*"$NS_POLICY_TAB"*"$NS_POLICY_TAB"}"
        return 0
        ;;
    esac
  done
  return 1
}

# _ns_policy_plan_binds <workspace> <allowance index> <normalized command>
# The five things an exact-plan allowance is bound to, all of which must still hold: the command
# is one the owner listed, the work target is the one the plan was approved against, the shift has
# not run out, the plan's own clock has not run out, and the digest still covers the same
# commands, shift and target. Any drift is a fresh owner decision, not a permission.
# The digest covers the commands, the shift and the target only — an expiry the owner shortens is
# a narrowing of an approval they already signed, not a different approval.
_ns_policy_plan_binds() {
  local ws="$1" i="$2" norm="$3" ap
  local count n found=0 raw enc cmds="" target target_json stored preimage digest
  local deadline expiry now=""
  ap="allowances[$i]"
  count="$(_ns_policy_pick "$NS_POLICY_SHIFT_COUNTS" "$ap.plan.commands")" || return 1
  _ns_json_uint "$count" || return 1
  n=0
  while [ "$n" -lt "$count" ]; do
    raw="$(_ns_policy_plan_lookup "$NS_POLICY_SHIFT_CMDS" "$i" "$n")" || return 1
    raw="${raw#*"$NS_POLICY_TAB"}"
    enc="$(_ns_policy_plan_lookup "$NS_POLICY_SHIFT_CMDJSON" "$i" "$n")" || return 1
    [ "$raw" != "$norm" ] || found=1
    cmds="$cmds${cmds:+,}$enc"
    n=$((n + 1))
  done
  [ "$found" -eq 1 ] || return 1

  target="$(ns_work_target "$ws")" || return 1
  target="$(cd -P "$target" 2>/dev/null && pwd)" || return 1
  target_json="$(ns_policy_json_string "$target")" || return 1
  stored="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" "$ap.plan.workTarget")" || return 1
  [ "$target_json" = "$stored" ] || return 1

  deadline="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" deadlineEpoch)" || deadline=null
  expiry="$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" "$ap.plan.expiry")" || expiry=null
  if [ "$deadline" != null ] || [ "$expiry" != null ]; then
    now="$(date +%s)"
    _ns_json_uint "$now" || return 1
  fi
  if [ "$deadline" != null ]; then
    _ns_json_uint "$deadline" || return 1
    [ "$now" -lt "$deadline" ] || return 1
  fi
  if [ "$expiry" != null ]; then
    _ns_json_uint "$expiry" || return 1
    [ "$now" -le "$expiry" ] || return 1
  fi

  preimage="$(printf '{"commands":[%s],"shiftId":"%s","workTarget":%s}' \
    "$cmds" "$NS_POLICY_SHIFT_ID" "$target_json" | ns_policy_canon_text)" || return 1
  [ -n "$preimage" ] || return 1
  digest="$(printf '%s' "$preimage" | ns_policy_sha256_text)" || return 1
  [ "\"$digest\"" = "$(_ns_policy_pick "$NS_POLICY_SHIFT_VALS" "$ap.plan.digest")" ] || return 1
  return 0
}

# ns_policy_allowed <workspace> <category> <scrubbed-command>
# Status 0 the category is allowed · 1 denied · 2 an exact-plan allowance covers the category but
# this command is not bound by it — the command, the work target, the shift clock, the plan's own
# clock, or the digest has moved. The caller matched the category pattern first; everything the
# plan was approved against is checked here, so no caller can hold half the binding.
ns_policy_allowed() {
  local ws="$1" category="$2" norm rest line
  ns_policy_default_pattern "$category" >/dev/null || return 1
  _ns_policy_load_rules "$ws"
  _ns_policy_load_shift "$ws"
  if [ "$NS_POLICY_SHIFT_STATE" != ok ]; then
    NS_POLICY_SHIFT_ALLOW=""
    NS_POLICY_SHIFT_PLAN=""
    NS_POLICY_SHIFT_PLANIDX=""
  fi
  _ns_policy_setting "elevation.$category" || return 1
  case "$NS_POLICY_V" in
    '"allow"') return 0 ;;
    '"exact-plan"') ;;
    *) return 1 ;;
  esac
  norm="$(ns_policy_normalize_command "${3:-}")"
  [ -n "$norm" ] || return 2
  rest="$NS_POLICY_SHIFT_PLANIDX"
  while [ -n "$rest" ]; do
    line="${rest%%"$NS_POLICY_NL"*}"
    case "$rest" in *"$NS_POLICY_NL"*) rest="${rest#*"$NS_POLICY_NL"}" ;; *) rest="" ;; esac
    _ns_pf_split "$line"
    [ "$NS_PF1" = "$category" ] || continue
    _ns_policy_plan_binds "$ws" "$NS_PF2" "$norm" && return 0
  done
  return 2
}
