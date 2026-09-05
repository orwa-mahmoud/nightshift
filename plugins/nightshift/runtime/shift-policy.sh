#!/usr/bin/env bash
# shift-policy.sh — read and write the three policy files, and print the one resolved view.
#
#   shift-policy.sh --project DIR get
#   shift-policy.sh --project DIR set --from-json FILE|-
#   shift-policy.sh --project DIR defaults-get
#   shift-policy.sh --project DIR defaults-set [--verificationProfile fast|balanced|strict|custom]
#                                             [--hours N|null] [--execution review-first|run-direct]
#                                             [--toolingPolicy existing-tools|review-missing|auto-add]
#
# defaults-get and defaults-set read and write the shift block of rules.json, which is where a
# remembered choice lives. A workspace that still carries the older shift-defaults.json is read
# from it until `migrate` moves it, so upgrading loses nothing.
#
#   shift-policy.sh --project DIR resolve [--json|--table]
#   shift-policy.sh --project DIR migrate [--dry-run]
#   shift-policy.sh --project DIR archive
#
# migrate moves the remembered composition choices out of shift-defaults.json into the shift block
# of rules.json, the one file the owner edits. It refuses an armed workspace, validates the whole
# destination before replacing anything, keeps a lossless backup of what it read, and does nothing
# the second time. Two explicit values that disagree are the owner's to settle: it names both and
# changes neither. --dry-run prints the same report and writes nothing.
#
# Writes only .nightshift/shift-policy.json, .nightshift/shift-defaults.json, and the dated
# archive directory the clock-out gate files the snapshot into. Both writes are refused while the
# shift is armed: composition writes before arming, and hardhat guards the files after.
# Exit: 0 ok · 1 usage · 2 contract failure, naming the field · 3 nothing to read or archive
#       · 4 refused while armed
set -u

_here="${BASH_SOURCE[0]%/*}"
[ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0" >&2
  exit 1
}

die() {
  printf 'shift-policy: %s\n' "$1" >&2
  exit "$2"
}

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
CMD=""
FROM=""
FORMAT=json
SET_PROFILE=""
SET_HOURS=""
SET_TOOLING=""
SET_EXECUTION=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || usage
      PROJECT="$2"
      shift 2
      ;;
    --from-json)
      [ $# -ge 2 ] || usage
      FROM="$2"
      shift 2
      ;;
    --json)
      FORMAT=json
      shift
      ;;
    --table)
      FORMAT=table
      shift
      ;;
    --verificationProfile)
      [ $# -ge 2 ] || usage
      SET_PROFILE="$2"
      shift 2
      ;;
    --hours)
      [ $# -ge 2 ] || usage
      SET_HOURS="$2"
      shift 2
      ;;
    --toolingPolicy)
      [ $# -ge 2 ] || usage
      SET_TOOLING="$2"
      shift 2
      ;;
    --execution)
      [ $# -ge 2 ] || usage
      SET_EXECUTION="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    get | set | defaults-get | defaults-set | resolve | migrate | archive)
      [ -z "$CMD" ] || usage
      CMD="$1"
      shift
      ;;
    *)
      printf 'shift-policy: unknown argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done
[ -n "$CMD" ] || usage

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || die "cannot cd to $PROJECT" 1
WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" ||
    die 'invalid .nightshift-link — Nightshift will not guess a workspace' 2
fi
NS="$WORKSPACE/.nightshift"
POLICY="$NS/shift-policy.json"
DEFAULTS="$NS/shift-defaults.json"
RULES="$NS/rules.json"

# The snapshot is where tonight's deadline, verification level and elevation allowances live.
# A host with no jq and no python3 still reads and writes it through the bounded reader; only a
# host with no awk either has nothing left to read it with.
ns_policy_json_tool >/dev/null || ns_rules_awk_bin >/dev/null ||
  die 'no JSON reader on this host: install jq, python3, or awk' 2

# Every write lands by rename, so a reader never sees half a policy.
atomic_write() { # <destination> — content on stdin
  local dest="$1" tmp
  tmp="$dest.tmp.$$"
  cat >"$tmp" || {
    rm -f "$tmp"
    die "cannot write $dest" 2
  }
  mv "$tmp" "$dest" || {
    rm -f "$tmp"
    die "cannot write $dest" 2
  }
}

