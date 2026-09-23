#!/usr/bin/env bash
# Nightshift runtime state: rules, punch-list counts, schema, retention, watch-reason.

# The owner's rules file is the one copy of every knob: .nightshift/rules.json — nightshift's
# whole life lives in nightshift's folder, and deleting the folder deletes all of it. Hooks
# read the file directly — a change applies from the next tool call. An env var of the
# matching name, when set, overrides the file for the session: the test suite's lever and the
# power user's per-session exception, never a second copy the owner maintains.
# rule <project-dir> <file-key> <env-value> — prints the effective value ('' = default).
rule() {
  if [ -n "$3" ]; then printf '%s' "$3"; return; fi
  local f="$1/.nightshift/rules.json"
  [ -f "$f" ] || return 0
  ns_rules_get "$f" "$2"
}

# ns_receipts <project-dir> <field> — one field of the receipts block, or empty.
ns_receipts() {
  ns_policy_pref "$1" receipts "$2"
}

# ns_report — the old name. Same fields live under receipts now.
ns_report() {
  ns_receipts "$@"
}

# ns_receipts_enabled <project-dir> — status 0 unless the owner turned receipts off.
ns_receipts_enabled() {
  [ "$(ns_receipts "$1" enabled)" != false ]
}

ns_report_enabled() {
  ns_receipts_enabled "$1"
}

# ns_receipts_dir <project-dir> — the folder that holds the index, morning page, and item files.
ns_receipts_dir() {
  printf '%s/.nightshift/receipts' "$1"
}

# ns_receipt_slug <title> — title lowercased, non-alphanumerics collapsed to one -, trimmed, 60.
ns_receipt_slug() {
  printf '%s' "$1" | LC_ALL=C awk '
    {
      s = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        o = index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
        if (o) c = substr("abcdefghijklmnopqrstuvwxyz", o, 1)
        if (c ~ /[a-z0-9]/) s = s c
        else s = s "-"
      }
      gsub(/-+/, "-", s)
      gsub(/^-|-$/, "", s)
      if (length(s) > 60) {
        s = substr(s, 1, 60)
        gsub(/-$/, "", s)
      }
      print s
    }
  '
}

