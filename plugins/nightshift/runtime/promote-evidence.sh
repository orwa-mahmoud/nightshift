#!/usr/bin/env bash
# promote-evidence.sh — choose which raw evidence of a filed shift the team's history shares.
#
#   promote-evidence.sh [--project DIR] --folder NAME [--select FILE]... [--all | --none] [--apply]
#
# A filed shift keeps each receipt's raw evidence (screenshots, recordings) in a folder beside the
# receipt, which Git ignores. This lists those files and the ones the project's preference,
# sharing.evidence in rules.json, would promote: none (the default), all, or select (the owner picks).
# --select, --all and --none set this filing's choice without changing the preference. With
# --apply, each chosen file is copied into the folder's evidence/, where Git sees it, and the filed
# receipts link to that copy by relative path; a file left private keeps its original and its link
# becomes a label that names it as private evidence, so no shared page carries a broken link or a
# runner's own path. Applying the same choice again leaves one copy and changes nothing else. Only
# regular files inside the folder's own evidence folders are eligible: a link is never followed.
#
# Prints one verdict per line: `ok`, `eligible`, `promote`, or `refuse` followed by its `repair`.
# Exit: 0 previewed or applied · 1 refused · 2 usage
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
_here="$(cd -P "$_here" && pwd)" || exit 2
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-$PWD}}}"
FOLDER=""
CHOICE=""
SELECTED=""
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project | --folder | --select)
      [ $# -ge 2 ] || { printf 'promote-evidence: %s needs a value\n' "$1" >&2; exit 2; }
      case "$1" in
        --project) PROJECT="$2" ;;
        --folder) FOLDER="$2" ;;
        --select)
          CHOICE=select
          SELECTED="$SELECTED$2
"
          ;;
      esac
      shift 2
      ;;
    --all | --none)
      CHOICE="${1#--}"
      shift
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 2
      ;;
    *) printf 'promote-evidence: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$FOLDER" in
  '' | .* | */*) printf 'promote-evidence: --folder names one filed shift folder\n' >&2; exit 2 ;;
esac

ok() { printf 'ok %s\n' "$1"; }
refuse() {
  printf 'refuse %s\n' "$1"
  [ -z "${2:-}" ] || printf 'repair %s\n' "$2"
  exit 1
}

WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || refuse "workspace no workspace at $PROJECT" "run Setup in the project first"
ROOT="$(ns_archive_root "$WORKSPACE")" || refuse "archive the archive root cannot be resolved" "run ns doctor"
DIR="$ROOT/$FOLDER"
[ -d "$DIR" ] && [ ! -L "$DIR" ] || refuse "folder no filed shift folder $FOLDER under ${ROOT##*/.nightshift/}" "name a folder Archive printed"
RECEIPTS="$DIR/receipts"
SHARED="$DIR/evidence"
REAL="$(cd -P "$RECEIPTS" 2>/dev/null && pwd)" || REAL=""

PREF="$(ns_rules_get_in "$(ns_layout_path "$WORKSPACE/.nightshift" rules)" sharing evidence)"
case "$PREF" in '') PREF=none ;; none | select | all) ;; *) refuse "preference sharing.evidence is $PREF" "use none, select or all" ;; esac
[ -n "$CHOICE" ] || case "$PREF" in all) CHOICE=all ;; *) CHOICE=none ;; esac

# eligible — each raw evidence file of the folder's receipts, as <receipt>/<path>: a regular file in
# a folder named after a filed receipt. find lists a link as a link and never descends into one, so
# nothing outside the folder is ever reached.
eligible() {
  local d base
  [ -n "$REAL" ] || return 0
  for d in "$RECEIPTS"/*/; do
    d="${d%/}"
    base="${d##*/}"
    [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$RECEIPTS/$base.md" ] || continue
    [ "$(cd -P "$d" && pwd)" = "$REAL/$base" ] || continue
    (cd "$d" && find . -type f ! -path '*/.*' 2>/dev/null) | sed "s|^\./|$base/|"
  done | LC_ALL=C sort
}