refuse_while_armed() {
  [ -e "$NS/.shift-armed" ] || [ -L "$NS/.shift-armed" ] || return 0
  die 'refuse to write the shift policy while the shift is armed — park the need' 4
}

now_utc() {
  if [ -n "${NIGHTSHIFT_POLICY_NOW:-}" ]; then
    printf '%s' "$NIGHTSHIFT_POLICY_NOW"
    return 0
  fi
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

cmd_get() {
  local out rc
  out="$(ns_policy_read_shift "$WORKSPACE")"
  rc=$?
  case "$rc" in
    0)
      printf '%s\n' "$out"
      exit 0
      ;;
    3)
      printf '{}\n'
      exit 3
      ;;
    4) die 'JSON parser unavailable; composition writes shift-policy.json and Start already has rules.json' 2 ;;
    *) die "invalid shift-policy.json: $out" 2 ;;
  esac
}

cmd_set() {
  local tmpd candidate out rc observed scope provenance
  [ -n "$FROM" ] || usage
  [ -d "$NS" ] || die "no .nightshift/ at $WORKSPACE — run setup first" 2
  refuse_while_armed
  tmpd="$(mktemp -d)" || die 'cannot create a temporary directory' 2
  candidate="$tmpd/candidate.json"
  if [ "$FROM" = - ]; then
    cat >"$candidate"
  else
    [ -f "$FROM" ] || {
      rm -rf "$tmpd"
      die "no such file: $FROM" 1
    }
    cat "$FROM" >"$candidate"
  fi
  out="$(ns_policy_validate_shift_file "$candidate")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf "$tmpd"
    case "$rc" in
      3) die 'the policy to write is empty' 2 ;;
      4) die 'JSON parser unavailable; composition writes shift-policy.json and Start already has rules.json' 2 ;;
      *) die "invalid shift-policy.json: $out" 2 ;;
    esac
  fi
  # Record what this session is actually running under, so a revival can reproduce it instead of
  # guessing. It grants nothing — it is a note of what the shift already had — and a candidate
  # that states it already is left exactly as the owner wrote it.
  if ! printf '%s' "$(cat "$candidate")" | grep -q '"launchScope"'; then
    observed="$(ns_launch_observed "$(ns_policy_host_name)")"
    scope="${observed%%	*}"
    provenance="${observed#*	}"
    ns_rules_set_block "$candidate" launchScope "\"$scope\"" >"$tmpd/with-scope.json" &&
      ns_rules_set_block "$tmpd/with-scope.json" launchProvenance "\"$provenance\"" \
        >"$tmpd/with-launch.json" &&
      mv "$tmpd/with-launch.json" "$candidate" || :
  fi
  ns_policy_pretty_text <"$candidate" >"$tmpd/pretty.json" || {
    rm -rf "$tmpd"
    die 'cannot render the policy' 2
  }
  atomic_write "$POLICY" <"$tmpd/pretty.json"
  rm -rf "$tmpd"
  printf '%s\n' "$POLICY"
  exit 0
}

cmd_defaults_get() {
  ns_policy_read_defaults "$WORKSPACE" || :
  exit 0
}