# ns_receipt_nn <label> — the item number as written: leading digits, or a letter+digits id.
ns_receipt_nn() {
  printf '%s' "$1" | LC_ALL=C awk '
    {
      if (match($0, /^[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit }
      if (match($0, /^[A-Za-z]+[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit }
    }
  '
}

# ns_receipt_title <label> — the words after the written number, for the slug.
ns_receipt_title() {
  printf '%s' "$1" | LC_ALL=C awk '
    {
      sub(/^[0-9]+\.[[:space:]]*/, "")
      sub(/^[A-Za-z]+[0-9]+[[:space:]]+/, "")
      print
    }
  '
}

# ns_receipt_basename <label> — NN-slug, no suffix.
ns_receipt_basename() {
  local label="$1" nn title slug
  # A leftover `- [x]` from a ticked line must not become an `x-` sidecar file.
  label="$(printf '%s' "$label" | sed 's/^- \[[xX ]\][[:space:]]*//; s/^\*\*//; s/\*\*$//')"
  nn="$(ns_receipt_nn "$label")"
  title="$(ns_receipt_title "$label")"
  [ -n "$title" ] || title="$label"
  if [ -n "$nn" ] && [ "$title" = "$label" ]; then
    printf '%s' "$nn"
    return 0
  fi
  slug="$(ns_receipt_slug "$title")"
  if [ -n "$nn" ] && [ -n "$slug" ]; then
    printf '%s-%s' "$nn" "$slug"
  elif [ -n "$slug" ]; then
    printf '%s' "$slug"
  else
    printf '%s' "$(ns_receipt_slug "$label")"
  fi
}

# ---------------------------------------------------------------------------------------------
# Item identity
#
# An item's number keeps its place in the list and its id keeps its identity. The first time the
# shift policy is recorded, every item without an id gets one as a trailing comment on its own
# line: `- [ ] **3. Fix the resolver.** <!-- id: k7q2 -->`. The owner may renumber, reorder or
# retitle items between shifts; the receipt and its history follow the id. Every reader of an
# item's label goes through NS_AWK_ITEM, so the comment is never part of a label.

# The awk functions every item reader shares, prepended to the program text.
NS_AWK_ITEM='
function ns_item_id(line,    s) {
  sub(/\r$/, "", line)
  if (!match(line, /<!--[[:space:]]*id:[[:space:]]*[a-z0-9]+[[:space:]]*-->[[:space:]]*$/)) return ""
  s = substr(line, RSTART, RLENGTH)
  sub(/^<!--[[:space:]]*id:[[:space:]]*/, "", s)
  sub(/[[:space:]]*-->[[:space:]]*$/, "", s)
  return s
}
function ns_item_label(line) {
  sub(/\r$/, "", line)
  sub(/[[:space:]]*<!--[[:space:]]*id:[[:space:]]*[a-z0-9]+[[:space:]]*-->[[:space:]]*$/, "", line)
  sub(/^- \[[ xX]\][[:space:]]*\*\*/, "", line)
  sub(/^- \[[ xX]\][[:space:]]*/, "", line)
  sub(/[[:space:]]+—.*$/, "", line)
  sub(/[[:space:]]+-[[:space:]].*$/, "", line)
  sub(/\*\*.*$/, "", line)
  gsub(/[[:space:]]+$/, "", line)
  return line
}
'

# ns_item_rows <punch-list> [open|ticked|all] — `<label>\t<id>` for each top-level item under
# `## Items` that has a label, list order. The id is empty for an item that has none.
ns_item_rows() {
  ns_items_section "$1" 2>/dev/null | awk -v want="${2:-all}" "$NS_AWK_ITEM"'
    /^- \[[ xX]\]/ {
      open = ($0 ~ /^- \[ \]/)
      if (want == "open" && !open) next
      if (want == "ticked" && open) next
      label = ns_item_label($0)
      if (label != "") print label "\t" ns_item_id($0)
    }
  '
}

# ns_item_ids <punch-list> — every id the list's items carry, one per line.
ns_item_ids() {
  ns_items_section "$1" 2>/dev/null | awk "$NS_AWK_ITEM"'
    /^- \[[ xX]\]/ { id = ns_item_id($0); if (id != "") print id }
  '
}

# ns_item_id_for <punch-list> <label> — the id of the first item with that label, or nothing.
ns_item_id_for() {
  ns_items_section "$1" 2>/dev/null | awk -v want="$2" "$NS_AWK_ITEM"'
    /^- \[[ xX]\]/ && ns_item_label($0) == want { print ns_item_id($0); exit }
  '
}

# ns_item_id_used <nightshift-dir> <id> [taken] — status 0 when the id is in `taken`, is carried by
# an archived list or receipt, or already names a receipt file, so an id means one item for as
# long as the history is kept.
ns_item_id_used() {
  local ns="$1" id="$2"
  case " ${3:-} " in *" $id "*) return 0 ;; esac
  grep -rqsF -- "id: $id " "$ns/archive" "$ns/receipts" && return 0
  [ -n "$(find "$ns/receipts" "$ns/archive" \( -name "$id.md" -o -name "$id-*.md" \) -print 2>/dev/null | head -n1)" ]
}

# ns_item_new_id <nightshift-dir> [taken] — a fresh id: a letter, then three letters or digits, that
# ns_item_id_used does not know.
ns_item_new_id() {
  local ns="$1" taken="${2:-}" id tries=0
  while [ "$tries" -lt 64 ]; do
    tries=$((tries + 1))
    id="$(od -An -N4 -tu1 /dev/urandom 2>/dev/null | awk '
      NF >= 4 {
        a = "abcdefghijklmnopqrstuvwxyz"; b = a "0123456789"
        printf "%s%s%s%s", substr(a, $1 % 26 + 1, 1), substr(b, $2 % 36 + 1, 1),
          substr(b, $3 % 36 + 1, 1), substr(b, $4 % 36 + 1, 1)
      }')" || return 1
    [ "${#id}" -eq 4 ] || return 1
    ns_item_id_used "$ns" "$id" "$taken" && continue
    printf '%s' "$id"
    return 0
  done
  return 1
}

# ns_punch_assign_ids <punch-list> <nightshift-dir> — give every item under `## Items` that has no
# id a new one. Items that carry one keep it, so running this again changes nothing.
ns_punch_assign_ids() {
  local list="$1" ns="$2" need taken ids="" id tmp
  [ -f "$list" ] && [ ! -L "$list" ] || return 0
  need="$(awk "$NS_AWK_ITEM"'
    { line = $0; sub(/\r$/, "", line) }
    !on { if (line ~ /^##[[:space:]]*Items[[:space:]]*$/) on = 1; next }
    line ~ /^## / { exit }
    line ~ /^- \[[ xX]\]/ && ns_item_id(line) == "" { n++ }
    END { print n + 0 }
  ' "$list")" || return 1
  [ "$need" -gt 0 ] || return 0
  taken="$(ns_item_ids "$list" | paste -sd' ' -)"
  while [ "$need" -gt 0 ]; do
    id="$(ns_item_new_id "$ns" "$taken $ids")" || return 1
    ids="$ids $id"
    need=$((need - 1))
  done
  tmp="$list.ids.$$"
  awk -v ids="$ids" "$NS_AWK_ITEM"'
    BEGIN { split(ids, pool, " "); k = 0 }
    { line = $0; cr = ""; if (sub(/\r$/, "", line)) cr = "\r" }
    !on { if (line ~ /^##[[:space:]]*Items[[:space:]]*$/) on = 1; print; next }
    line ~ /^## / { on = 0; done = 1 }
    !done && line ~ /^- \[[ xX]\]/ && ns_item_id(line) == "" {
      k++
      print line " <!-- id: " pool[k] " -->" cr
      next
    }
    { print }
  ' "$list" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$list" || { rm -f "$tmp"; return 1; }
}

# ns_receipt_base <project-dir> <label> [id] — the item's receipt file stem under receipts/. An item
# with an id keeps the file that id already names, else an earlier shift's receipt found by its
# label, else a new `<id>-<slug>`; an item without one is its label's `NN-slug`. With no id
# argument the id is looked up in the punch list by label.
ns_receipt_base() {
  local project="$1" label="$2" id="${3-}" dir legacy f slug
  [ $# -ge 3 ] || id="$(ns_item_id_for "$project/.nightshift/punch-list.md" "$label")"
  legacy="$(ns_receipt_basename "$label")"
  [ -n "$id" ] || { printf '%s' "$legacy"; return 0; }
  dir="$(ns_receipts_dir "$project")"
  for f in "$dir/$id.md" "$dir/$id"-*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    f="${f##*/}"
    printf '%s' "${f%.md}"
    return 0
  done
  if [ -n "$legacy" ] && [ -f "$dir/$legacy.md" ] && [ ! -L "$dir/$legacy.md" ]; then
    printf '%s' "$legacy"
    return 0
  fi
  slug="$(ns_receipt_slug "$(ns_receipt_title "$label")")"
  if [ -n "$slug" ]; then printf '%s-%s' "$id" "$slug"; else printf '%s' "$id"; fi
}

# ns_receipt_path <project-dir> <label> [id] — the item's file under receipts/.
ns_receipt_path() {
  printf '%s/%s.md' "$(ns_receipts_dir "$1")" "$(ns_receipt_base "$@")"
}

# ns_active_item <project-dir> — the item being worked: the open item whose receipt the model
# wrote last, or the first open item while no open item has one. A receipt starts when substantive
# work on its item starts, and the runtime's own writes keep a receipt's time, so only the model's
# writing moves this. Two receipts written in the same instant go to the earlier item.
ns_active_item() {
  local punch="$1/.nightshift/punch-list.md" dir label id f cand best="" best_f="" first=""
  [ -f "$punch" ] || return 1
  dir="$(ns_receipts_dir "$1")"
  while IFS=$'\t' read -r label id; do
    [ -n "$label" ] || continue
    [ -n "$first" ] || first="$label"
    f=""
    if [ -n "$id" ]; then
      for cand in "$dir/$id.md" "$dir/$id"-*.md; do
        if [ -f "$cand" ] && [ ! -L "$cand" ]; then
          f="$cand"
          break
        fi
      done
    fi
    # A receipt named by label starts with the item's number; only when one might exist is the
    # exact name worked out, so the pulse that runs this on every tool call stays cheap.
    if [ -z "$f" ] && [[ "$label" =~ ^([0-9]+|[A-Za-z]+[0-9]+) ]]; then
      for cand in "$dir/${BASH_REMATCH[1]}.md" "$dir/${BASH_REMATCH[1]}"-*.md; do
        if [ -f "$cand" ]; then
          f="$dir/$(ns_receipt_basename "$label").md"
          break
        fi
      done
    elif [ -z "$f" ]; then
      f="$dir/$(ns_receipt_basename "$label").md"
    fi
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    if [ -z "$best_f" ] || [ "$f" -nt "$best_f" ]; then
      best="$label"
      best_f="$f"
    fi
  done <<EOF
$(ns_item_rows "$punch" open)
EOF
  printf '%s' "${best:-$first}"
}

# ns_receipt_track_label <receipt> <label> — note in the receipt which label it belongs to, and
# record a renumber or retitle once the item's label has moved since. The heading follows when it
# was the old label, and one dated line under it names what the item was called before.
#
# The runtime's writes to a receipt keep its modification time: the time says when the model last
# wrote it, which is how the pulse tells which item is being worked.
ns_receipt_track_label() {
  local f="$1" was tmp ref rc=0
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  was="$(sed -n 's/^<!-- item: \(.*\) -->[[:space:]]*$/\1/p' "$f" | tail -n1)"
  [ "$was" != "$2" ] || return 0
  ref="$f.mtime.$$"
  touch -r "$f" "$ref" 2>/dev/null || return 1
  if [ -z "$was" ]; then
    printf '\n<!-- item: %s -->\n' "$2" >>"$f" || rc=1
  else
    tmp="$f.track.$$"
    if NS_WAS="$was" NS_NOW="$2" NS_DAY="$(date +%Y-%m-%d)" awk '
      BEGIN { was = ENVIRON["NS_WAS"]; now = ENVIRON["NS_NOW"]; day = ENVIRON["NS_DAY"] }
      { line = $0; sub(/\r$/, "", line) }
      !headed && line ~ /^# / {
        headed = 1
        print (line == "# " was) ? "# " now : $0
        print ""
        print "Renamed from " was " on " day "."
        next
      }
      line ~ /^<!-- item: .* -->[[:space:]]*$/ { print "<!-- item: " now " -->"; next }
      { print }
    ' "$f" >"$tmp"; then
      mv "$tmp" "$f" || rc=1
    else
      rm -f "$tmp"
      rc=1
    fi
  fi
  touch -r "$ref" "$f" 2>/dev/null || rc=1
  rm -f "$ref"
  return "$rc"
}

# ns_receipt_add_session <receipt> <label> <shift-id> <start> <end> <working-sec> <input> <output>
# <ended> — add one session to the receipt's Sessions table and redraw it. The table is drawn from
# the data lines kept under it, so its totals stay exact across every shift the item was worked
# in. `-` is an unknown shift or an unreported token count; <ended> is ticked, switched-away,
# blocked or paused. A receipt that does not exist yet is created with its heading; one that does
# keeps its modification time.
ns_receipt_add_session() {
  local f="$1" label="$2" data line block ref tmp fresh=0 rc=0
  local sid start end work in out ended n=0 twork=0 tin=0 tout=0 havein=0 haveout=0 cell_in cell_out word
  [ ! -L "$f" ] || return 0
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  if [ ! -f "$f" ]; then
    printf '# %s\n' "$label" >"$f" || return 1
    fresh=1
  fi
  data="$(awk '/^<!-- session-data$/ { on = 1; next } on && /^-->$/ { on = 0 } on { print }' "$f")"
  data="$(printf '%s\n%s %s %s %s %s %s %s' "$data" "$3" "$4" "$5" "$6" "$7" "$8" "$9" | sed '/^$/d')"
  block="$(mktemp "${TMPDIR:-/tmp}/ns-sessions.XXXXXX")" || return 1
  {
    printf '<!-- sessions -->\n**Sessions**\n\n'
    printf '| # | Shift | Start | End | Working | Input | Output | Ended |\n'
    printf '| --- | --- | --- | --- | --- | ---: | ---: | --- |\n'
    while read -r sid start end work in out ended; do
      [ -n "$sid" ] || continue
      n=$((n + 1))
      case "$work" in '' | *[!0-9]*) work=0 ;; esac
      twork=$((twork + work))
      cell_in=unavailable
      cell_out=unavailable
      case "$in" in '' | *[!0-9]*) ;; *) tin=$((tin + in)); havein=1; cell_in="$(ns_usage_scale "$in")" ;; esac
      case "$out" in '' | *[!0-9]*) ;; *) tout=$((tout + out)); haveout=1; cell_out="$(ns_usage_scale "$out")" ;; esac
      [ "$sid" != - ] || sid='—'
      printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' "$n" "$(printf '%s' "$sid" | cut -c1-8)" \
        "$(ns_usage_iso "$start" || printf '—')" "$(ns_usage_iso "$end" || printf '—')" \
        "$(ns_usage_duration "$work")" "$cell_in" "$cell_out" "$(printf '%s' "$ended" | tr '-' ' ')"
    done <<EOF
$data
EOF
    word=sessions
    [ "$n" -ne 1 ] || word=session
    cell_in=unavailable
    cell_out=unavailable
    [ "$havein" -eq 0 ] || cell_in="$(ns_usage_scale "$tin")"
    [ "$haveout" -eq 0 ] || cell_out="$(ns_usage_scale "$tout")"
    printf '| **Total** | %s %s |  |  | **%s** | **%s** | **%s** |  |\n' \
      "$n" "$word" "$(ns_usage_duration "$twork")" "$cell_in" "$cell_out"
    printf '\n<!-- session-data\n%s\n-->\n<!-- /sessions -->\n' "$data"
  } >"$block"
  ref="$f.mtime.$$"
  [ "$fresh" -eq 1 ] || touch -r "$f" "$ref" 2>/dev/null || { rm -f "$block"; return 1; }
  tmp="$f.sessions.$$"
  if awk -v blockfile="$block" '
    function emit(   l) { while ((getline l < blockfile) > 0) print l; close(blockfile); done = 1 }
    /^<!-- sessions -->/ { skip = 1; emit(); next }
    skip && /^<!-- \/sessions -->/ { skip = 0; next }
    skip { next }
    { print }
    END { if (!done) { print ""; emit() } }
  ' "$f" >"$tmp"; then
    mv "$tmp" "$f" || rc=1
  else
    rm -f "$tmp"
    rc=1
  fi
  rm -f "$block"
  if [ "$fresh" -eq 0 ]; then
    touch -r "$ref" "$f" 2>/dev/null || rc=1
    rm -f "$ref"
  fi
  return "$rc"
}

# ns_receipt_has_model_text <file> — status 0 when a line exists outside the runtime block
# and the gate-written heading.
ns_receipt_has_model_text() {
  local f="$1"
  { [ -f "$f" ] && [ ! -L "$f" ]; } || return 1
  awk '
    /^[[:space:]]*$/ { next }
    /^# / { next }
    /^\*\*Usage:\*\*/ { next }
    /^\*\*Duration:\*\*/ { next }
    /^  Source:/ { next }
    /^  Cache reads/ { next }
    /^  The input figure/ { next }
    /^  Cached input/ { next }
    /^  Overlap between/ { next }
    /^\| Tokens \|/ { next }
    /^\| Time \|/ { next }
    /^\| ---/ { next }
    /^\| input \|/ { next }
    /^\| cache / { next }
    /^\| output \|/ { next }
    /^\| reasoning \|/ { next }
    /^\| working \|/ { next }
    /^\| paused \|/ { next }
    /^\| wall \|/ { next }
    /^\| span \|/ { next }
    /^<!-- sessions -->/ { sessions = 1; next }
    /^<!-- \/sessions -->/ { sessions = 0; next }
    sessions { next }
    /^<!-- tokens / { next }
    /^<!-- item: / { next }
    /^Renamed from .* on [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\.$/ { next }
    / · [0-9]+ segments?\./ { next }
    { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$f"
}

# ns_receipts_missing_nns <project> — one item number per ticked item with no model text.
ns_receipts_missing_nns() {
  local project="$1" punch ns label id base nn
  ns="$project/.nightshift"
  punch="$ns/punch-list.md"
  [ -f "$punch" ] || return 0
  ns_receipts_enabled "$project" || return 0
  ns_item_rows "$punch" ticked | while IFS=$'\t' read -r label id || [ -n "$label" ]; do
    [ -n "$label" ] || continue
    base="$(ns_receipt_base "$project" "$label" "$id")"
    ns_receipt_has_model_text "$ns/receipts/${base}.md" && continue
    nn="$(ns_receipt_nn "$label")"
    [ -n "$nn" ] || nn="$label"
    printf '%s\n' "$nn"
  done
}

ns_receipts_missing_count() {
  local n
  n="$(ns_receipts_missing_nns "$1" | grep -c . || true)"
  printf '%s' "${n:-0}"
}

# ns_usage_scale <n> — integer below 1000, then one decimal k, M, or B. Tenths are rounded half up
# on the exact integer, never through a binary fraction, so 1950 is 2.0k on every runtime; a value
# that rounds to 1000.0 of a unit reads as 1.0 of the next.
ns_usage_scale() {
  local n="$1"
  case "$n" in '' | *[!0-9]*) printf '%s' "$n"; return 0 ;; esac
  awk -v n="$n" 'BEGIN {
    if (n < 1000) { printf "%d", n; exit }
    split("1000 1000000 1000000000", unit, " ")
    split("k M B", suffix, " ")
    i = 1
    while (i < 3 && n >= unit[i + 1]) i++
    tenths = int((n * 10 + unit[i] / 2) / unit[i])
    if (tenths >= 10000 && i < 3) { i++; tenths = int((n * 10 + unit[i] / 2) / unit[i]) }
    printf "%d.%d%s", int(tenths / 10), tenths % 10, suffix[i]
  }'
}

# ns_receipts_shift_date <project-dir> — Date: on the punch list, else the policy day, else today.
ns_receipts_shift_date() {
  local punch="$1/.nightshift/punch-list.md" policy="$1/.nightshift/shift-policy.json" day
  if [ -f "$punch" ]; then
    day="$(sed -n 's/^Date:[[:space:]]*//p' "$punch" | head -n1)"
    day="${day%%[$'\r\n']*}"
    [ -n "$day" ] && { printf '%s' "$day"; return 0; }
  fi
  if [ -f "$policy" ]; then
    day="$(sed -n 's/.*"createdAt"[[:space:]]*:[[:space:]]*"\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p' "$policy" | head -n1)"
    [ -n "$day" ] && { printf '%s' "$day"; return 0; }
  fi
  date -u +%Y-%m-%d
}

# ns_receipt_usage_cells <file> — input, cache_write, cache_read, output, reasoning, work
# seconds, pause seconds, the named usage cell, and the time cell, tab separated. A receipt
# with no runtime block reads as zeros and dashes. An `x-<name>` sidecar is read when the
# item file itself has no exact line (the old tick-label bug).
ns_receipt_usage_cells() {
  local f="$1" dir base sidecar exact comment in=0 cw=0 cr=0 out=0 rea=0 tok_sum=0
  local usage='—' time='—' work=0 pause=0 raw work_s pause_s
  dir="${f%/*}"
  base="${f##*/}"
  if [ -f "$f" ] && { grep -q 'exact:' "$f" 2>/dev/null || grep -q '<!-- tokens ' "$f" 2>/dev/null; }; then
    :
  else
    sidecar="$dir/x-${base}"
    [ -f "$sidecar" ] && f="$sidecar"
  fi
  if [ -f "$f" ]; then
    comment="$(sed -n 's/^<!--[[:space:]]*tokens[[:space:]]\{1,\}\(.*\)-->/\1/p' "$f" | head -n1)"
    comment="${comment%"${comment##*[![:space:]]}"}"
    if [ -n "$comment" ]; then
      in="${comment%% *}"; comment="${comment#* }"
      cw="${comment%% *}"; comment="${comment#* }"
      cr="${comment%% *}"; comment="${comment#* }"
      out="${comment%% *}"; rea="${comment#* }"
      case "$in" in '' | *[!0-9]*) in=0 ;; esac
      case "$cw" in '' | *[!0-9]*) cw=0 ;; esac
      case "$cr" in '' | *[!0-9]*) cr=0 ;; esac
      case "$out" in '' | *[!0-9]*) out=0 ;; esac
      case "$rea" in '' | *[!0-9]*) rea=0 ;; esac
      tok_sum=$((in + out))
      usage="input $(ns_usage_scale "$in") · cache_write $(ns_usage_scale "$cw") · cache_read $(ns_usage_scale "$cr") · output $(ns_usage_scale "$out") · reasoning $(ns_usage_scale "$rea")"
    else
      exact="$(sed -n 's/.*exact:[[:space:]]*\([0-9][0-9]* \/ [0-9][0-9]* \/ [0-9][0-9]* \/ [0-9][0-9]* \/ [0-9][0-9]*\).*/\1/p' "$f" | head -n1)"
      if [ -n "$exact" ]; then
        in="${exact%% /*}"; exact="${exact#* / }"
        cw="${exact%% /*}"; exact="${exact#* / }"
        cr="${exact%% /*}"; exact="${exact#* / }"
        out="${exact%% /*}"; rea="${exact#* / }"
        tok_sum=$((in + out))
        usage="input $(ns_usage_scale "$in") · cache_write $(ns_usage_scale "$cw") · cache_read $(ns_usage_scale "$cr") · output $(ns_usage_scale "$out") · reasoning $(ns_usage_scale "$rea")"
      fi
    fi
    work_s="$(sed -n 's/^| working |[[:space:]]*//p' "$f" | head -n1)"
    if [ -n "$work_s" ]; then
      work_s="${work_s%% |*}"
      work_s="${work_s%"${work_s##*[![:space:]]}"}"
      work="$(ns_usage_parse_seconds "$work_s")"
      pause_s="$(sed -n 's/^| paused |[[:space:]]*//p' "$f" | head -n1)"
      if [ -n "$pause_s" ]; then
        pause_s="${pause_s%% |*}"
        pause_s="${pause_s%%(*}"
        pause_s="${pause_s%"${pause_s##*[![:space:]]}"}"
        pause="$(ns_usage_parse_seconds "$pause_s")"
      fi
      time="$(ns_receipts_time_cell "$work" "$pause")"
    else
      raw="$(sed -n 's/^\*\*Duration:\*\*[[:space:]]*//p' "$f" | head -n1)"
      if [ -n "$raw" ]; then
        case "$raw" in
          *' working'*) work_s="${raw%% working*}" ;;
          *' ('*) work_s="${raw%% (*}" ;;
          *) work_s="$raw" ;;
        esac
        work_s="${work_s%"${work_s##*[![:space:]]}"}"
        work="$(ns_usage_parse_seconds "$work_s")"
        case "$raw" in
          *' paused '*)
            pause_s="${raw#* paused }"
            pause_s="${pause_s%%,*}"
            pause_s="${pause_s%%)*}"
            pause_s="${pause_s%"${pause_s##*[![:space:]]}"}"
            pause="$(ns_usage_parse_seconds "$pause_s")"
            ;;
        esac
        time="$(ns_receipts_time_cell "$work" "$pause")"
      fi
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$in" "$cw" "$cr" "$out" "$rea" "$work" "$pause" "$usage" "$time" "$tok_sum"
}

