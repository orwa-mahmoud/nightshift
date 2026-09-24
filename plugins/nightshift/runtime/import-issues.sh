#!/usr/bin/env bash
# import-issues.sh — fetch or stage explicitly selected GitHub issues.
#
# Read-only gh. Never searches. Never mutates GitHub. Never installs gh.
#   import-issues.sh [--project DIR] --fetch SPEC...
#   import-issues.sh [--project DIR] --fetch --repo owner/repo N [N...]
#   import-issues.sh [--project DIR] --stage SPEC... [--allow-closed]
#   import-issues.sh [--project DIR] --list-proposed [--authorized-repo owner/repo]
#   import-issues.sh [--project DIR] --promote SPEC... [--authorized-repo owner/repo] [--allow-flagged]
#
# SPEC is an issue URL or owner/repo#N. Default is preview (--fetch).
# --stage appends selected issues to drafting-table.md atomically.
# --list-proposed and --promote are local markdown only; they never call gh.
# Exit: 0 previewed, staged, listed, or promoted · 1 usage · 2 refused
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
MODE=""
REPO=""
ALLOW_CLOSED=0
ALLOW_FLAGGED=0
AUTH_REPO=""
SPECS=""

set_mode() {
  [ -z "$MODE" ] || [ "$MODE" = "$1" ] || {
    printf 'import-issues: choose one of --fetch, --stage, --list-proposed, --promote\n' >&2
    exit 1
  }
  MODE="$1"
}

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || exit 1; PROJECT="$2"; shift 2 ;;
    --fetch) set_mode fetch; shift ;;
    --stage) set_mode stage; shift ;;
    --list-proposed) set_mode list-proposed; shift ;;
    --promote) set_mode promote; shift ;;
    --repo) [ $# -ge 2 ] || exit 1; REPO="$2"; shift 2 ;;
    --authorized-repo) [ $# -ge 2 ] || exit 1; AUTH_REPO="$2"; shift 2 ;;
    --allow-closed) ALLOW_CLOSED=1; shift ;;
    --allow-flagged) ALLOW_FLAGGED=1; shift ;;
    -h | --help) usage; exit 1 ;;
    --) shift; break ;;
    -*)
      printf 'import-issues: unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
    *)
      SPECS="${SPECS:+$SPECS
}$1"
      shift
      ;;
  esac
done
while [ $# -gt 0 ]; do
  SPECS="${SPECS:+$SPECS
}$1"
  shift
done

[ -n "$MODE" ] || MODE=fetch

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'import-issues: cannot cd to %s\n' "$PROJECT" >&2
  exit 1
}
WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" || {
    printf 'import-issues: invalid .nightshift-link\n' >&2
    exit 2
  }
fi
NS="$WORKSPACE/.nightshift"
declare DRAFT PUNCH ARCHIVE
ns_layout_set DRAFT "$NS" drafting-table
ns_layout_set PUNCH "$NS" punch-list
ns_layout_set ARCHIVE "$NS" archive