cmd_defaults_set() {
  [ -d "$NS" ] || die "no .nightshift/ at $WORKSPACE — run setup first" 2
  refuse_while_armed
  ns_policy_read_defaults "$WORKSPACE" >/dev/null || :
  if [ -n "$SET_PROFILE" ]; then
    case "$SET_PROFILE" in
      fast | balanced | strict | custom) NS_POLICY_DEF_PROFILE="\"$SET_PROFILE\"" ;;
      *) die 'verificationProfile must be fast, balanced, strict, or custom' 2 ;;
    esac
  fi
  if [ -n "$SET_HOURS" ]; then
    case "$SET_HOURS" in
      null) NS_POLICY_DEF_HOURS=null ;;
      '' | *[!0-9]*) die 'hours must be a whole number of hours or null' 2 ;;
      *) NS_POLICY_DEF_HOURS="$SET_HOURS" ;;
    esac
  fi
  if [ -n "$SET_TOOLING" ]; then
    case "$SET_TOOLING" in
      existing-tools | review-missing | auto-add) NS_POLICY_DEF_TOOLING="\"$SET_TOOLING\"" ;;
      *) die 'toolingPolicy must be existing-tools, review-missing, or auto-add' 2 ;;
    esac
  fi
  if [ -n "$SET_EXECUTION" ]; then
    case "$SET_EXECUTION" in
      review-first | run-direct) NS_POLICY_DEF_EXECUTION="\"$SET_EXECUTION\"" ;;
      *) die 'execution must be review-first or run-direct' 2 ;;
    esac
  fi
  # These live in the shift block of the owner file, which is the one place a preference is
  # kept. Writing them anywhere else would leave the value that is read and the value that was
  # set in two files that can disagree.
  [ -f "$RULES" ] || die "no owner rules file at $RULES — run setup first" 2
  local tmpd block
  block="$(printf '{"verificationProfile":%s,"hours":%s,"execution":%s,"toolingPolicy":%s}' \
    "$NS_POLICY_DEF_PROFILE" "$NS_POLICY_DEF_HOURS" \
    "$NS_POLICY_DEF_EXECUTION" "$NS_POLICY_DEF_TOOLING")"
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/nightshift-defaults.XXXXXX")" ||
    die 'no writable temporary directory' 2
  ns_rules_set_block "$RULES" shift "$block" >"$tmpd/next.json" || {
    rm -rf "$tmpd"
    die 'cannot write the shift block' 2
  }
  ns_rules_load "$tmpd/next.json" >/dev/null 2>&1 || {
    rm -rf "$tmpd"
    die 'the updated owner file would not load' 2
  }
  atomic_write "$RULES" <"$tmpd/next.json"
  rm -rf "$tmpd"
  printf '%s\n' "$RULES"
  exit 0
}

cmd_resolve() {
  if [ "$FORMAT" = table ]; then
    ns_policy_resolve_table "$WORKSPACE" || die 'JSON parser unavailable; composition writes shift-policy.json and Start already has rules.json' 2
  else
    ns_policy_resolve "$WORKSPACE" || die 'JSON parser unavailable; composition writes shift-policy.json and Start already has rules.json' 2
  fi
  exit 0
}

cmd_archive() {
  local out rc shift_id dated dest
  out="$(ns_policy_read_shift "$WORKSPACE")"
  rc=$?
  case "$rc" in
    0) ;;
    3) die 'no shift-policy.json to archive' 3 ;;
    4) die 'JSON parser unavailable; composition writes shift-policy.json and Start already has rules.json' 2 ;;
    *) die "invalid shift-policy.json: $out" 2 ;;
  esac
  shift_id="$(ns_policy_shift_id "$WORKSPACE")" || die 'shift-policy.json carries no shiftId' 2
  # The owner chooses where and how a shift is filed; the shift id names the file either way.
  dated="$(ns_archive_dir "$WORKSPACE" "$(date '+%Y-%m-%d')" "$shift_id")" ||
    die 'archive.root must name a directory inside .nightshift/' 2
  mkdir -p "$dated" || die "cannot create $dated" 2
  dest="$dated/shift-policy-$shift_id.json"
  mv "$POLICY" "$dest" || die "cannot archive $POLICY" 2
  printf '%s\n' "$dest"
  exit 0
}


# _mig_check <field> <compact-json> — status 0 when that value is one the field takes. The
# bounded reader answers about shape; this answers about the value, which is what a migration
# must know before it carries one forward.
_mig_check() {
  case "$1" in
    verificationProfile)
      case "$2" in
        '"fast"' | '"balanced"' | '"strict"' | '"custom"') return 0 ;;
        *) die "shift.verificationProfile: must be fast, balanced, strict, or custom" 2 ;;
      esac
      ;;
    execution)
      case "$2" in
        '"review-first"' | '"run-direct"') return 0 ;;
        *) die "shift.execution: must be review-first or run-direct" 2 ;;
      esac
      ;;
    toolingPolicy)
      case "$2" in
        '"existing-tools"' | '"review-missing"' | '"auto-add"') return 0 ;;
        *) die "shift.toolingPolicy: must be existing-tools, review-missing, or auto-add" 2 ;;
      esac
      ;;
    hours)
      case "$2" in
        null) return 0 ;;
        '' | *[!0-9]*) die "shift.hours: must be a whole number of hours or null" 2 ;;
        *) return 0 ;;
      esac
      ;;
  esac
  return 0
}