# ns_usage_parse_seconds <1h 25m|11m 35s|45s> — integer seconds, or 0.
ns_usage_parse_seconds() {
  local t="$1" h=0 m=0 s=0
  h="$(printf '%s' "$t" | grep -Eo '[0-9]+h' | head -n1 | tr -d h)"
  m="$(printf '%s' "$t" | grep -Eo '[0-9]+m' | head -n1 | tr -d m)"
  s="$(printf '%s' "$t" | grep -Eo '[0-9]+s' | head -n1 | tr -d s)"
  case "$h" in '' | *[!0-9]*) h=0 ;; esac
  case "$m" in '' | *[!0-9]*) m=0 ;; esac
  case "$s" in '' | *[!0-9]*) s=0 ;; esac
  printf '%s' "$((h * 3600 + m * 60 + s))"
}

# ns_receipts_index_head <date> — the title and column headers of an index page.
ns_receipts_index_head() {
  printf '# Receipts — %s\n\n' "$1"
  printf '| Item | State | **Usage** | **Time** | Receipt |\n'
  printf '| --- | --- | --- | --- | --- |\n'
}
# ns_receipts_index_totals <usage-cell> <time-cell> — the closing totals row of an index page.
ns_receipts_index_totals() {
  printf '| **Totals** |  | **%s** | **%s** |  |\n' "${1:-—}" "${2:-—}"
}

ns_receipts_usage_total_cell() {
  local in="$1" cw="$2" cr="$3" out="$4" rea="$5"
  if [ "$((in + cw + cr + out + rea))" -eq 0 ]; then
    printf '%s' '—'
    return 0
  fi
  printf 'input %s · cache_write %s · cache_read %s · output %s · reasoning %s' \
    "$(ns_usage_scale "$in")" "$(ns_usage_scale "$cw")" "$(ns_usage_scale "$cr")" \
    "$(ns_usage_scale "$out")" "$(ns_usage_scale "$rea")"
}

ns_receipts_time_cell() {
  local work="${1:-0}" pause="${2:-0}"
  case "$work" in '' | *[!0-9]*) work=0 ;; esac
  case "$pause" in '' | *[!0-9]*) pause=0 ;; esac
  if [ "$work" -eq 0 ] && [ "$pause" -eq 0 ]; then
    printf '%s' '—'
    return 0
  fi
  if [ "$pause" -gt 0 ]; then
    printf '%s working · %s paused' "$(ns_usage_duration "$work")" "$(ns_usage_duration "$pause")"
    return 0
  fi
  printf '%s working' "$(ns_usage_duration "$work")"
}

ns_receipts_time_total_cell() {
  ns_receipts_time_cell "${1:-0}" "${2:-0}"
}

# ns_receipts_item_names <project-dir> <open|ticked> — receipt file names for boxes in that state.
# A ticked item's receipt leaves live storage once the shift has ended; an open item's stays, so
# the next shift writes into the same file.
ns_receipts_item_names() {
  local punch="$1/.nightshift/punch-list.md" state="${2:-open}" label id
  [ -f "$punch" ] || return 0
  [ "$state" = ticked ] || state=open
  ns_item_rows "$punch" "$state" | while IFS=$'\t' read -r label id || [ -n "$label" ]; do
    [ -n "$label" ] || continue
    printf '%s.md\n' "$(ns_receipt_base "$1" "$label" "$id")"
  done
}

ns_receipts_open_names() { ns_receipts_item_names "$1" open; }
ns_receipts_ticked_names() { ns_receipts_item_names "$1" ticked; }