# parse_spec SPEC
# Prints: owner<TAB>repo<TAB>number<TAB>canonical
parse_spec() {
  local spec="$1" owner="" repo="" num="" rest=""
  spec="${spec#"${spec%%[![:space:]]*}"}"
  spec="${spec%"${spec##*[![:space:]]}"}"
  [ -n "$spec" ] || return 1
  spec="${spec#https://}"
  spec="${spec#http://}"
  spec="${spec#www.}"

  case "$spec" in
    github.com/*)
      rest="${spec#github.com/}"
      owner="${rest%%/*}"
      [ "$owner" != "$rest" ] || return 1
      rest="${rest#*/}"
      repo="${rest%%/*}"
      [ "$repo" != "$rest" ] || return 1
      rest="${rest#*/}"
      case "$rest" in
        issues/[0-9]*)
          num="${rest#issues/}"
          num="${num%%[!0-9]*}"
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    */*#*)
      owner="${spec%%/*}"
      rest="${spec#*/}"
      repo="${rest%%#*}"
      num="${rest#*#}"
      num="${num%%[!0-9]*}"
      case "$repo" in */*) return 1 ;; esac
      ;;
    *)
      return 1
      ;;
  esac

  case "$owner" in "" | *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$repo" in "" | *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$num" in "" | *[!0-9]*) return 1 ;; esac
  printf '%s\t%s\t%s\thttps://github.com/%s/%s/issues/%s\n' \
    "$owner" "$repo" "$num" "$owner" "$repo" "$num"
}

parse_repo_number() {
  local pair="$1" num="$2" owner repo
  case "$pair" in
    */*) ;;
    *) return 1 ;;
  esac
  owner="${pair%%/*}"
  repo="${pair#*/}"
  case "$repo" in */* | "") return 1 ;; esac
  case "$num" in "" | *[!0-9]*) return 1 ;; esac
  parse_spec "${owner}/${repo}#${num}"
}

# flag_issue TITLE BODY — prints comma-separated flags or "none"
flag_issue() {
  local blob flags=""
  blob=$(printf '%s\n%s' "$1" "$2" | tr '[:upper:]' '[:lower:]')
  if printf '%s' "$blob" | grep -Eq 'rm[[:space:]]+-rf|drop[[:space:]]+table|format[[:space:]].*disk|delete[[:space:]]+all[[:space:]]+(files|data)|wipe[[:space:]]+disk'; then
    flags="${flags:+$flags,}destructive"
  fi
  if printf '%s' "$blob" | grep -Eq 'exfiltrat|dump[[:space:]]+(the[[:space:]]+)?(secrets?|credentials?|tokens?)|printenv|steal[[:space:]].*(password|secret|token)|api[_-]?key|private[[:space:]]+key'; then
    flags="${flags:+$flags,}secret-seeking"
  fi
  if printf '%s' "$blob" | grep -Eq 'git[[:space:]]+push|npm[[:space:]]+publish|deploy[[:space:]]+to[[:space:]]+prod|publish[[:space:]]+to[[:space:]]+(pypi|npm)'; then
    flags="${flags:+$flags,}publishing"
  fi
  if printf '%s' "$blob" | grep -Eq 'credit[[:space:]]+card|wire[[:space:]]+transfer|send[[:space:]]+money'; then
    flags="${flags:+$flags,}payment"
  fi
  if printf '%s' "$blob" | grep -Eq 'relicense|change[[:space:]]+the[[:space:]]+license|assign[[:space:]]+copyright|contributor[[:space:]]+license[[:space:]]+agreement'; then
    flags="${flags:+$flags,}legal"
  fi
  if [ -z "$2" ] || printf '%s' "$blob" | grep -Eq 'not sure what|maybe we should|consider whether|^tbd$'; then
    flags="${flags:+$flags,}ambiguous"
  fi
  printf '%s\n' "${flags:-none}"
}

sanitize_title() {
  printf '%s' "$1" | tr '\n\r' '  ' | sed 's/\*\*//g; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

