#!/usr/bin/env bash
# check-items.sh — check the shape of drafted items before they are promoted.
#
#   check-items.sh --project DIR [--file PATH]
#
# Reads the drafting table, or the file named: the items under its `## Items` heading when it has
# one (a punch list), else the items below its first `---` rule, else the whole file. For each item
# it reports what the gate and the item's own definition of done would trip over:
#
#   no Verify: line · a Verify: that names no command and no WHEN/THEN scenario · no Commit: line
#   (or Receipt: in artifact mode) · a Budget: line that does not parse · a nested checkbox
#
# and, anywhere in that part of the file, a checkbox outside an item line, which the gate would count
# as an open item. It checks the shape of the plan, never the work behind a tick, and refuses
# nothing: Start and promotion never wait on it. Read-only.
#
# Exit: 0 checked · 1 usage/resolve
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT=""
FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'check-items: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --file)
      [ $# -ge 2 ] || { printf 'check-items: --file needs a value\n' >&2; exit 1; }
      FILE="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'check-items: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$PROJECT" ] || { printf 'check-items: --project is required\n' >&2; exit 1; }

if [ -z "$FILE" ]; then
  WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || { printf 'check-items: no workspace at %s\n' "$PROJECT" >&2; exit 1; }
  ns_layout_set FILE "$WORKSPACE/.nightshift" drafting-table
fi
if [ ! -f "$FILE" ] || [ -L "$FILE" ]; then
  printf 'no items to check: %s is not there\n' "$FILE"
  exit 0
fi

# Events, in file order: `item <label>`, `find <finding>`, `budget <text>` for the item being read,
# and `outside <line>` for a box no item owns.
EVENTS="$(awk '
  { sub(/\r$/, "") }
  # Where the items are: under `## Items`, else below the first rule, else everywhere.
  FNR == 1 && !scanned {
    while ((getline l < FILENAME) > 0) {
      sub(/\r$/, "", l)
      if (l ~ /^##[[:space:]]*Items[[:space:]]*$/) { mode = "items"; break }
      if (l ~ /^--- *$/ && mode == "") mode = "rule"
    }
    close(FILENAME)
    if (mode == "") mode = "all"
    scanned = 1
    on = (mode == "all")
  }
  !on {
    if (mode == "items" && $0 ~ /^##[[:space:]]*Items[[:space:]]*$/) on = 1
    if (mode == "rule" && $0 ~ /^--- *$/) on = 1
    next
  }
  mode == "items" && /^## / { finish(); on = 0; next }

  function finish() {
    if (!open) return
    if (!verify) print "find\tno Verify: line"
    else if (!concrete) print "find\tVerify: names no command and no WHEN/THEN scenario"
    if (!commit) print "find\tno Commit: line"
    if (budget != "") print "budget\t" budgettext
    for (i = 1; i <= nested; i++) print "find\tline " nestedat[i] ": a nested checkbox; only the item line may be a box"
    open = 0
  }

  # Fenced code and HTML comments hold no items, but a box written in them is still counted.
  fence || /^[[:space:]]*```/ {
    if (!fence && /^```/) finish()
    if (/^[[:space:]]*```/) fence = !fence
    if (/^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/) print "outside\t" FNR
    next
  }
  comment {
    if ($0 ~ /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/) print "outside\t" FNR
    if ($0 ~ /-->/) comment = 0
    next
  }
  # A comment that opens here and runs on: nothing in it is an item. One that closes on the same
  # line, such as an item id, leaves the line as it was.
  {
    line = $0
    gsub(/<!--.*-->/, "", line)
  }
  line ~ /<!--/ {
    if ($0 !~ /^[[:space:]]/) finish()
    comment = 1
    if ($0 ~ /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/) print "outside\t" FNR
    next
  }

  /^- \[[ xX-]\]/ {
    finish()
    label = $0
    sub(/^- \[.\][[:space:]]*/, "", label)
    sub(/[[:space:]]*<!--.*-->[[:space:]]*$/, "", label)
    print "item\t" label
    open = 1; verify = 0; concrete = 0; commit = 0; budget = ""; budgettext = ""; nested = 0; inverify = 0
    next
  }

  /^[[:space:]]*$/ { inverify = 0; next }

  open && /^[[:space:]]+/ {
    indent = match($0, /[^[:space:]]/) - 1
    if (inverify && indent > verifyindent) {
      if ($0 ~ /`[^`]+`/ || $0 ~ /WHEN .*THEN /) concrete = 1
      next
    }
    inverify = 0
    if ($0 ~ /^[[:space:]]*-[[:space:]]*\[.\]/) { nestedat[++nested] = FNR; next }
    if ($0 ~ /^[[:space:]]*- Verify:/) {
      verify = 1; inverify = 1; verifyindent = indent
      if ($0 ~ /`[^`]+`/ || $0 ~ /WHEN .*THEN /) concrete = 1
      next
    }
    if ($0 ~ /^[[:space:]]*- (Commit|Receipt):/) { commit = 1; next }
    if ($0 ~ /^[[:space:]]*- Budget:/) {
      budget = "yes"
      budgettext = $0
      sub(/^[[:space:]]*- Budget:[[:space:]]*/, "", budgettext)
      next
    }
    next
  }

  # Any other top-level line ends the item; a box written another way is one no item owns.
  {
    finish()
    if ($0 ~ /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/) print "outside\t" FNR
  }
  END { finish() }
' "$FILE")"

ITEMS=0
WITH=0
LABEL=""
ITEM_FINDINGS=0
# close_item — the `ok` line for an item that had nothing to report.
close_item() {
  [ -n "$LABEL" ] || return 0
  if [ "$ITEM_FINDINGS" -eq 0 ]; then
    printf '%s: ok\n' "$LABEL"
  else
    WITH=$((WITH + 1))
  fi
  LABEL=""
}
finding() {
  printf '%s: %s\n' "$LABEL" "$1"
  ITEM_FINDINGS=$((ITEM_FINDINGS + 1))
}
OUTSIDE=0
while IFS=$'\t' read -r kind text; do
  case "$kind" in
    item)
      close_item
      LABEL="$text"
      ITEM_FINDINGS=0
      ITEMS=$((ITEMS + 1))
      ;;
    find) finding "$text" ;;
    budget) ns_budget_parse "$text" >/dev/null 2>&1 || finding "Budget: does not parse ($text)" ;;
    outside)
      close_item
      printf 'line %s: a checkbox outside an item line counts as an open item\n' "$text"
      OUTSIDE=$((OUTSIDE + 1))
      ;;
  esac
done <<<"$EVENTS"
close_item

if [ "$ITEMS" -eq 0 ] && [ "$OUTSIDE" -eq 0 ]; then
  printf 'no items to check\n'
  exit 0
fi
printf 'checked %s items: %s with findings' "$ITEMS" "$WITH"
case "$OUTSIDE" in
  0) ;;
  1) printf ', 1 stray checkbox' ;;
  *) printf ', %s stray checkboxes' "$OUTSIDE" ;;
esac
printf '\n'