# ns_receipts_item_order — receipt paths on stdin, printed in item order: numbered items by value
# (1, 2, 10), then letter-and-number ids by letters and value (A1, A2, A10, B1), then the rest by
# name. Keys are tab-separated and compared bytewise, so tab ends a shorter field first.
ns_receipts_item_order() {
  LC_ALL=C awk "$NS_AWK_ORDER_KEY"'
    { n = $0; sub(/.*\//, "", n); print ns_order_key(n) "\t" $0 }
  ' | LC_ALL=C sort | cut -f5-
}

# ns_receipts_heading_order — `<heading>\t<path>` lines on stdin, printed in the item order of the
# headings. A receipt named for its item's id sorts by the number and title its heading shows.
ns_receipts_heading_order() {
  LC_ALL=C awk -F'\t' "$NS_AWK_ORDER_KEY"'
    { print ns_order_key($1) "\t" $0 }
  ' | LC_ALL=C sort | cut -f5-
}

# The item-order key of one name, as four tab-separated fields, for the two orderings above.
NS_AWK_ORDER_KEY='
function ns_order_key(n,    cls, pre, num, id) {
  cls = 2; pre = ""; num = ""
  if (match(n, /^[0-9]+/)) {
    cls = 0; num = substr(n, 1, RLENGTH)
  } else if (match(n, /^[A-Za-z]+[0-9]+/)) {
    id = substr(n, 1, RLENGTH)
    match(id, /[0-9]+$/)
    cls = 1; pre = tolower(substr(id, 1, RSTART - 1)); num = substr(id, RSTART)
  }
  sub(/^0+/, "", num)
  if (cls < 2 && num == "") num = "0"
  return sprintf("%d\t%s\t%04d%s\t%s", cls, pre, length(num), num, n)
}
'

# _ns_archive_receipt_headings <dir> — `<heading>\t<path>` for each item receipt filed in <dir>.
_ns_archive_receipt_headings() {
  local f label
  find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | while IFS= read -r f; do
    { [ -f "$f" ] && [ ! -L "$f" ]; } || continue
    case "${f##*/}" in
      README.md | morning-* | x-* | *.original.md) continue ;;
    esac
    label="$(sed -n 's/^# //p' "$f" | head -n1)"
    label="${label%$'\r'}"
    [ -z "$label" ] || printf '%s\t%s\n' "$label" "$f"
  done
}

# ns_receipts_write_archive_index <dir> <date> — the index of the item receipts filed in <dir>,
# written only when at least one landed there. Links stay siblings, because the receipts it lists
# are in that directory too.
ns_receipts_write_archive_index() {
  local dir="$1" date_s="$2" index rows f base label cells
  local in cw cr out rea work pause usage time _sum
  local tin=0 tcw=0 tcr=0 tout=0 trea=0 twork=0 tpause=0
  { [ -d "$dir" ] && [ ! -L "$dir" ]; } || return 0
  index="$dir/README.md"
  [ -L "$index" ] && return 0
  rows="$(mktemp "${TMPDIR:-/tmp}/ns-archive-index.XXXXXX")" || return 0
  : >"$rows"
  while IFS=$'\t' read -r label f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    cells="$(ns_receipt_usage_cells "$f")"
    IFS=$'\t' read -r in cw cr out rea work pause usage time _sum <<EOF
$cells
EOF
    tin=$((tin + in)); tcw=$((tcw + cw)); tcr=$((tcr + cr))
    tout=$((tout + out)); trea=$((trea + rea)); twork=$((twork + work)); tpause=$((tpause + pause))
    printf '| %s | ticked | **%s** | **%s** | [./%s](./%s) |\n' \
      "$label" "$usage" "$time" "$base" "$base" >>"$rows"
  done <<FIND
$(_ns_archive_receipt_headings "$dir" | ns_receipts_heading_order)
FIND
  if [ ! -s "$rows" ]; then
    rm -f "$rows"
    return 0
  fi
  {
    ns_receipts_index_head "$date_s"
    cat "$rows"
    ns_receipts_index_totals "$(ns_receipts_usage_total_cell "$tin" "$tcw" "$tcr" "$tout" "$trea")" \
      "$(ns_receipts_time_total_cell "$twork" "$tpause")"
  } >"$index" 2>/dev/null || :
  rm -f "$rows"
}

# ns_receipts_write_index <project-dir> [remaining] — rewrite receipts/README.md from the list,
# marks, files. `remaining` writes the index a live receipts folder still needs — every open item
# and every ticked item whose receipt is still there — and removes it when nothing is left.
ns_receipts_write_index() {
  local project="$1" mode="${2:-}" punch="$1/.nightshift/punch-list.md"
  local dir index date_s state base file cells
  local in cw cr out rea work pause usage time _sum
  local tin=0 tcw=0 tcr=0 tout=0 trea=0 twork=0 tpause=0
  local label id items rows
  dir="$(ns_receipts_dir "$project")"
  [ -n "$dir" ] || return 0
  if [ "$mode" = remaining ]; then
    [ -d "$dir" ] || return 0
  else
    mkdir -p "$dir" 2>/dev/null || return 0
  fi
  [ ! -L "$dir" ] || return 0
  index="$dir/README.md"
  [ -L "$index" ] && return 0
  date_s="$(ns_receipts_shift_date "$project")"
  items="$(mktemp "${TMPDIR:-/tmp}/ns-receipts-index.XXXXXX")" || return 0
  rows="$(mktemp "${TMPDIR:-/tmp}/ns-receipts-rows.XXXXXX")" || { rm -f "$items"; return 0; }
  : >"$items"
  if [ -f "$punch" ]; then
    ns_items_section "$punch" 2>/dev/null | awk "$NS_AWK_ITEM"'
      /^- \[[ xX]\] / {
        label = ns_item_label($0)
        if (label != "") print (($0 ~ /^- \[ \]/) ? "open" : "ticked") "\t" label "\t" ns_item_id($0)
      }
    ' >"$items" || :
  fi
  : >"$rows"
  while IFS=$'\t' read -r state label id || [ -n "$state" ]; do
    [ -n "$label" ] || continue
    base="$(ns_receipt_base "$project" "$label" "$id")"
    if [ "$mode" = remaining ] && [ "$state" = ticked ] && [ ! -f "$dir/${base}.md" ]; then
      continue
    fi
    file="./${base}.md"
    cells="$(ns_receipt_usage_cells "$dir/${base}.md")"
    IFS=$'\t' read -r in cw cr out rea work pause usage time _sum <<EOF
$cells
EOF
    tin=$((tin + in)); tcw=$((tcw + cw)); tcr=$((tcr + cr))
    tout=$((tout + out)); trea=$((trea + rea)); twork=$((twork + work)); tpause=$((tpause + pause))
    printf '| %s | %s | **%s** | **%s** | [%s](%s) |\n' \
      "$label" "$state" "$usage" "$time" "$file" "$file" >>"$rows"
  done <"$items"
  if [ "$mode" = remaining ] && [ ! -s "$rows" ]; then
    rm -f "$index" "$items" "$rows"
    return 0
  fi
  {
    ns_receipts_index_head "$date_s"
    cat "$rows"
    ns_receipts_index_totals "$(ns_receipts_usage_total_cell "$tin" "$tcw" "$tcr" "$tout" "$trea")" \
      "$(ns_receipts_time_total_cell "$twork" "$tpause")"
  } >"$index" 2>/dev/null || :
  rm -f "$items" "$rows"
}

# ns_migrate_receipts_layout <workspace> — report→receipts; shift-report.md → previous-report.md.
# Idempotent. Does not bump state-version. Leaves timestamp-named receipt files untouched.
ns_migrate_receipts_layout() {
  local ws="$1" ns="$1/.nightshift" rules policy report dest dir tmp
  [ -d "$ns" ] || return 0
  for rules in "$ns/rules.json" "$ns/shift-policy.json"; do
    { [ -f "$rules" ] && [ ! -L "$rules" ]; } || continue
    if grep -q '"report"' "$rules" 2>/dev/null; then
      tmp="$rules.receipts-mig.$$"
      if command -v jq >/dev/null 2>&1; then
        jq 'if has("report") then
              .receipts = ((.receipts // .report) | del(.legacyItemReceipts))
              | del(.report)
            else . end' "$rules" >"$tmp" 2>/dev/null && mv "$tmp" "$rules"
      elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as f:
    d = json.load(f)
if "report" in d:
    src = dict(d.get("receipts") or d["report"])
    src.pop("legacyItemReceipts", None)
    d["receipts"] = src
    del d["report"]
    with open(p, "w", encoding="utf-8") as o:
        json.dump(d, o, indent=2, ensure_ascii=False)
        o.write("\n")
' "$rules" 2>/dev/null || rm -f "$tmp"
      fi
      rm -f "$tmp"
    fi
  done
  report="$ns/shift-report.md"
  dir="$ns/receipts"
  dest="$dir/previous-report.md"
  if [ -f "$report" ] && [ ! -L "$report" ]; then
    mkdir -p "$dir" 2>/dev/null || return 0
    if [ ! -e "$dest" ]; then
      mv "$report" "$dest" 2>/dev/null || :
    fi
  fi
}

# ns_archive <project-dir> <field> — one field of the archive block, or empty.
ns_archive() {
  ns_policy_pref "$1" archive "$2"
}

# The ending marker carries what filing still needs after the live policy has moved.
#
# Clock-out archives the policy, and a later Archive would then have no shift id to name a
# directory after and no frozen archive settings to file into — so one shift's records could land
# half under its own name and half under a date, and an owner edit between the two would move the
# destination. The marker that already says the shift ended says which shift, and where it files.
# One line per field, `key=value`, and an empty marker stays a valid ending.
#
# ns_ended_record <state-dir> <shift-id> <archive-root-name> <archive-layout>
ns_ended_record() {
  local ns="$1"
  [ -d "$ns" ] || return 0
  [ -L "$ns/.ended" ] && rm -f "$ns/.ended"
  printf 'shiftId=%s\narchiveRoot=%s\narchiveLayout=%s\n' "$2" "$3" "$4" >"$ns/.ended" 2>/dev/null || :
}

# ns_ended_field <project-dir> <key> — one field of the ending marker, or empty.
ns_ended_field() {
  local f="$1/.nightshift/.ended"
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  sed -n "s/^$2=//p" "$f" 2>/dev/null | head -n1
}

# ns_state_path <state-dir> <relative-name> — a nested path under the Nightshift state area, or
# status 2. The whole chain is checked, not just its last component: a link anywhere along it is
# what an escape actually looks like, because `linked/history` reaches outside while `history` is
# an ordinary directory nobody would question.
#
# Refused: an absolute or ~ path, any component that is empty, `.`, `..` or begins with a dot,
# an existing component that is a symlink, an existing component that is not a directory, and the
# state directory itself. Then the deepest ancestor that exists is canonicalised and checked to
# be the state directory or inside it — comparing the real paths rather than trusting that the
# text of one is a prefix of the other.
ns_state_path() {
  local ns="$1" rel="$2" path comp rest deepest canon_ns canon_deep
  case "$rel" in
    '' | . | /* | '~'*) return 2 ;;
  esac
  path="$ns"
  deepest="$ns"
  rest="$rel"
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
    case "$comp" in
      '' | .*) return 2 ;;
    esac
    path="$path/$comp"
    [ ! -L "$path" ] || return 2
    if [ -e "$path" ]; then
      [ -d "$path" ] || return 2
      deepest="$path"
    fi
  done
  canon_ns="$(cd -P "$ns" 2>/dev/null && pwd -P)" || return 2
  canon_deep="$(cd -P "$deepest" 2>/dev/null && pwd -P)" || return 2
  case "$canon_deep" in
    "$canon_ns" | "$canon_ns"/*) ;;
    *) return 2 ;;
  esac
  printf '%s' "$path"
}

# ns_archive_root <project-dir> — the directory dated archives live in, as an absolute path.
# The name is the owner's; where it may sit is not. It stays inside the Nightshift state area,
# and a request to leave it is refused with status 2 so the caller says so rather than writing
# the owner's records somewhere they cannot find them. Writing outside the state area is an
# unsupported request, not a setting.
ns_archive_root() {
  local ns="$1/.nightshift" name
  name="$(ns_archive "$1" root)"
  [ -n "$name" ] || name=archive
  # The live records are not an archive destination: filing into them would file a shift on top
  # of the shift that is still running.
  case "$name" in
    receipts | receipts/*) return 2 ;;
  esac
  ns_state_path "$ns" "$name" || return 2
}

# ns_archive_dest <path> — status 0 when one file may be written at that exact path. A directory
# containment check says nothing about the leaf: a link left where a receipt is about to land
# would still carry its bytes somewhere else.
ns_archive_dest() {
  [ ! -L "$1" ] || return 2
  [ ! -e "$1" ] || [ -f "$1" ] || return 2
}

# ns_archive_dir <project-dir> <date> <shift-id> — the directory one shift is filed into.
# The date layout groups a night together; the shift layout gives each shift its own directory.
# The shift id names the files inside either way, so two shifts on one day never collide.
ns_archive_dir() {
  local root layout
  root="$(ns_archive_root "$1")" || return 2
  layout="$(ns_archive "$1" layout)"
  if [ "$layout" = shift ] && [ -n "$3" ] && [ "$3" != unknown ]; then
    printf '%s/shift-%s' "$root" "$3"
    return 0
  fi
  printf '%s/%s' "$root" "$2"
}

# ns_archive_automatic <project-dir> — status 0 when the owner asked for filing at clock-out.
# Filing is a copy; it never implies deleting anything.
ns_archive_automatic() {
  [ "$(ns_archive "$1" automatic)" = true ]
}

# ns_review_handled <text> — status 0 when the entry carries a filing disposition.
ns_review_handled() {
  printf '%s\n' "$1" | grep -qiE ' · (fixed|ignored|answered|rejected-because|accepted-tradeoff)( ·|$)'
}

# ns_archive_review_label <date> <shift-id> <layout>
ns_archive_review_label() {
  if [ "$3" = shift ] && [ -n "$2" ] && [ "$2" != unknown ]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

# ns_archive_review_dest <project> <date> <shift-id> <basename>
# Date layout names the file with the shift so two nights on one day stay distinct.
ns_archive_review_dest() {
  local group layout
  group="$(ns_archive_dir "$1" "$2" "$3")" || return 2
  layout="$(ns_archive "$1" layout)"
  if [ "$layout" != shift ] && [ -n "$3" ] && [ "$3" != unknown ]; then
    printf '%s/%s/%s' "$group" "$3" "$4"
    return 0
  fi
  printf '%s/%s' "$group" "$4"
}

# ns_archive_pointer_line <label> <relpath>
ns_archive_pointer_line() {
  printf 'Filed: [%s](%s)' "$1" "$2"
}

# ns_archive_rel_from_ns <nightshift-dir> <absolute-dest>
ns_archive_rel_from_ns() {
  local ns="$1" dest="$2"
  printf '%s' "${dest#"$ns"/}"
}

# ns_archive_file_review_source <project> <basename> <date> <shift-id>
# Moves handled entries from the live review file into the archive dest and appends one pointer.
ns_archive_file_review_source() {
  local project="$1" base="$2" date="$3" shift_id="$4"
  local ns live dest label rel layout tmp filed ptr title
  ns="$project/.nightshift"
  live="$ns/$base"
  [ -f "$live" ] && [ ! -L "$live" ] || return 0
  dest="$(ns_archive_review_dest "$project" "$date" "$shift_id" "$base")" || return 2
  layout="$(ns_archive "$project" layout)"
  label="$(ns_archive_review_label "$date" "$shift_id" "$layout")"
  rel="$(ns_archive_rel_from_ns "$ns" "$dest")"
  case "$rel" in
    '' | /*) return 2 ;;
  esac
  tmp="$(mktemp)" || return 2
  filed="$(mktemp)" || {
    rm -f "$tmp"
    return 2
  }
  awk -v filed="$filed" '
    function handled(s) {
      t = tolower(s)
      return t ~ / · (fixed|ignored|answered|rejected-because|accepted-tradeoff)/
    }
    function flush() {
      if (buf == "") return
      if (handled(buf)) printf "%s\n", buf >> filed
      else printf "%s\n", buf
      buf = ""
    }
    /^Filed:/ { flush(); print; next }
    /^- Filed:/ { flush(); print; next }
    /^- / { flush(); buf = $0; next }
    /^# / { flush(); print; next }
    {
      if (buf != "") buf = buf "\n" $0
      else print
    }
    END { flush() }
  ' "$live" >"$tmp" || {
    rm -f "$tmp" "$filed"
    return 2
  }
  if [ ! -s "$filed" ]; then
    rm -f "$tmp" "$filed"
    return 0
  fi
  if ! ns_archive_dest "$dest"; then
    rm -f "$tmp" "$filed"
    return 2
  fi
  mkdir -p "${dest%/*}" || {
    rm -f "$tmp" "$filed"
    return 2
  }
  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    printf '\n' >>"$dest"
    cat "$filed" >>"$dest"
  else
    if [ "$base" = snag-log.md ]; then
      title='# Snag Log'
    else
      title='# Parking Lot'
    fi
    printf '%s\n\n' "$title" >"$dest"
    cat "$filed" >>"$dest"
  fi
  ptr="$(ns_archive_pointer_line "$label" "$rel")"
  if ! grep -qxF "$ptr" "$tmp"; then
    printf '\n%s\n' "$ptr" >>"$tmp"
  fi
  mv "$tmp" "$live" || {
    rm -f "$tmp" "$filed"
    return 2
  }
  rm -f "$filed"
  return 0
}

# ns_archive_check_review_pointers <project> — one snag per missing Filed: target.
ns_archive_check_review_pointers() {
  local project="$1" ns live dest rel line snag
  ns="$project/.nightshift"
  snag="$ns/snag-log.md"
  for live in "$ns/snag-log.md" "$ns/parking-lot.md"; do
    { [ -f "$live" ] && [ ! -L "$live" ]; } || continue
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\n' "$line" | grep -qE '^Filed: \[[^]]+\]\([^)]+\)$' || continue
      rel="${line#*']('}"
      rel="${rel%')'}"
      [ -n "$rel" ] || continue
      dest=""
      case "$rel" in
        /* | *..*) dest="" ;;
        *) dest="$ns/$rel" ;;
      esac
      if [ -n "$dest" ] && [ -f "$dest" ] && [ ! -L "$dest" ]; then
        continue
      fi
      if [ -f "$snag" ] && grep -qF "broken archive pointer · $rel " "$snag"; then
        continue
      fi
      if [ ! -f "$snag" ]; then
        printf '# Snag Log\n\n' >"$snag" || return 2
      fi
      printf -- '- broken archive pointer · %s is not a readable file\n' "$rel" >>"$snag"
    done <"$live"
  done
  return 0
}

# ns_archive_file_review_records <project> <date> <shift-id>
ns_archive_file_review_records() {
  ns_archive_file_review_source "$1" snag-log.md "$2" "$3" || return $?
  ns_archive_file_review_source "$1" parking-lot.md "$2" "$3" || return $?
  ns_archive_check_review_pointers "$1"
}

# ns_handoff <project-dir> <field> — one field of the handoff block, or empty when the file says
# nothing. Presentation only: none of it decides whether a check ran.
ns_handoff() {
  ns_policy_pref "$1" handoff "$2"
}

# ns_handoff_enabled <project-dir> — status 0 unless the owner turned the page off. A shift that
# writes no page still keeps every factual record it made.
ns_handoff_enabled() {
  [ "$(ns_handoff "$1" enabled)" != false ]
}

# ns_handoff_view <project-dir> — the configured reader, or owner.
ns_handoff_view() {
  local v
  v="$(ns_handoff "$1" view)"
  case "$v" in
    owner | reviewer | release | artifact) printf '%s' "$v" ;;
    *) printf 'owner' ;;
  esac
}

# ns_recovery_launch_scope <project-dir> — the permission scope a revived session starts under.
# host-grant is the documented grant for the host; host-default adds no permission argument and
# takes whatever the host gives. Anything else, or an unreadable file, is host-grant: recovery
# keeps working, and the scope in force is logged either way. The watchman never widens it.
ns_recovery_launch_scope() {
  local v=""
  if [ -n "${NIGHTSHIFT_LAUNCH_SCOPE:-}" ]; then
    v="$NIGHTSHIFT_LAUNCH_SCOPE"
  else
    v="$(ns_policy_pref "$1" recovery launchScope)"
  fi
  case "$v" in
    host-default) printf 'host-default' ;;
    host-grant) printf 'host-grant' ;;
    *) printf 'inherit-recorded-scope' ;;
  esac
}

# ns_policy_host_name — which host this session is, from what the host itself sets.
ns_policy_host_name() {
  if [ -n "${CURSOR_PLUGIN_ROOT:-}" ]; then
    printf 'cursor'
  elif [ -n "${CODEX_PROJECT_DIR:-}${CODEX_SANDBOX:-}${CODEX_SANDBOX_MODE:-}" ]; then
    printf 'codex'
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}${CLAUDE_PROJECT_DIR:-}" ]; then
    printf 'claude'
  else
    printf 'unknown'
  fi
}

# ns_launch_scope_supported <host> <scope> — true when the host can actually be asked to start a
# session at that scope. A recorded scope is only useful if a revival can name it on the command
# line, so this is the vocabulary the watchmen are allowed to pass through, and nothing else
# reaches a native flag.
ns_launch_scope_supported() {
  case "$1" in
    codex)
      case "$2" in
        read-only | workspace-write | danger-full-access) return 0 ;;
      esac
      ;;
    claude)
      case "$2" in
        dangerously-skip-permissions | bypass-permissions) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# A recorded observed scope that host-default cannot reproduce.
ns_launch_scope_elevated() {
  case "$1" in
    danger-full-access | workspace-write | dangerously-skip-permissions | bypass-permissions | bypassPermissions)
      return 0
      ;;
  esac
  return 1
}

# ns_launch_observed <host> — the execution scope this session is running under, in the host's own
# words, and whether the host actually told us. Read only from what the host already exposes; a
# scope nobody reported is unavailable, never assumed.
#
# Only Codex names a session's sandbox, and only in its own environment. Claude Code and Cursor
# hand a session its permissions at launch and expose no name for them anywhere a hook can read,
# so there is nothing to observe and this says so. Calling that 'inherited' would have been a
# label for a measurement never taken.
_ns_scan_process_scope() {
  local pid="$1" hops=0 args
  while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ] && [ "$hops" -lt 16 ]; do
    args="$(ps -o args= -p "$pid" 2>/dev/null)" || break
    case "$args" in
      *dangerously-skip-permissions* | *bypass-permissions*)
        printf '%s\tobserved' 'dangerously-skip-permissions'
        return 0
        ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    hops=$((hops + 1))
  done
  return 1
}

ns_launch_observed() {
  case "$1" in
    codex)
      if [ -n "${CODEX_SANDBOX_MODE:-}" ]; then
        printf '%s\tobserved' "$CODEX_SANDBOX_MODE"
        return 0
      fi
      if [ -n "${CODEX_SANDBOX:-}" ]; then
        printf '%s\tobserved' "$CODEX_SANDBOX"
        return 0
      fi
      ;;
    claude | cursor)
      if [ -n "${CLAUDE_PROJECT_DIR:-}${CLAUDE_PLUGIN_ROOT:-}${CURSOR_PLUGIN_ROOT:-}" ] \
        && _ns_scan_process_scope "$$"; then
        return 0
      fi
      ;;
  esac
  printf 'unknown\tunavailable'
}

# ns_recovery_effective_scope <project-dir> <host> — what a revival may actually ask for.
#
# The shipped choice inherits the scope the shift was started under, so recovery reproduces the
# session rather than improving on it. Nothing here ever widens what the original session had — an
# owner who wants the documented broad grant writes host-grant in their own file, and that is the
# only way it happens.
#
# There are four answers, and the caller logs the one it got:
#
#   host-default      the owner asked for it, or no scope was ever recorded. No permission
#                     argument is passed and the host decides. This is the baseline, not a proof
#                     that it is narrower than the original session — no host reports enough for
#                     that claim, and it is not made.
#   host-grant        the owner wrote it by name. Only ever from their own file.
#   recorded:<scope>  the shift recorded a scope the host observed and can be asked for again.
#   unavailable:<s>   a scope was recorded that this host has no way to request. A revival would
#                     run at some other scope, so the caller refuses rather than guess.
ns_recovery_effective_scope() {
  local configured recorded provenance
  configured="$(ns_recovery_launch_scope "$1")"
  case "$configured" in
    host-grant)
      printf 'host-grant'
      return 0
      ;;
    host-default)
      _ns_policy_load_shift "$1"
      case "$NS_POLICY_SHIFT_STATE" in
        ok)
          recorded="$(ns_policy_launch "$1" scope 2>/dev/null)" || recorded=""
          provenance="$(ns_policy_launch "$1" provenance 2>/dev/null)" || provenance=""
          if [ "$provenance" = observed ] && [ -n "$recorded" ] && ns_launch_scope_elevated "$recorded"; then
            printf 'unavailable:narrower:%s' "$recorded"
            return 0
          fi
          ;;
      esac
      printf 'host-default'
      return 0
      ;;
  esac
  _ns_policy_load_shift "$1"
  case "$NS_POLICY_SHIFT_STATE" in
    ok) ;;
    absent)
      printf 'unavailable:unrecorded'
      return 0
      ;;
    *)
      printf 'unavailable:unreadable'
      return 0
      ;;
  esac
  recorded="$(ns_policy_launch "$1" scope 2>/dev/null)" || recorded=""
  provenance="$(ns_policy_launch "$1" provenance 2>/dev/null)" || provenance=""
  if [ "$provenance" = observed ] && [ -n "$recorded" ] && [ "$recorded" != unknown ]; then
    if ns_launch_scope_supported "$2" "$recorded"; then
      printf 'recorded:%s' "$recorded"
    else
      printf 'unavailable:unsupported:%s' "$recorded"
    fi
    return 0
  fi
  printf 'unavailable:unrecorded'
}

# ns_recovery_refusal <effective-scope> — the one sentence that says why a revival is refused.
# Status 1 for a scope that is not a refusal.
ns_recovery_refusal() {
  case "$1" in
    unavailable:unrecorded)
      printf 'the host named no scope for the session this shift was started in, so there is nothing to inherit and no way to show a revival would be no broader'
      ;;
    unavailable:unreadable)
      printf 'the policy that records the launch scope cannot be read, so what this shift was started under is unknown'
      ;;
    unavailable:unsupported:*)
      printf "the shift was started under '%s', which this host has no way to be asked for again" "${1#unavailable:unsupported:}"
      ;;
    unavailable:narrower:*)
      printf "the shift was started under '%s', so a host-default revival would be too narrow" "${1#unavailable:narrower:}"
      ;;
    *) return 1 ;;
  esac
}

# toolDeny requires exact key matching. The shipped reader accepts the template's
# object-of-strings shape and nothing else. Malformed input fails closed.
ns_tool_map_ok() { # stdin = a JSON object of string values
  local raw
  raw="$(cat)"
  ns_rules_map_parse "$raw" || return 1
  printf '%s' "$raw"
}

ns_tool_rules() { # $1 = project dir, $2 = session override
  local f="$1/.nightshift/rules.json" raw
  if [ -n "$2" ]; then
    raw="$2"
    ns_rules_map_parse "$raw" || {
      printf '%s' '__nightshift_invalid_tool_rules__'
      return
    }
    printf '%s' "$raw"
    return
  fi
  [ -f "$f" ] || return 0
  ns_rules_load "$f" || {
    printf '%s' '__nightshift_invalid_tool_rules__'
    return
  }
  ns_rules_tool_deny_json "$f"
}

# The punch list's `## Items` heading is the boundary between the owner's contract and the work.
# A checkbox above it is prose — an example, a note — and holds nobody. Both the gate and the
# watchman must agree on that boundary: a watchman counting a different range would keep reviving
# a shift the gate considers finished. One implementation is how they cannot disagree.
ns_items_section() { sed -n '/^## Items[[:space:]]*$/,$p' "$1" 2>/dev/null; }

# A count is a verdict about how much work is open, so it is either a number or a failure —
# never a silent zero. An absent list is the one honest zero: there is no work because there is
# no list. Everything else that can go wrong — the file exists but cannot be read, sed or grep is
# missing from a stripped PATH, the ERE is rejected — returns non-zero and prints nothing, and
# callers hold the site armed and the gate shut on that.
#
# grep -c prints the count AND exits 1 on zero matches, so status 1 is a real answer here and
# only status 2 and up is an error. The pipeline is split so the reader's status is its own.
ns_count_boxes() { # $1 = punch list, $2 = ERE for the box state
  local section n rc
  [ -e "$1" ] || { printf '0'; return 0; }
  [ -r "$1" ] || return 1
  section="$(ns_items_section "$1")" || return 1
  n="$(printf '%s\n' "$section" | grep -cE "$2" 2>/dev/null)"
  rc=$?
  [ "$rc" -le 1 ] || return 1
  case "$n" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$n"
}

ns_open_boxes()   { ns_count_boxes "$1" '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]'; }
ns_ticked_boxes() { ns_count_boxes "$1" '^[[:space:]]*-[[:space:]]*\[[xX]\]'; }

# Work orders have no ## Items heading. Count every top-level open box in the file.
ns_open_boxes_file() {
  local n
  n="$(grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' "$1" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# Drafting table: the fenced item-shape example sits above the first --- rule.
ns_open_drafts() {
  [ -f "$1" ] || { printf '0'; return 0; }
  awk '
    /^---[[:space:]]*$/ { seen=1; next }
    seen && /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/ { n++ }
    END { print n+0 }
  ' "$1"
}

# Watchman reason codes — one token, no transcript. Written to .nightshift/.watch-reason
# (line 1 = code, line 2 = optional non-sensitive detail). Status and Doctor render the same
# labels. Adding a code here is the contract; callers must not invent ad-hoc strings.
ns_reason_label() {
  case "$1" in
    completed) printf 'shift completed' ;;
    owner-stop) printf 'owner stop-work order' ;;
    owner-disarm) printf 'shift disarmed - the armed marker is gone' ;;
    stale-pid) printf 'recorded process is stale' ;;
    invalid-session) printf 'session identity is missing or unreadable' ;;
    exhausted-retry) printf 'revival retries exhausted this wake' ;;
    unknown-wedge) printf 'session looks wedged without a verified error signature' ;;
    revived) printf 'session revived into its own conversation' ;;
    stand-down) printf 'watchman stood down' ;;
    wrong-host) printf 'watchman stood down - shift belongs to another host' ;;
    deadline) printf 'quitting time passed' ;;
    clean-session-end) printf 'owner closed the session' ;;
    esc-standby) printf 'standing by - owner interrupt in the transcript' ;;
    silent-standby) printf 'standing by - session alive and quiet' ;;
    non-resumable-session) printf 'recorded Codex identity cannot be resumed' ;;
    unreadable-rules) printf 'rules file missing or incomplete' ;;
    fresh-fallback) printf 'fresh session - punch list is the handover' ;;
    unsupported-state) printf 'workspace state-version is unsupported' ;;
    recovery-scope-unavailable) printf 'recorded launch scope cannot be requested on this host' ;;
    process-evidence-unavailable) printf 'process evidence is unavailable' ;;
    clock-out-failed) printf 'terminal clock-out failed without releasing the shift' ;;
    *) printf 'unknown watchman outcome' ;;
  esac
}

ns_record_reason() { # <nightshift-dir> <code> [detail]
  local dir="$1" code="$2" detail="${3:-}"
  [ -d "$dir" ] || return 1
  case "$code" in
    completed|owner-stop|owner-disarm|stale-pid|invalid-session|exhausted-retry|unknown-wedge|revived|stand-down|wrong-host|deadline|clean-session-end|esc-standby|silent-standby|non-resumable-session|unreadable-rules|fresh-fallback|unsupported-state|process-evidence-unavailable|clock-out-failed|recovery-scope-unavailable) ;;
    *) code="stand-down" ;;
  esac
  detail="$(printf '%s' "$detail" | tr -d '\000-\037' | sed 's/[[:space:]]*$//')"
  printf '%s\n%s\n' "$code" "$detail" >"$dir/.watch-reason"
}

ns_reason_code() { sed -n 1p "$1/.watch-reason" 2>/dev/null | tr -d '[:space:]'; }
ns_reason_detail() { sed -n 2p "$1/.watch-reason" 2>/dev/null; }

# The shift log is the owner's record of what the runtime did. Append-only, one line per
# event, in the format the gate and the control helpers already write. Hooks do not load
# the control module, so this is the writer they share.
ns_shift_log() { # <nightshift-dir> <line>
  [ -d "$1" ] || return 0
  printf '%s · %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$2" >>"$1/shift-log.md"
}

# Workspace schema. One integer in .nightshift/state-version is the authority. This plugin
# supports version 1. A missing marker is legacy version 0 — existing files stay compatible,
# and only an explicit setup/Doctor repair writes the marker. Newer integers fail closed.
# Never rewrite or downgrade a future marker; never migrate from hooks, start, status,
# archive, or recovery.
NS_STATE_VERSION=1

# ns_state_kind <workspace>
# Prints: absent | legacy | current | malformed | future
# Return: 0 operable (legacy or current) · 1 malformed · 2 future · 3 absent
ns_state_kind() {
  local ws="$1" ns marker raw lines
  ns="$ws/.nightshift"
  if [ ! -d "$ns" ]; then
    printf 'absent'
    return 3
  fi
  marker="$ns/state-version"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    printf 'legacy'
    return 0
  fi
  if [ -L "$marker" ] || [ ! -f "$marker" ]; then
    printf 'malformed'
    return 1
  fi
  IFS= read -r raw <"$marker" || true
  raw="$(printf '%s' "$raw" | tr -d '\r')"
  lines="$(awk 'END { print NR + 0 }' "$marker" 2>/dev/null)"
  case "$raw" in
    '' | *[!0-9]*)
      printf 'malformed'
      return 1
      ;;
    0) ;;
    0*)
      printf 'malformed'
      return 1
      ;;
  esac
  if [ "${#raw}" -gt 8 ] || [ "$lines" -gt 1 ]; then
    printf 'malformed'
    return 1
  fi
  if [ "$raw" -gt "$NS_STATE_VERSION" ]; then
    printf 'future'
    return 2
  fi
  if [ "$raw" -eq "$NS_STATE_VERSION" ]; then
    printf 'current'
    return 0
  fi
  printf 'legacy'
  return 0
}

# ns_state_version <workspace>
# Prints the integer when it can be read (0 if the marker is missing). Empty on
# absent or malformed. Return matches ns_state_kind.
ns_state_version() {
  local ws="$1" kind raw
  kind="$(ns_state_kind "$ws")"
  case "$kind" in
    absent)
      return 3
      ;;
    legacy)
      printf '0'
      return 0
      ;;
    current)
      printf '%s' "$NS_STATE_VERSION"
      return 0
      ;;
    future)
      IFS= read -r raw <"$ws/.nightshift/state-version" || true
      raw="$(printf '%s' "$raw" | tr -d '\r')"
      printf '%s' "$raw"
      return 2
      ;;
    *)
      return 1
      ;;
  esac
}

# ns_state_refuse_message <kind> — hook and skill diagnostic; no paths, no guesses.
ns_state_refuse_message() {
  case "$1" in
    future)
      printf 'Nightshift state-version is newer than this plugin supports (supported: %s). Upgrade Nightshift; never rewrite or downgrade the marker.' "$NS_STATE_VERSION"
      ;;
    malformed)
      printf 'Nightshift state-version is malformed. Inspect it only while unarmed; never guess a version.'
      ;;
    *)
      printf 'Nightshift state-version is unsupported.'
      ;;
  esac
}

# ns_write_state_version <workspace> <integer>
# Atomic replace of the marker. Refuses a symlink destination. Touches no other file.
ns_write_state_version() {
  local ws="$1" n="$2" ns marker tmp
  ns="$ws/.nightshift"
  marker="$ns/state-version"
  case "$n" in
    '' | *[!0-9]* | 0?*) return 1 ;;
  esac
  [ -d "$ns" ] || return 1
  if [ -L "$marker" ]; then
    return 1
  fi
  tmp="$ns/.state-version.$$"
  printf '%s\n' "$n" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$marker" || { rm -f "$tmp"; return 1; }
}

# ns_migrate_state <workspace>
# Legacy 0 → 1: write only the marker. Idempotent when already current.
# Return: 0 migrated or already current · 1 armed · 2 unsupported · 3 write failed
# Callers: setup and an explicit Doctor repair only. Never hooks, start, status, archive, recovery.
ns_migrate_state() {
  local ws="$1" kind
  kind="$(ns_state_kind "$ws")"
  case "$kind" in
    current)
      ns_migrate_receipts_layout "$ws"
      return 0
      ;;
    legacy)
      if [ -f "$ws/.nightshift/.shift-armed" ]; then
        return 1
      fi
      ns_migrate_receipts_layout "$ws"
      ns_write_state_version "$ws" "$NS_STATE_VERSION" || return 3
      return 0
      ;;
    *)
      return 2
      ;;
  esac
}

# Retention — archive-only, preview-first. 0 means keep forever. Unreadable rules
# also mean 0: a broken file must never become a delete. Hooks, start, status,
# Doctor, and recovery must not call these apply helpers.

# ns_retention_days <workspace> <runtimeLogDays|archiveDays>
# Prints a non-negative integer. Missing, nested, or unreadable → 0.
ns_retention_days() {
  local ws="$1" key="$2" f="$1/.nightshift/rules.json" raw=""
  case "$key" in
    runtimeLogDays)
      [ -z "${NIGHTSHIFT_RETENTION_RUNTIME_LOG_DAYS:-}" ] || { printf '%s' "$NIGHTSHIFT_RETENTION_RUNTIME_LOG_DAYS"; return 0; }
      ;;
    archiveDays)
      [ -z "${NIGHTSHIFT_RETENTION_ARCHIVE_DAYS:-}" ] || { printf '%s' "$NIGHTSHIFT_RETENTION_ARCHIVE_DAYS"; return 0; }
      ;;
    *)
      printf '0'
      return 0
      ;;
  esac
  if [ -f "$f" ]; then
    ns_rules_load "$f" && raw="$(_ns_rules_row retention "$key" "")" && {
      raw="${raw#*"$_NS_RULES_TAB"}"
    } || raw=0
  fi
  case "$raw" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "$raw" ;;
  esac
}

# True when a dated archive still holds open punch-list work or an armed marker.
ns_archive_has_open_work() {
  local dir="$1" f
  [ -d "$dir" ] || return 1
  [ ! -e "$dir/.shift-armed" ] || return 0
  [ ! -L "$dir/.shift-armed" ] || return 0
  for f in "$dir"/*; do
    if [ ! -f "$f" ] || [ -L "$f" ]; then
      continue
    fi
    case "${f##*/}" in
      punch-list.md | shipped.md)
        [ "$(ns_open_boxes "$f")" -eq 0 ] || return 0
        ;;
    esac
  done
  return 1
}

# ns_retention_eligible <workspace>
# Print "kind<TAB>rel<TAB>age<TAB>days" for allowlisted, old-enough, unprotected targets.
ns_retention_eligible() {
  local ws="$1" ns log_days arch_days age path rel
  ns="$ws/.nightshift"
  [ -d "$ns" ] || return 0
  log_days="$(ns_retention_days "$ws" runtimeLogDays)"
  arch_days="$(ns_retention_days "$ws" archiveDays)"

  if [ "$log_days" -gt 0 ] && [ -e "$ns/scheduled.log" ]; then
    path="$(ns_under_nightshift "$ws" scheduled.log)" && {
      age="$(ns_age_days "$path")" || age=""
      if [ -n "$age" ] && [ "$age" -ge "$log_days" ]; then
        printf '%s\t%s\t%s\t%s\n' runtime-log scheduled.log "$age" "$log_days"
      fi
    }
  fi

  [ "$arch_days" -gt 0 ] || return 0
  [ -d "$ns/archive" ] && [ ! -L "$ns/archive" ] || return 0
  for rel in "$ns/archive"/*; do
    [ -e "$rel" ] || continue
    rel="${rel#"$ns/"}"
    case "$rel" in
      archive/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      archive/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) rel="${rel%/}" ;;
      *) continue ;;
    esac
    if [ ! -d "$ns/$rel" ] || [ -L "$ns/$rel" ]; then
      continue
    fi
    path="$(ns_under_nightshift "$ws" "$rel")" || continue
    ns_archive_has_open_work "$path" && continue
    age="$(ns_age_days "$path")" || continue
    [ "$age" -ge "$arch_days" ] || continue
    printf '%s\t%s\t%s\t%s\n' archive "$rel" "$age" "$arch_days"
  done
}

# ns_retention_apply <workspace> — delete currently eligible allowlisted targets.
# Return: 0 deleted or nothing eligible · 1 armed · 2 refused/failed
ns_retention_apply() {
  local ws="$1" ns kind rel path
  ns="$ws/.nightshift"
  [ -d "$ns" ] || return 2
  if [ -f "$ns/.shift-armed" ]; then
    return 1
  fi
  while IFS="$(printf '\t')" read -r kind rel _ _; do
    [ -n "$rel" ] || continue
    path="$(ns_under_nightshift "$ws" "$rel")" || return 2
    case "$kind" in
      runtime-log)
        [ -f "$path" ] && [ ! -L "$path" ] || return 2
        rm -f "$path" || return 2
        ;;
      archive)
        [ -d "$path" ] && [ ! -L "$path" ] || return 2
        ns_archive_has_open_work "$path" && return 2
        rm -rf "$path" || return 2
        ;;
      *)
        return 2
        ;;
    esac
  done <<EOF
$(ns_retention_eligible "$ws")
EOF
}

# Artifact completion receipts live in .nightshift/receipts/. They replace a work-target
# git commit only while work-mode is artifact. Repository mode still requires a real commit.

# Real receipts directory only. A symlink here would let count, latest, and
# fingerprint follow files outside .nightshift/.
ns_receipts_usable_dir() {
  local dir
  dir="$(ns_receipts_dir "$1")"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  printf '%s' "$dir"
}

ns_file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

ns_receipts_count() {
  local dir n
  dir="$(ns_receipts_usable_dir "$1")" || {
    printf '0'
    return 0
  }
  n="$(find "$dir" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s' "${n:-0}"
}

# Newest completion receipt path, or status 1 when none exist.
# Primary key is mtime. Same-second uniqueness suffixes (`stamp-slug-n.md`)
# sort before `stamp-slug.md` in C locale (`-` < `.`), so a name-only sort
# can name the first write as latest. Tie-break maps `.md` → `-0.md` so the
# unsuffixed sibling sorts first and `-n` wins.
# The sort-row helper stays outside $(...) — a `case` `)` would close the substitution.
ns_latest_receipt_sort_row() {
  local path="$1" m key
  m="$(ns_mtime "$path")" || return 0
  case "$m" in
    '' | *[!0-9]*) return 0 ;;
  esac
  case "$path" in
    *.md) key="${path%.md}-0.md" ;;
    *) key="$path" ;;
  esac
  printf '%020d\t%s\t%s\n' "$m" "$key" "$path"
}

ns_latest_receipt() {
  local dir out tab
  dir="$(ns_receipts_usable_dir "$1")" || return 1
  out="$(
    find "$dir" -maxdepth 1 -type f ! -name '.*' -print 2>/dev/null | while IFS= read -r path; do
      [ -n "$path" ] || continue
      ns_latest_receipt_sort_row "$path"
    done | LC_ALL=C sort | tail -n 1
  )"
  [ -n "$out" ] || return 1
  tab="$(printf '\t')"
  printf '%s' "${out##*"$tab"}"
}

# Stable stall token: none when the directory is empty, otherwise a cksum of every receipt.
ns_receipts_fingerprint() {
  local dir out
  dir="$(ns_receipts_usable_dir "$1")" || {
    printf 'none'
    return 0
  }
  out="$(find "$dir" -maxdepth 1 -type f ! -name '.*' -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    cksum "$f" 2>/dev/null
  done)"
  if [ -z "$out" ]; then
    printf 'none'
    return 0
  fi
  printf '%s\n' "$out" | cksum | awk '{print $1"-"$2}'
}

# ---------------------------------------------------------------------------------------------
# Reading one item out of the punch list, and holding the contract to what it was
#
# The bounded rule the gate and Status already use: a top-level checkbox line owns the indented
# lines that follow it, up to the next top-level line. Fenced code and nested lists inside an item
# are indented, so they belong to it and come through whole. This is not a Markdown parser and is
# not trying to be one.

# ns_punch_gates <punch-list> — the gates block verbatim, heading included, or nothing.
# The owner may change it mid-shift by design, so it is never digested and always reprinted.
ns_punch_gates() {
  awk '
    /^## Gates[[:space:]]*$/ { on = 1; print; next }
    on && /^## / { exit }
    on { print }
  ' "$1" 2>/dev/null
}

# ns_punch_items <punch-list> — the lines under `## Items`, stopping at the next top-level heading.
#
# Not ns_items_section, which runs to the end of the file: that is the right boundary for counting
# boxes and the wrong one for a digest, because it would put a `## Notes` section the owner is free
# to edit inside the thing the gate holds still.
ns_punch_items() {
  awk '
    { sub(/\r$/, "") }
    !on { if ($0 ~ /^##[[:space:]]*Items[[:space:]]*$/) on = 1; next }
    /^## / { exit }
    { print }
  ' "$1" 2>/dev/null
}

# ns_punch_item <punch-list> <item> — one item with its sub-bullets, exactly as written. The item is
# named by its whole label, its number (`5`, `P03`), or its id; empty means the first still-open
# one. The first item that matches wins. Prints nothing when there is no such item.
ns_punch_item() {
  ns_punch_items "$1" | awk -v want="$2" "$NS_AWK_ITEM"'
    function starts_item(line) { return line ~ /^- \[[ xX]\]/ }
    # A top-level line is anything not indented: the next item, a heading, a note. Either way this
    # item has ended.
    function top_level(line) { return line !~ /^[[:space:]]/ && line != "" }
    function number(label) {
      if (match(label, /^[0-9]+/)) return substr(label, RSTART, RLENGTH)
      if (match(label, /^[A-Za-z]+[0-9]+/)) return substr(label, RSTART, RLENGTH)
      return ""
    }
    {
      if (!on && starts_item($0)) {
        if (want == "") {
          if ($0 !~ /^- \[ \]/) next
          on = 1
          print
          next
        }
        label = ns_item_label($0)
        if (label != want && ns_item_id($0) != want && number(label) != want) next
        on = 1
        print
        next
      }
      if (on) {
        if (top_level($0)) exit
        print
      }
    }
  '
}

# ns_punch_contract <punch-list> — everything above `## Items` except the gates block: the shift
# contract the owner wrote and nobody may edit while a shift is armed.
#
# The gates block is excluded from this digest and from the items one. It sits above `## Items` in
# the file, but the owner is meant to be able to change it mid-shift — tightening a gate after a
# near miss, relaxing one that is costing more than it catches — and `gatesDigest` already tracks
# it on its own terms.
ns_punch_contract() {
  awk '
    { sub(/\r$/, "") }
    /^## Items[[:space:]]*$/ { exit }
    /^## Gates[[:space:]]*$/ { skip = 1; next }
    skip && /^## / { skip = 0 }
    skip { next }
    { print }
  ' "$1" 2>/dev/null
}

# ns_punch_items_normalised <punch-list> — every item line and sub-bullet with the checkbox state
# flattened, so ticking a box changes nothing and any other edit — a reworded item, a deleted one,
# an inserted one — changes everything.
#
# Line endings are flattened with it, here and in the contract. A shift can be handed from a macOS
# host to a Windows one, and a checkout that converts on the way would otherwise present a contract
# nobody touched as tampered with. The digest is a property of what the list says, not of how the
# filesystem it is sitting on ends a line.
ns_punch_items_normalised() {
  ns_punch_items "$1" | sed 's/^- \[[xX]\]/- [ ]/'
}

# ns_punch_digest — a stable digest of stdin, from whatever the machine has. Same shape as every
# other digest Nightshift records: 64 lowercase hex characters.
ns_punch_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | cut -d' ' -f1
  else
    return 1
  fi
}

# ns_punch_contract_digest <punch-list> / ns_punch_items_digest <punch-list>
ns_punch_contract_digest() { ns_punch_contract "$1" | ns_punch_digest; }
ns_punch_items_digest() { ns_punch_items_normalised "$1" | ns_punch_digest; }

# ---------------------------------------------------------------- preflight explanations
#
# The explanation belongs on the verdict line that occurred, not in a paragraph the model reads on
# every Start for verdicts that did not. It is printed here from lib/preflight-explain.txt, which
# the PowerShell twin reads too: one copy of the text, so the two hosts cannot word the same
# verdict differently.

# ns_explain_lines <kind> <topic> — the records of that kind for that topic, in file order.
# Prints nothing when the topic has none, which is not an error: a topic without a record keeps
# its verdict and its own repairs.
ns_explain_lines() {
  local file
  file="${NS_EXPLAIN_FILE:-}"
  [ -n "$file" ] || return 0
  [ -f "$file" ] || return 0
  awk -F '\t' -v kind="$1" -v topic="$2" '
    /^#/ || NF < 3 { next }
    $1 == kind && $2 == topic { print $3 }
  ' "$file" 2>/dev/null
}

# ns_explain_emit <topic> — the explanation for a topic, then any repairs the table carries for it.
# Called by the warn and refuse emitters, so no verdict site has to remember to do it.
ns_explain_emit() {
  ns_explain_lines explain "$1" | while IFS= read -r line; do
    [ -n "$line" ] && printf 'explain %s %s\n' "$1" "$line"
  done
  ns_explain_lines repair "$1" | while IFS= read -r line; do
    [ -n "$line" ] && printf 'repair %s\n' "$line"
  done
}

# ns_explain_topic <verdict text> — the first word, which every verdict leads with.
ns_explain_topic() {
  case "$1" in
    *' '*) printf '%s' "${1%% *}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------- the facts Status renders
#
# Counting is mechanics — the boxes below a heading, drafting-table boxes only after the first
# rule, the deadline against the clock, the stall counter. The skill renders; these produce, so
# none of it is derived by hand.
#
# Bounded readers, never Markdown parsers: each one takes the first line of an entry under the
# shape the file already has, so a file the owner has written prose into still yields facts rather
# than a guess.

# ns_status_open_title <punch-list> — the title line of the first still-open item, without its
# checkbox or bold markers. Empty when nothing is open.
ns_status_open_title() {
  ns_punch_item "$1" "" 2>/dev/null | awk '
    NR == 1 {
      sub(/[[:space:]]*<!--[[:space:]]*id:[[:space:]]*[a-z0-9]+[[:space:]]*-->[[:space:]]*$/, "")
      sub(/^- \[[ xX]\][[:space:]]*/, "")
      gsub(/\*\*/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  '
}

# ns_status_entry_titles <file> <max> — the first line of each top-level `- ` entry, trimmed.
# Used for the parking lot and the snag log, which share that shape.
ns_status_entry_titles() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  awk -v max="${2:-0}" '
    /^Filed:/ { next }
    /^- Filed:/ { next }
    /^- / {
      line = $0
      sub(/^- /, "", line)
      gsub(/\*\*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (length(line) > 100) line = substr(line, 1, 97) "..."
      out[++n] = line
    }
    END {
      first = 1
      if (max > 0 && n > max) first = n - max + 1
      for (i = first; i <= n; i++) print out[i]
    }
  ' "$1" 2>/dev/null
}

# ns_status_entry_count <file> — how many such entries the file holds.
ns_status_entry_count() {
  if ! { [ -f "$1" ] && [ ! -L "$1" ]; }; then printf '0'; return 0; fi
  awk '/^Filed:/ { next } /^- Filed:/ { next } /^- / { n++ } END { printf "%d", n + 0 }' "$1" 2>/dev/null || printf '0'
}

# ns_status_opportunity_counts <opportunity-map> — `candidate=N building=N shipped=N rejected=N
# parked=N` from the `Status:` lines the map already carries.
ns_status_opportunity_counts() {
  if ! { [ -f "$1" ] && [ ! -L "$1" ]; }; then printf 'candidate=0 building=0 shipped=0 rejected=0 parked=0'; return 0; fi
  awk '
    /<!--/ { comment = 1 }
    /-->/  { comment = 0; next }
    comment { next }
    /^[[:space:]]*Status:[[:space:]]*/ {
      s = $0
      sub(/^[[:space:]]*Status:[[:space:]]*/, "", s)
      sub(/[[:space:]].*$/, "", s)
      gsub(/[^a-zA-Z]/, "", s)
      if (s != "") c[tolower(s)]++
    }
    END {
      printf "candidate=%d building=%d shipped=%d rejected=%d parked=%d",
        c["candidate"] + 0, c["building"] + 0, c["shipped"] + 0, c["rejected"] + 0, c["parked"] + 0
    }
  ' "$1" 2>/dev/null || printf 'candidate=0 building=0 shipped=0 rejected=0 parked=0'
}

# ns_status_building <opportunity-map> — the building entry's title, then its `Phase:`, `Next:` and
# `Verify remaining:` lines, one per line. Nothing when none is building.
#
# An entry runs from a heading to the next heading. More than one building entry is inconsistent
# state the model reports without changing; this prints the first, and the count says there is more.
ns_status_building() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  awk '
    /<!--/ { comment = 1 }
    /-->/  { comment = 0; next }
    comment { next }
    /^#{2,}[[:space:]]/ {
      if (found) exit
      title = $0
      sub(/^#+[[:space:]]*/, "", title)
      gsub(/\*\*/, "", title)
      building = 0
      next
    }
    /^[[:space:]]*Status:[[:space:]]*building/ {
      building = 1
      found = 1
      print "title\t" title
      next
    }
    building && /^[[:space:]]*(Phase|Next|Verify remaining):/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      key = line
      sub(/:.*$/, "", key)
      sub(/^[^:]*:[[:space:]]*/, "", line)
      print tolower(key) "\t" line
    }
  ' "$1" 2>/dev/null
}