# The four remembered choices, named once so the reader, the writer and the conflict report
# cannot disagree about the list. schemaVersion and updatedAt are bookkeeping and stay behind.
MIGRATE_FIELDS="verificationProfile hours execution toolingPolicy"

# _mig_canonical <field> — what the owner file already states, as compact JSON, or nothing.
_mig_canonical() {
  local v
  v="$(ns_rules_get_in "$RULES" shift "$1")"
  [ -n "$v" ] || return 1
  case "$v" in
    null | true | false) printf '%s' "$v" ;;
    '' | *[!0-9]*) printf '"%s"' "$v" ;;
    *) printf '%s' "$v" ;;
  esac
}

cmd_migrate() {
  local field legacy canonical conflicts="" block="" first=1 value tmpd why

  [ -f "$RULES" ] || die "no owner rules file at $RULES — run setup first" 3

  # An armed shift keeps the contract it started under; changing it underneath the running agent
  # would leave the shift and its policy describing different nights.
  if [ -e "$NS/.shift-armed" ] || [ -L "$NS/.shift-armed" ]; then
    die 'refuse to migrate while the shift is armed — stop the shift, migrate, then start again' 4
  fi

  # The destination is read before anything is computed from it, so a file that does not load is
  # named rather than half-migrated.
  why="$(ns_rules_check "$WORKSPACE" 2>&1)" || die "$RULES is not readable: $why" 2

  for field in $MIGRATE_FIELDS; do
    legacy="$(ns_policy_defaults_stated "$WORKSPACE" "$field")" || legacy=""
    canonical="$(_mig_canonical "$field")" || canonical=""
    value=""
    [ -z "$canonical" ] || _mig_check "$field" "$canonical"
    [ -z "$legacy" ] || _mig_check "$field" "$legacy"
    if [ -n "$canonical" ] && [ -n "$legacy" ] && [ "$canonical" != "$legacy" ]; then
      conflicts="$conflicts  shift.$field: this file says $canonical, the legacy file says $legacy
"
      continue
    fi
    [ -n "$canonical" ] && value="$canonical"
    [ -n "$value" ] || value="$legacy"
    [ -n "$value" ] || continue
    [ "$first" -eq 1 ] || block="$block,"
    first=0
    block="$block\"$field\":$value"
  done

  if [ -n "$conflicts" ]; then
    printf 'refused: two explicit values disagree, and nothing here decides between them\n' >&2
    printf '%s' "$conflicts" >&2
    printf 'keep one value, delete the other from %s, then run migrate again\n' "$DEFAULTS" >&2
    return 2
  fi


  if [ ! -f "$DEFAULTS" ] && [ -n "$(ns_rules_get "$RULES" shift)" ]; then
    printf 'no-op: every remembered choice already lives in %s\n' "$RULES"
    return 0
  fi

  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/nightshift-migrate.XXXXXX")" ||
    die 'no writable temporary directory' 2
  ns_rules_set_block "$RULES" shift "{$block}" >"$tmpd/next.json" || {
    rm -rf "$tmpd"
    die 'cannot compose the migrated file' 2
  }
  # The complete destination must load before it replaces one that already does.
  why="$(ns_rules_load "$tmpd/next.json" 2>&1)" || {
    rm -rf "$tmpd"
    die "the migrated file would not load: $why" 2
  }

  _mig_report "$block"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'dry run: nothing was written\n'
    rm -rf "$tmpd"
    return 0
  fi

  if [ -f "$DEFAULTS" ]; then
    cp "$DEFAULTS" "$DEFAULTS.bak" || {
      rm -rf "$tmpd"
      die 'cannot keep a backup of the legacy file' 2
    }
  fi
  atomic_write "$RULES" <"$tmpd/next.json"
  rm -rf "$tmpd"
  rm -f "$DEFAULTS"
  printf '%s\n' "$RULES"
}

# _mig_report <block> — what the shift block will hold, in the owner's terms.
_mig_report() {
  printf 'migrating into %s:\n' "$RULES"
  printf '  shift = %s\n' "{$1}"
}

case "$CMD" in
  get) cmd_get ;;
  set) cmd_set ;;
  defaults-get) cmd_defaults_get ;;
  defaults-set) cmd_defaults_set ;;
  resolve) cmd_resolve ;;
  migrate) cmd_migrate ;;
  archive) cmd_archive ;;
esac