quote_body() {
  local body="$1" orig_len
  body=$(printf '%s' "$body" | tr -d '\r' | sed 's/```/'\'''\'''\''/g')
  orig_len=${#body}
  if [ "$orig_len" -gt 4000 ]; then
    body=$(printf '%s' "$body" | head -c 4000)
    body="${body}
… truncated"
  fi
  if [ -z "$body" ]; then
    printf '%s\n' "    > (empty issue body)"
    return 0
  fi
  printf '%s\n' "$body" | sed 's/^/    > /'
}

already_known() {
  local url="$1" f
  [ -f "$DRAFT" ] && grep -F -q "$url" "$DRAFT" && return 0
  [ -f "$PUNCH" ] && grep -F -q "$url" "$PUNCH" && return 0
  [ -d "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] || return 1
  for f in "$ARCHIVE"/*.md; do
    [ -e "$f" ] || continue
    [ -L "$f" ] && continue
    [ -f "$f" ] || continue
    grep -F -q "$url" "$f" && return 0
  done
  for dated in "$ARCHIVE"/*; do
    if [ ! -d "$dated" ] || [ -L "$dated" ]; then
      continue
    fi
    for f in "$dated"/*.md; do
      [ -e "$f" ] || continue
      [ -L "$f" ] && continue
      [ -f "$f" ] || continue
      grep -F -q "$url" "$f" && return 0
    done
  done
  return 1
}

require_tools() {
  if ! ns_have_cmd gh; then
    printf 'import-issues: gh is not installed. Install the GitHub CLI yourself and run gh auth login. Nightshift will not install it.\n' >&2
    exit 2
  fi
  if ! ns_have_cmd jq; then
    printf 'import-issues: jq is required to read issue JSON\n' >&2
    exit 2
  fi
  if ! gh auth status >/dev/null 2>&1; then
    printf 'import-issues: gh is not authenticated. Run gh auth login and retry. No files were changed.\n' >&2
    exit 2
  fi
}

fetch_issue() {
  local owner="$1" repo="$2" num="$3"
  gh issue view "$num" --repo "${owner}/${repo}" --json title,body,labels,state,number,url 2>/dev/null |
    jq -e 'select(type == "object" and .title and .number and .url)'
}

# Local markdown cut. Never calls gh.
import_md() {
  if ! ns_have_cmd python3; then
    printf 'import-issues: list/promote unavailable without a parser; cut drafts in the skill\n' >&2
    exit 2
  fi
  python3 - "$@" <<'PY'
import re, sys

ITEM_RE = re.compile(r"(?m)^- \[ \] \*\*.+\*\*\s*$")
SOURCE_RE = re.compile(
    r"(?m)^\s*- Source: (https://github.com/[^/\s]+/[^/\s]+/issues/\d+)\s*$"
)
STATUS_RE = re.compile(r"(?m)^\s*- Status: proposed\s*$")
REPO_RE = re.compile(r"(?m)^\s*- Repository: (\S+)\s*$")
FLAGS_RE = re.compile(r"(?m)^\s*- Review flags: (.+?)\s*$")
TITLE_RE = re.compile(r"^- \[ \] \*\*(.+)\.\*\*\s*$")

def split_items(text):
    matches = list(ITEM_RE.finditer(text))
    if not matches:
        return text, []
    head = text[: matches[0].start()]
    items = []
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        items.append(text[m.start() : end])
    return head, items

def parse_import(block):
    if not STATUS_RE.search(block):
        return None
    sm = SOURCE_RE.search(block)
    if not sm:
        return None
    rm = REPO_RE.search(block)
    fm = FLAGS_RE.search(block)
    first = block.splitlines()[0] if block.splitlines() else ""
    tm = TITLE_RE.search(first)
    return {
        "block": block,
        "url": sm.group(1),
        "repo": rm.group(1) if rm else "",
        "flags": fm.group(1).strip() if fm else "none",
        "title": tm.group(1) if tm else "",
    }

def load_imports(path):
    text = open(path, encoding="utf-8").read()
    head, items = split_items(text)
    parsed = []
    other = []
    for block in items:
        info = parse_import(block)
        if info:
            parsed.append(info)
        else:
            other.append(block)
    return text, head, parsed, other

cmd, draft_path = sys.argv[1], sys.argv[2]
auth = sys.argv[3] if len(sys.argv) > 3 else ""
_, head, imported, other = load_imports(draft_path)

def allowed(info):
    return not auth or info["repo"] == auth

if cmd == "list":
    for info in imported:
        if allowed(info):
            print("\t".join([info["url"], info["repo"], info["flags"], info["title"]]))
    sys.exit(0)

if cmd != "promote":
    sys.exit(2)

punch_path = sys.argv[4]
allow_flagged = sys.argv[5] == "1"
urls = sys.argv[6:]
punch = open(punch_path, encoding="utf-8").read()
if "## Items" not in punch:
    sys.stderr.write("import-issues: punch list has no ## Items heading\n")
    sys.exit(2)

by_url = {info["url"]: info for info in imported}
chosen = []
for url in urls:
    info = by_url.get(url)
    if info is None:
        sys.stderr.write("import-issues: not a proposed imported issue: %s\n" % url)
        sys.exit(2)
    if not allowed(info):
        sys.stderr.write("import-issues: %s is outside the authorized repository\n" % url)
        sys.exit(2)
    if info["flags"] != "none" and not allow_flagged:
        sys.stderr.write("import-issues: refuse flagged issue %s (%s)\n" % (url, info["flags"]))
        sys.exit(2)
    if info["url"] in punch:
        sys.stderr.write("import-issues: already on the punch list: %s\n" % url)
        sys.exit(2)
    chosen.append(info)

if not chosen:
    sys.stderr.write("import-issues: nothing to promote\n")
    sys.exit(1)

remain = [info["block"] for info in imported if info["url"] not in {c["url"] for c in chosen}]
new_draft = head + "".join(other) + "".join(remain)
moved = "".join(c["block"].rstrip() + "\n\n" for c in chosen)
if not punch.endswith("\n"):
    punch += "\n"
new_punch = punch + "\n" + moved
open(draft_path + ".next", "w", encoding="utf-8").write(new_draft)
open(punch_path + ".next", "w", encoding="utf-8").write(new_punch)
print("promoted\t%d" % len(chosen))
PY
}

canonical_specs() {
  local spec
  : >"$work/canon"
  if [ -n "$REPO" ]; then
    [ -n "$SPECS" ] || {
      printf 'import-issues: --repo requires explicit issue numbers. Nightshift never lists a repository.\n' >&2
      exit 1
    }
    printf '%s\n' "$SPECS" >"$work/specs"
    while IFS= read -r spec; do
      [ -n "$spec" ] || continue
      case "$spec" in
        *[!0-9]*)
          printf 'import-issues: with --repo, arguments must be issue numbers (got %s)\n' "$spec" >&2
          exit 1
          ;;
      esac
      parse_repo_number "$REPO" "$spec" >>"$work/canon" || {
        printf 'import-issues: cannot parse --repo %s issue %s\n' "$REPO" "$spec" >&2
        exit 1
      }
    done <"$work/specs"
  else
    printf '%s\n' "$SPECS" >"$work/specs"
    while IFS= read -r spec; do
      [ -n "$spec" ] || continue
      parse_spec "$spec" >>"$work/canon" || {
        printf 'import-issues: not an explicit GitHub issue: %s\n' "$spec" >&2
        exit 1
      }
    done <"$work/specs"
  fi
  awk -F '\t' '!seen[$4]++ { print $4 }' "$work/canon"
}

if [ "$MODE" = list-proposed ] || [ "$MODE" = promote ]; then
  [ -d "$NS" ] || {
    printf 'import-issues: no .nightshift/ — run setup first\n' >&2
    exit 2
  }
  [ -f "$DRAFT" ] || {
    printf 'import-issues: missing drafting-table.md — run setup first. No files were changed.\n' >&2
    exit 2
  }
  if [ -n "$AUTH_REPO" ]; then
    case "$AUTH_REPO" in
      */*) ;;
      *)
        printf 'import-issues: --authorized-repo must be owner/repo\n' >&2
        exit 1
        ;;
    esac
  fi
  if [ "$MODE" = list-proposed ]; then
    import_md list "$DRAFT" "$AUTH_REPO"
    exit $?
  fi
  [ -f "$PUNCH" ] || {
    printf 'import-issues: missing punch-list.md — run setup first. No files were changed.\n' >&2
    exit 2
  }
  [ -n "$SPECS" ] || [ -n "$REPO" ] || {
    printf 'import-issues: name explicit issue URLs to promote. Nightshift never searches.\n' >&2
    exit 1
  }
  work=$(mktemp -d "${TMPDIR:-/tmp}/ns-import.XXXXXX") || exit 2
  trap 'rm -rf "$work"' EXIT
  urls=$(canonical_specs) || exit 1
  # shellcheck disable=SC2086
  set -- $urls
  [ $# -gt 0 ] || {
    printf 'import-issues: nothing to promote\n' >&2
    exit 1
  }
  import_md promote "$DRAFT" "$AUTH_REPO" "$PUNCH" "$ALLOW_FLAGGED" "$@" || {
    rm -f "$DRAFT.next" "$PUNCH.next"
    exit 2
  }
  draft_backup="${DRAFT%/*}/.drafting-table.md.rollback.$$"
  punch_backup="${PUNCH%/*}/.punch-list.md.rollback.$$"
  if ! cp "$DRAFT" "$draft_backup" || ! cp "$PUNCH" "$punch_backup"; then
    rm -f "$DRAFT.next" "$PUNCH.next" "$draft_backup" "$punch_backup"
    printf 'import-issues: could not prepare a rollback copy. Both live queues are unchanged.\n' >&2
    exit 2
  fi
  # Replace the destination first while the source remains live. If the second
  # replace fails, restore both files so an issue is never lost between queues.
  if ! mv "$PUNCH.next" "$PUNCH"; then
    rm -f "$DRAFT.next" "$PUNCH.next" "$draft_backup" "$punch_backup"
    printf 'import-issues: could not update the punch list. Both live queues are unchanged.\n' >&2
    exit 2
  fi
  if ! mv "$DRAFT.next" "$DRAFT"; then
    rollback_ok=1
    cp "$punch_backup" "$PUNCH" || rollback_ok=0
    cp "$draft_backup" "$DRAFT" || rollback_ok=0
    rm -f "$DRAFT.next" "$PUNCH.next"
    if [ "$rollback_ok" -eq 1 ]; then
      rm -f "$draft_backup" "$punch_backup"
      printf 'import-issues: could not update the drafting table. Both live queues were restored.\n' >&2
    else
      printf 'import-issues: queue update and rollback failed. Inspect both live files and rollback copies before continuing.\n' >&2
    fi
    exit 2
  fi
  rm -f "$draft_backup" "$punch_backup"
  printf 'Promoted %s issue(s) into the punch list. Removed from the drafting table.\n' "$#"
  exit 0
fi

[ -n "$SPECS" ] || [ -n "$REPO" ] || {
  printf 'import-issues: name explicit issue URLs or --repo owner/repo plus issue numbers. Nightshift never searches.\n' >&2
  exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/ns-import.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

if [ -n "$REPO" ]; then
  [ -n "$SPECS" ] || {
    printf 'import-issues: --repo requires explicit issue numbers. Nightshift never lists a repository.\n' >&2
    exit 1
  }
  printf '%s\n' "$SPECS" >"$work/specs"
  : >"$work/parsed"
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    case "$spec" in
      *[!0-9]*)
        printf 'import-issues: with --repo, arguments must be issue numbers (got %s)\n' "$spec" >&2
        exit 1
        ;;
    esac
    parse_repo_number "$REPO" "$spec" >>"$work/parsed" || {
      printf 'import-issues: cannot parse --repo %s issue %s\n' "$REPO" "$spec" >&2
      exit 1
    }
  done <"$work/specs"
else
  printf '%s\n' "$SPECS" >"$work/specs"
  : >"$work/parsed"
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    parse_spec "$spec" >>"$work/parsed" || {
      printf 'import-issues: not an explicit GitHub issue: %s\n' "$spec" >&2
      exit 1
    }
  done <"$work/specs"
fi

[ -s "$work/parsed" ] || {
  printf 'import-issues: nothing to fetch\n' >&2
  exit 1
}

awk -F '\t' '!seen[$4]++' "$work/parsed" >"$work/uniq"
mv "$work/uniq" "$work/parsed"

if [ "$MODE" = stage ]; then
  [ -d "$NS" ] || {
    printf 'import-issues: no .nightshift/ — run setup first\n' >&2
    exit 2
  }
  [ -f "$DRAFT" ] || {
    printf 'import-issues: missing drafting-table.md — run setup first. No files were changed.\n' >&2
    exit 2
  }
fi

require_tools

fail=0
n=0
: >"$work/index"
while IFS="$(printf '\t')" read -r owner repo num canonical; do
  [ -n "$canonical" ] || continue
  n=$((n + 1))
  if ! fetch_issue "$owner" "$repo" "$num" >"$work/$n.json"; then
    printf 'import-issues: failed to read %s\n' "$canonical" >&2
    rm -f "$work/$n.json"
    fail=1
    n=$((n - 1))
    continue
  fi
  printf '%s\n' "$canonical" >"$work/$n.url"
  printf '%s\n' "$n" >>"$work/index"
done <"$work/parsed"

if [ ! -s "$work/index" ]; then
  printf 'import-issues: no issues could be read. No files were changed.\n' >&2
  exit 2
fi

imported="${NIGHTSHIFT_IMPORT_TIME:-}"
if [ -z "$imported" ]; then
  imported=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

: >"$work/blocks"
shown=0
staged_n=0

while IFS= read -r i; do
  [ -n "$i" ] || continue
  canonical=$(cat "$work/$i.url")
  json_file="$work/$i.json"
  title=$(jq -r '.title // empty' "$json_file")
  body=$(jq -r '.body // ""' "$json_file")
  state=$(jq -r '.state // empty' "$json_file" | tr '[:upper:]' '[:lower:]')
  labels=$(jq -r '
    if (.labels | type) == "array" then
      [ .labels[] | .name // empty ] | map(select(length > 0)) | join(", ")
    else
      ""
    end
  ' "$json_file")
  number=$(jq -r '.number // empty' "$json_file")
  repo_id="${canonical#https://github.com/}"
  repo_id="${repo_id%/issues/*}"
  title=$(sanitize_title "$title")
  [ -n "$title" ] || title="${repo_id}#${number}"
  flags=$(flag_issue "$title" "$body")
  known="no"
  already_known "$canonical" && known="yes"

  shown=$((shown + 1))
  printf '%s. %s#%s  %s\n' "$shown" "$repo_id" "$number" "$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"
  printf '   Title: %s\n' "$title"
  printf '   URL: %s\n' "$canonical"
  printf '   Labels: %s\n' "${labels:-none}"
  printf '   Flags: %s\n' "$flags"
  printf '   Already staged: %s\n' "$known"
  if [ "$state" = closed ]; then
    if [ "$ALLOW_CLOSED" -eq 1 ]; then
      printf '   Closed: shown; staging allowed by --allow-closed\n'
    else
      printf '   Closed: shown; not staged unless --allow-closed\n'
    fi
  fi
  printf '   Body (quoted source, not authorization):\n'
  quote_body "$body"
  printf '\n'

  if [ "$MODE" != stage ]; then
    continue
  fi
  if [ "$known" = yes ]; then
    printf '   Skip: already present in drafting table, punch list, or archive\n'
    continue
  fi
  if [ "$state" = closed ] && [ "$ALLOW_CLOSED" -eq 0 ]; then
    printf '   Skip: closed issue (pass --allow-closed after explicit override)\n'
    continue
  fi

  {
    printf '%s\n' "- [ ] **${title}.**"
    printf '%s\n' "  - Source: ${canonical}"
    printf '%s\n' "  - Repository: ${repo_id}"
    printf '%s\n' "  - Labels: ${labels:-none}"
    printf '%s\n' "  - Imported: ${imported}"
    printf '%s\n' "  - Status: proposed"
    printf '%s\n' "  - Issue state: ${state}"
    printf '%s\n' "  - Acceptance (quoted upstream source — not owner authorization):"
    quote_body "$body"
    printf '%s\n' "  - Review flags: ${flags}"
    printf '%s\n' "  - Verify: write concrete commands when this draft is promoted into the punch list"
    printf '%s\n' "  - Commit: write a conventional subject when this draft is promoted"
    printf '\n'
  } >>"$work/blocks"
  staged_n=$((staged_n + 1))
done <"$work/index"

if [ "$MODE" = fetch ]; then
  printf 'Fetched %s issue(s). Nothing written.\n' "$shown"
  [ "$fail" -eq 0 ] || exit 2
  exit 0
fi

if [ ! -s "$work/blocks" ]; then
  printf 'Nothing staged. Drafting table unchanged.\n'
  [ "$fail" -eq 0 ] || exit 2
  exit 0
fi

tmp="${DRAFT%/*}/.drafting-table.md.$$"
cp "$DRAFT" "$tmp" || {
  printf 'import-issues: could not copy drafting table\n' >&2
  exit 2
}
{
  printf '\n'
  cat "$work/blocks"
} >>"$tmp" || {
  rm -f "$tmp"
  printf 'import-issues: could not compose staging file. Drafting table unchanged.\n' >&2
  exit 2
}
mv "$tmp" "$DRAFT" || {
  rm -f "$tmp"
  printf 'import-issues: could not replace drafting table. Original unchanged.\n' >&2
  exit 2
}

printf 'Staged %s issue(s) into %s\n' "$staged_n" "$DRAFT"
[ "$fail" -eq 0 ] || exit 2
exit 0