# ns_status_stop_reason <ns> — the first line of the stop-work marker, or nothing.
ns_status_stop_reason() {
  ns_marker="$1/STOP"
  [ -f "$ns_marker" ] && [ ! -L "$ns_marker" ] || return 0
  IFS= read -r ns_line <"$ns_marker" 2>/dev/null || return 0
  printf '%s' "$ns_line"
}

# ns_status_transitions <shift-log> <max> — the journal lines that record a shift changing hands:
# a stand-down, a revival, a host change. Compacted to their first sentence.
ns_status_transitions() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  awk -v max="${2:-3}" '
    {
      line = $0
      # Both writers lead with a dash, a timestamp and a separator before the message. Everything up
      # to the first letter is that preamble, in any locale and with any separator byte.
      sub(/^[^A-Za-z]*/, "", line)
    }
    # A transition is a line whose SUBJECT is the shift changing hands. Matching the words anywhere
    # would catch an item summary that merely mentions one.
    tolower(line) ~ /^(watchman|the watchman|shift started|shift ended|the session ended|revived|host change)/ {
      if (length(line) > 120) line = substr(line, 1, 117) "..."
      out[++n] = line
    }
    END {
      first = 1
      if (max > 0 && n > max) first = n - max + 1
      for (i = first; i <= n; i++) print out[i]
    }
  ' "$1" 2>/dev/null
}

# ns_status_deadline_remaining <ns> — `<n>h<m>m remaining`, `passed`, or nothing when there is no
# deadline. The clock is read once, here, rather than in the skill.
ns_status_deadline_remaining() {
  ns_file="$1/deadline"
  [ -f "$ns_file" ] && [ ! -L "$ns_file" ] || return 0
  IFS= read -r ns_epoch <"$ns_file" 2>/dev/null || return 0
  case "$ns_epoch" in '' | *[!0-9]*) return 0 ;; esac
  ns_now="$(date +%s 2>/dev/null)" || return 0
  if [ "$ns_epoch" -le "$ns_now" ]; then
    printf 'passed'
    return 0
  fi
  ns_left=$((ns_epoch - ns_now))
  printf '%dh%02dm remaining' "$((ns_left / 3600))" "$(((ns_left % 3600) / 60))"
}
