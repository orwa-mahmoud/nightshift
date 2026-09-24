#!/usr/bin/env bash
# provision.sh — thin auto-add seatbelt. No recipe engine.
#
#   provision.sh --project DIR baseline --surface PATH [PATH ...]
#   provision.sh --project DIR baseline --surface PATH [--surface PATH ...]
#   provision.sh --project DIR diff
#   provision.sh --project DIR rollback
#   provision.sh --project DIR recover
#
# The skill tells the model to inspect the package manager, choose a compatible tool,
# install, smoke, and record. This helper only captures a write-surface baseline,
# prints the diff, and restores. Refuse symlink or reparse escape. Unknown flags
# do not mutate. A failed tooling commit is the model's job to keep consistent:
# write the inventory row only after git commit succeeds; on failure run rollback
# and leave capabilities.json untouched.
#
# recover of a leftover provision-transaction.json still settles that file.
# Exit: 0 ok · 1 usage/runtime · 2 refused (escape or locked path) · 3 unproven restore
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
  printf 'provision: %s\n' "$1" >&2
  exit "$2"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Locked owner state — never a write surface.
locked_name() {
  case "$1" in
    punch-list.md | parking-lot.md | drafting-table.md | work-orders.md | \
    capability-policy.json | shift-policy.json | shift-defaults.json | rules.json)
      return 0
      ;;
  esac
  return 1
}