ELIGIBLE="$(eligible)"
case "$CHOICE" in
  all) CHOSEN="$ELIGIBLE" ;;
  none) CHOSEN="" ;;
  select)
    CHOSEN=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf '%s\n' "$ELIGIBLE" | grep -qxF -- "$f" ||
        refuse "select $f is not raw evidence of $FOLDER" "choose from the eligible files this prints without --select"
      CHOSEN="$CHOSEN$f
"
    done <<EOF_SELECTED
$SELECTED
EOF_SELECTED
    CHOSEN="$(printf '%s' "$CHOSEN" | LC_ALL=C sort -u)"
    ;;
esac

ok "preference $PREF"
[ -z "$ELIGIBLE" ] || printf '%s\n' "$ELIGIBLE" | sed 's/^/eligible /'
[ -z "$CHOSEN" ] || printf '%s\n' "$CHOSEN" | sed 's/^/promote /'
if [ -z "$ELIGIBLE" ]; then
  ok "nothing to promote: $FOLDER keeps no raw evidence"
  exit 0
fi
if [ "$APPLY" -eq 0 ]; then
  printf 'next run this again with --apply, and --select, --all or --none to change the choice\n'
  exit 0
fi

# ---------------------------------------------------------------- copy the chosen files
while IFS= read -r f; do
  [ -n "$f" ] || continue
  mkdir -p "$SHARED/${f%/*}" || refuse "copy could not create $SHARED/${f%/*}" "check that .nightshift/ is writable"
  if ! cmp -s "$RECEIPTS/$f" "$SHARED/$f" 2>/dev/null; then
    cp "$RECEIPTS/$f" "$SHARED/$f" || refuse "copy could not copy $f" "check that .nightshift/ is writable"
  fi
done <<EOF_CHOSEN
$CHOSEN
EOF_CHOSEN

# ---------------------------------------------------------------- relink the filed receipts
# Each link to a raw file points at its shared copy when it was promoted and becomes a private label
# when it was not.
for receipt in "$RECEIPTS"/*.md; do
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || continue
  base="${receipt##*/}"
  base="${base%.md}"
  if ! NS_CHOSEN="$CHOSEN" awk -v base="$base" '
    # Every link into the evidence folder of this receipt: a promoted file links to its shared copy;
    # any other becomes a label, so the shared page carries no link that resolves only on one machine.
    BEGIN {
      nc = split(ENVIRON["NS_CHOSEN"], c, "\n")
      for (k = 1; k <= nc; k++) if (c[k] != "") chosen[c[k]] = 1
    }
    {
      line = $0
      out = ""
      while ((i = index(line, "](")) > 0) {
        close_at = index(substr(line, i + 2), ")")
        if (close_at == 0) break
        target = substr(line, i + 2, close_at - 1)
        p = target
        sub(/^\.\//, "", p)
        open = 0
        for (j = i - 1; j >= 1; j--) if (substr(line, j, 1) == "[") { open = j; break }
        if (index(p, base "/") != 1 || open == 0) {
          out = out substr(line, 1, i + close_at + 1)
          line = substr(line, i + close_at + 2)
          continue
        }
        text = substr(line, open + 1, i - open - 1)
        bang = (open > 1 && substr(line, open - 1, 1) == "!") ? 1 : 0
        out = out substr(line, 1, open - 1 - bang)
        if (p in chosen) out = out (bang ? "!" : "") "[" text "](../evidence/" p ")"
        else out = out text " (private evidence: " p ")"
        line = substr(line, i + close_at + 2)
      }
      print out line
    }' "$receipt" >"$receipt.tmp.$$" || ! mv -f "$receipt.tmp.$$" "$receipt"; then
    rm -f "$receipt.tmp.$$"
    refuse "relink could not rewrite ${receipt##*/}" "check that .nightshift/ is writable"
  fi
done
ok "promoted $(printf '%s' "$CHOSEN" | grep -c .) of $(printf '%s\n' "$ELIGIBLE" | grep -c .) evidence files of $FOLDER; the rest stay private"
exit 0