# Refuse absolute paths, .., and any symlink whose target leaves the work target.
# Prints the contained relative path on success.
contain_rel() {
  local rel="$1" cur="$TARGET" part dest resolved
  case "$rel" in
    '' | /* | *..*) return 1 ;;
  esac
  case "$rel" in
    . | ./*) rel="${rel#./}" ;;
  esac
  [ -n "$rel" ] || return 1
  locked_name "$rel" && return 1
  case "$rel" in
    .nightshift | .nightshift/* | .git | .git/*) return 1 ;;
  esac
  IFS=/
  # shellcheck disable=SC2086
  set -- $rel
  unset IFS
  for part in "$@"; do
    [ -n "$part" ] || continue
    [ "$part" != . ] || continue
    [ "$part" != .. ] || return 1
    cur="$cur/$part"
    if [ -L "$cur" ]; then
      dest="$(readlink "$cur")" || return 1
      case "$dest" in
        /*)
          resolved="$(cd -P "$(dirname "$cur")" 2>/dev/null && cd -P "$dest" 2>/dev/null && pwd)" || {
            # dangling or file symlink: resolve the parent + dest without following the leaf
            case "$dest" in
              "$TARGET" | "$TARGET"/*) ;;
              *) return 1 ;;
            esac
            continue
          }
          case "$resolved" in
            "$TARGET" | "$TARGET"/*) ;;
            *) return 1 ;;
          esac
          ;;
        *)
          # relative link: walk it against the parent
          if [ -d "$cur" ]; then
            resolved="$(cd -P "$cur" 2>/dev/null && pwd)" || return 1
            case "$resolved" in
              "$TARGET" | "$TARGET"/*) ;;
              *) return 1 ;;
            esac
          fi
          ;;
      esac
    fi
  done
  printf '%s' "$rel"
}

digest_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    return 1
  fi
}

PROJECT=""
VERB=""
SURFACES=()
UNKNOWN=0
taken=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { UNKNOWN=1; break; }
      PROJECT="$2"
      shift 2
      ;;
    --surface)
      # One flag may list several paths, and the flag may also be repeated per path.
      # A bare word is a path unless it is the verb this call has not named yet.
      shift
      taken=0
      while [ $# -gt 0 ]; do
        case "$1" in
          -*) break ;;
          baseline | diff | rollback | recover) [ -n "$VERB" ] || break ;;
        esac
        SURFACES+=("$1")
        taken=$((taken + 1))
        shift
      done
      [ "$taken" -gt 0 ] || { UNKNOWN=1; break; }
      ;;
    baseline | diff | rollback | recover)
      if [ -n "$VERB" ]; then UNKNOWN=1; break; fi
      VERB="$1"
      shift
      ;;
    -h | --help) usage ;;
    *)
      UNKNOWN=1
      break
      ;;
  esac
done

# Unknown flags do not mutate: fail before resolving the tree.
if [ "$UNKNOWN" -eq 1 ] || [ -z "$VERB" ] || [ -z "$PROJECT" ]; then
  usage
fi

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || die "cannot cd to $PROJECT" 1
WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" || WORKSPACE="$HOST"
TARGET="$(ns_work_target "$WORKSPACE" 2>/dev/null)" || TARGET="$WORKSPACE"
NS="$WORKSPACE/.nightshift"
declare BASE MANIFEST TX
ns_layout_set BASE "$NS" provision-baseline
ns_layout_set MANIFEST "$NS" provision-surface
ns_layout_set TX "$NS" provision-transaction

# recover of a leftover engine transaction stays next door.
if [ "$VERB" = recover ] && [ -f "$TX" ] && [ ! -f "$MANIFEST" ]; then
  exec bash "$_here/provision-recover.sh" --project "$PROJECT"
fi
if [ "$VERB" = rollback ] && [ -f "$TX" ] && [ ! -f "$MANIFEST" ]; then
  exec bash "$_here/provision-recover.sh" --project "$PROJECT" --rollback
fi

emit_ok() {
  printf '{"ok":true,"refused":false,"rolledBack":%s,"command":"%s"}\n' \
    "$1" "$VERB"
}

refuse() {
  printf '{"ok":false,"refused":true,"reason":"%s"}\n' "$(json_escape "$1")"
  exit 2
}

do_baseline() {
  [ "${#SURFACES[@]}" -gt 0 ] || die "baseline needs --surface PATH" 1
  mkdir -p "$NS" || die "cannot create $NS" 1
  rm -rf "$BASE"
  mkdir -p "$BASE" || die "cannot create $BASE" 1
  : >"$MANIFEST" || die "cannot write $MANIFEST" 1
  local rel contained path digest existed
  for rel in "${SURFACES[@]}"; do
    contained="$(contain_rel "$rel")" || {
      rm -rf "$BASE" "$MANIFEST"
      refuse "surface-escape:$rel"
    }
    path="$TARGET/$contained"
    existed=0
    digest="-"
    if [ -L "$path" ]; then
      rm -rf "$BASE" "$MANIFEST"
      refuse "surface-symlink:$rel"
    fi
    if [ -f "$path" ]; then
      existed=1
      digest="$(digest_file "$path")" || {
        rm -rf "$BASE" "$MANIFEST"
        die "cannot hash $contained" 1
      }
      cp "$path" "$BASE/$digest" || {
        rm -rf "$BASE" "$MANIFEST"
        die "cannot store baseline blob" 1
      }
    elif [ -e "$path" ]; then
      rm -rf "$BASE" "$MANIFEST"
      refuse "surface-not-file:$rel"
    fi
    printf '%s\t%s\t%s\n' "$contained" "$existed" "$digest" >>"$MANIFEST"
  done
  printf '{"schemaVersion":1,"stage":"baseline","workTarget":"%s"}\n' \
    "$(json_escape "$TARGET")" >"$TX" || die "cannot write transaction" 1
  emit_ok false
}

do_diff() {
  [ -f "$MANIFEST" ] || die "no provision-surface; run baseline first" 1
  local rel existed digest path now first=1
  printf '{"ok":true,"touched":['
  while IFS="$(printf '\t')" read -r rel existed digest; do
    [ -n "$rel" ] || continue
    path="$TARGET/$rel"
    now="absent"
    if [ -L "$path" ]; then
      now="symlink"
    elif [ -f "$path" ]; then
      now="$(digest_file "$path")" || now="unreadable"
    elif [ -e "$path" ]; then
      now="other"
    fi
    if [ "$existed" = 1 ]; then
      [ "$now" = "$digest" ] && continue
    else
      [ "$now" = "absent" ] && continue
    fi
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '"%s"' "$(json_escape "$rel")"
  done <"$MANIFEST"
  printf ']}\n'
}

# Unlink a path without following a symlink, then restore bytes if the file existed.
restore_one() {
  local rel="$1" existed="$2" digest="$3" path="$TARGET/$1"
  if [ -L "$path" ]; then
    rm -f "$path" || return 1
  elif [ -f "$path" ]; then
    rm -f "$path" || return 1
  elif [ -e "$path" ]; then
    return 1
  fi
  if [ "$existed" = 1 ]; then
    [ -f "$BASE/$digest" ] || return 1
    mkdir -p "$(dirname "$path")" || return 1
    cp "$BASE/$digest" "$path" || return 1
  fi
  return 0
}

do_restore() {
  if [ ! -f "$MANIFEST" ]; then
    printf '{"detail":"no transaction","ok":true,"recovered":false}\n'
    exit 0
  fi
  local rel existed digest path
  while IFS="$(printf '\t')" read -r rel existed digest; do
    [ -n "$rel" ] || continue
    case "$rel" in
      '' | /* | *..* | .nightshift | .nightshift/* | .git | .git/*)
        printf '{"ok":false,"proven":false,"rolledBack":false,"reason":"surface-escape"}\n'
        exit 3
        ;;
    esac
    locked_name "$rel" && {
      printf '{"ok":false,"proven":false,"rolledBack":false,"reason":"surface-escape"}\n'
      exit 3
    }
    restore_one "$rel" "$existed" "$digest" || {
      printf '{"ok":false,"proven":false,"rolledBack":false,"reason":"restore-failed"}\n'
      exit 3
    }
    path="$TARGET/$rel"
    if [ "$existed" = 1 ]; then
      [ -f "$path" ] || {
        printf '{"ok":false,"proven":false,"rolledBack":false,"reason":"unproven"}\n'
        exit 3
      }
      [ "$(digest_file "$path")" = "$digest" ] || {
        printf '{"ok":false,"proven":false,"rolledBack":false,"reason":"unproven"}\n'
        exit 3
      }
    else
      [ ! -e "$path" ] || {
        printf '{"ok":false,"proven":false,"rolledBack":false,"reason":"unproven"}\n'
        exit 3
      }
    fi
  done <"$MANIFEST"
  rm -rf "$BASE" "$MANIFEST" "$TX"
  printf '{"ok":true,"rolledBack":true,"recovered":true}\n'
}

case "$VERB" in
  baseline) do_baseline ;;
  diff) do_diff ;;
  rollback | recover) do_restore ;;
  *) usage ;;
esac
