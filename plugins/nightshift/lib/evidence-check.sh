#!/usr/bin/env bash
# evidence-check.sh — whether a ticked item's named evidence is present.
#
# check off asks for nothing, which is how a tick behaved before this choice existed. report and
# block both name what is missing. block is the only one the clock-out gate treats as open. A file
# named in backticks is one path segment under the item's evidence folder. kind: names a kind whose
# evidence-check block also applies. The result says present. It does not say the work is right.

_ns_evidence_here="${BASH_SOURCE[0]%/*}"
[ "$_ns_evidence_here" != "${BASH_SOURCE[0]}" ] || _ns_evidence_here=.
# shellcheck source=plugins/nightshift/lib/catalog-sources.sh
. "$_ns_evidence_here/catalog-sources.sh"

# ns_evidence_item_line <punch-list> <label> — the item's Evidence: text, after the marker.
ns_evidence_item_line() {
  ns_items_section "$1" 2>/dev/null | awk -v want="$2" "$NS_AWK_ITEM"'
    /^- \[[ xX-]\]/ { inside = (ns_item_label($0) == want); next }
    /^[^[:space:]]/ { inside = 0 }
    inside && /^[[:space:]]+-[[:space:]]+Evidence:/ {
      sub(/^[[:space:]]+-[[:space:]]+Evidence:[[:space:]]*/, "")
      print
      exit
    }
  '
}

# ns_evidence_line_value <line> <key> — the value after `key:` when it is one this setting allows.
ns_evidence_line_value() {
  printf '%s\n' "$1" | awk -v key="$2" '
    {
      n = split($0, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (w[i] == key ":") { print w[i + 1]; exit }
        if (index(w[i], key ":") == 1) { print substr(w[i], length(key) + 2); exit }
      }
    }
  '
}

# ns_evidence_kinds <line> — each `kind:` key, one per line.
ns_evidence_kinds() {
  printf '%s\n' "$1" | awk '
    {
      n = split($0, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        v = ""
        if (w[i] == "kind:") v = w[i + 1]
        else if (index(w[i], "kind:") == 1) v = substr(w[i], 6)
        if (v ~ /^[a-z0-9]+(-[a-z0-9]+)*$/) print v
      }
    }
  '
}

# ns_evidence_files <line> — each closed backtick span that is a single path segment.
ns_evidence_files() {
  printf '%s\n' "$1" | awk '
    {
      s = $0
      while (match(s, /`[^`]*`/)) {
        name = substr(s, RSTART + 1, RLENGTH - 2)
        s = substr(s, RSTART + RLENGTH)
        if (name == "" || name ~ /\// || name ~ /\\/ || name == "." || name == "..") continue
        print name
      }
    }
  '
}

# ns_evidence_shift_value <project> <field> — the shift value, or empty when nothing is set.
ns_evidence_shift_value() {
  ns_policy_pref "$1" receipts "evidence.$2" 2>/dev/null || true
}

# ns_evidence_effective <project> <line> <field> — the item's value, else the shift's, else the default.
ns_evidence_effective() {
  local project="$1" line="$2" field="$3" item shift check
  item="$(ns_evidence_line_value "$line" "$field")"
  case "$field" in
    check)
      case "$item" in off | report | block) printf '%s' "$item"; return 0 ;; esac
      shift="$(ns_evidence_shift_value "$project" check)"
      case "$shift" in off | report | block) printf '%s' "$shift"; return 0 ;; esac
      printf 'off'
      ;;
    review)
      case "$item" in off | on) printf '%s' "$item"; return 0 ;; esac
      shift="$(ns_evidence_shift_value "$project" review)"
      case "$shift" in off | on) printf '%s' "$shift"; return 0 ;; esac
      printf 'off'
      ;;
    unavailable)
      case "$item" in hold | park | note) printf '%s' "$item"; return 0 ;; esac
      shift="$(ns_evidence_shift_value "$project" unavailable)"
      case "$shift" in hold | park | note) printf '%s' "$shift"; return 0 ;; esac
      check="$(ns_evidence_effective "$project" "$line" check)"
      if [ "$check" = block ]; then printf 'hold'; else printf 'note'; fi
      ;;
  esac
}

_ns_evidence_plugin() {
  (cd "$_ns_evidence_here/.." && pwd -P)
}

# ns_evidence_kind_file <project> <key> — the winning kind file, project over configured over user over plugin.
ns_evidence_kind_file() {
  local project="$1" key="$2" dir f raw resolved plugin
  dir="$(ns_layout_path "$project/.nightshift" evidence-kinds 2>/dev/null || true)"
  if [ -n "$dir" ] && [ -f "$dir/$key.md" ] && [ ! -L "$dir/$key.md" ]; then
    printf '%s' "$dir/$key.md"
    return 0
  fi
  raw="$(ns_evidence_shift_value "$project" kindsPaths)"
  if [ -n "$raw" ]; then
    while IFS= read -r resolved; do
      [ -n "$resolved" ] || continue
      f="$(ns_catalog_resolve "$project" "$resolved")/$key.md"
      if [ -f "$f" ] && [ ! -L "$f" ]; then
        printf '%s' "$f"
        return 0
      fi
    done <<PATHS
$(ns_json_string_list "$raw" || true)
PATHS
  fi
  dir="$(ns_catalog_user_dir evidence kinds)"
  if [ -f "$dir/$key.md" ] && [ ! -L "$dir/$key.md" ]; then
    printf '%s' "$dir/$key.md"
    return 0
  fi
  plugin="$(_ns_evidence_plugin)"
  f="$plugin/skills/nightshift/references/evidence/kinds/$key.md"
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    printf '%s' "$f"
    return 0
  fi
  return 1
}

# _ns_evidence_block <kind-file> — `files`, `min`, `type` from the first evidence-check fence.
_ns_evidence_block() {
  awk '
    /^```evidence-check$/ { on = 1; next }
    on && /^```$/ { exit }
    on && /^files: / { files = substr($0, 8) }
    on && /^min: / { min = substr($0, 6) }
    on && /^type: / { type = substr($0, 7) }
    END {
      if (files != "" || min != "" || type != "") print files "\t" min "\t" type
    }
  ' "$1"
}

_ns_evidence_hex() {
  od -An -N12 -tx1 "$1" 2>/dev/null | tr -d ' \n'
}

_ns_evidence_image() {
  local sig
  sig="$(_ns_evidence_hex "$1")"
  case "$sig" in
    89504e47*) return 0 ;;
    ffd8ff*) return 0 ;;
    47494638*) return 0 ;;
    52494646????????57454250*) return 0 ;;
  esac
  return 1
}

_ns_evidence_json() {
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$1" >/dev/null 2>&1
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" >/dev/null 2>&1
    return
  fi
  return 1
}

_ns_evidence_type_of() {
  local name="$1"
  case "$name" in
    *.png | *.jpg | *.jpeg | *.gif | *.webp) printf 'image' ;;
    *.json) printf 'json' ;;
    *) printf 'text' ;;
  esac
}

_ns_evidence_typed() {
  local file="$1" type="$2"
  case "$type" in
    image) _ns_evidence_image "$file" ;;
    json) _ns_evidence_json "$file" ;;
    text | any) return 0 ;;
    *) return 1 ;;
  esac
}

# ns_evidence_file_problem <dir> <name> — one problem word, or nothing when the file is present.
ns_evidence_file_problem() {
  local dir="$1" name="$2" path="$1/$2" type
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'missing %s\n' "$name"
    return 0
  fi
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    printf 'link %s\n' "$name"
    return 0
  fi
  if [ ! -s "$path" ]; then
    printf 'empty %s\n' "$name"
    return 0
  fi
  type="$(_ns_evidence_type_of "$name")"
  if ! _ns_evidence_typed "$path" "$type"; then
    printf 'type %s\n' "$name"
  fi
}

# ns_evidence_problems <project> <punch-list> <label> — one problem per line. Nothing when check is off.
ns_evidence_problems() {
  local project="$1" punch="$2" label="$3" line id receipt dir kind file block files min type count f
  line="$(ns_evidence_item_line "$punch" "$label")"
  [ "$(ns_evidence_effective "$project" "$line" check)" = off ] && return 0
  id="$(ns_item_id_for "$punch" "$label")"
  receipt="$(ns_receipt_path "$project" "$label" "$id")"
  if [ -f "$receipt" ] && [ ! -L "$receipt" ] && grep -qxF '<!-- nightshift:evidence-unavailable -->' "$receipt"; then
    return 0
  fi
  dir="${receipt%.md}"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    ns_evidence_file_problem "$dir" "$file"
  done <<FILES
$(ns_evidence_files "$line")
FILES
  while IFS= read -r kind; do
    [ -n "$kind" ] || continue
    file="$(ns_evidence_kind_file "$project" "$kind" || true)"
    if [ -z "$file" ]; then
      printf 'missing kind %s\n' "$kind"
      continue
    fi
    block="$(_ns_evidence_block "$file")"
    [ -n "$block" ] || continue
    files="${block%%$'\t'*}"
    type="${block##*$'\t'}"
    min="${block#*$'\t'}"
    min="${min%%$'\t'*}"
    case "$files" in *'/'* | *'..'* | '') printf 'pattern %s\n' "$kind"; continue ;; esac
    case "$min" in '' | *[!0-9]* | 0) printf 'pattern %s\n' "$kind"; continue ;; esac
    case "$type" in image | text | json | any) ;; *) printf 'pattern %s\n' "$kind"; continue ;; esac
    count=0
    if [ -d "$dir" ] && [ ! -L "$dir" ]; then
      shopt -s nullglob
      for f in "$dir"/$files; do
        [ -f "$f" ] && [ ! -L "$f" ] && [ -s "$f" ] || continue
        _ns_evidence_typed "$f" "$type" || continue
        count=$((count + 1))
      done
      shopt -u nullglob
    fi
    [ "$count" -ge "$min" ] || printf 'pattern %s\n' "$kind"
  done <<KINDS
$(ns_evidence_kinds "$line")
KINDS
  if [ "$(ns_evidence_effective "$project" "$line" review)" = on ] && [ "$(ns_evidence_effective "$project" "$line" check)" = block ]; then
    if [ ! -f "$receipt" ] || [ -L "$receipt" ] || ! grep -qE '^## Reviewed([[:space:]]|$)' "$receipt"; then
      printf 'reviewed\n'
    fi
  fi
}

# ns_evidence_hold <project> <punch-list> — the clock-out sentence when a ticked item's evidence
# blocks, or nothing. check off and report print nothing: the tick stands.
ns_evidence_hold() {
  local project="$1" punch="$2" label id line problems flat
  [ -f "$punch" ] && [ ! -L "$punch" ] || return 0
  while IFS=$'\t' read -r label id; do
    [ -n "$label" ] || continue
    line="$(ns_evidence_item_line "$punch" "$label")"
    [ "$(ns_evidence_effective "$project" "$line" check)" = block ] || continue
    problems="$(ns_evidence_problems "$project" "$punch" "$label")"
    [ -n "$problems" ] || continue
    flat="$(printf '%s\n' "$problems" | paste -sd ', ' -)"
    printf 'DO NOT STOP — %s is ticked and its evidence is not present: %s. A present file is a regular, non-empty file of the type it claims. The tick stands once those files are there.\n' \
      "$label" "$flat"
    return 0
  done <<ROWS
$(ns_item_rows "$punch" ticked 2>/dev/null || true)
ROWS
}

# ns_evidence_mechanical <project> <line> — 0 when the line names a file, a missing kind, or a kind
# whose evidence-check block applies. A kind with no block adds nothing.
ns_evidence_mechanical() {
  local project="$1" line="$2" kind file block
  [ -n "$(ns_evidence_files "$line")" ] && return 0
  while IFS= read -r kind; do
    [ -n "$kind" ] || continue
    file="$(ns_evidence_kind_file "$project" "$kind" || true)"
    if [ -z "$file" ]; then
      return 0
    fi
    block="$(_ns_evidence_block "$file")"
    [ -n "$block" ] && return 0
  done <<KINDS
$(ns_evidence_kinds "$line")
KINDS
  return 1
}

# ns_evidence_receipt_text <project> <punch-list> <label> — the block a report or block check writes.
# Status 1 when check is off, so the receipt is left as it was.
ns_evidence_receipt_text() {
  local project="$1" punch="$2" label="$3" line check problems
  line="$(ns_evidence_item_line "$punch" "$label")"
  check="$(ns_evidence_effective "$project" "$line" check)"
  [ "$check" = off ] && return 1
  problems="$(ns_evidence_problems "$project" "$punch" "$label")"
  if ns_evidence_mechanical "$project" "$line"; then
    if [ -n "$problems" ]; then
      printf '%s\n' "$problems"
    else
      printf 'present\n'
    fi
  else
    printf 'Nothing mechanical to check.\n'
    if [ -n "$problems" ]; then
      printf '%s\n' "$problems"
    fi
  fi
}

# ns_evidence_record <nightshift-dir> <project> <label> — write the evidence-check block when check
# is report or block. check off writes nothing. A recorded unavailable reason is left as it stands.
ns_evidence_record() {
  local ns="$1" project="$2" label="$3" punch receipt body text
  ns_receipts_enabled "$project" || return 0
  ns_layout_set punch "$ns" punch-list
  [ -f "$punch" ] && [ ! -L "$punch" ] || return 0
  text="$(ns_evidence_receipt_text "$project" "$punch" "$label")" || return 0
  receipt="$(ns_receipt_path "$project" "$label")"
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 0
  if grep -qxF '<!-- nightshift:evidence-unavailable -->' "$receipt"; then
    return 0
  fi
  body="$(mktemp "${TMPDIR:-/tmp}/ns-evidence.XXXXXX")" || return 0
  printf '%s\n' "$text" >"$body"
  ns_receipt_write_block "$receipt" evidence-check "$body" || :
  rm -f "$body"
}

# ns_evidence_set_box <punch-list> <label> <mark> — rewrite that item's checkbox. mark is x or -.
ns_evidence_set_box() {
  local punch="$1" label="$2" mark="$3" tmp
  [ -f "$punch" ] && [ ! -L "$punch" ] || return 1
  tmp="$punch.box.$$"
  awk -v want="$label" -v mark="$mark" "$NS_AWK_ITEM"'
    /^- \[[ xX-]\]/ {
      if (ns_item_label($0) == want) sub(/^- \[[ xX-]\]/, "- [" mark "]")
    }
    { print }
  ' "$punch" >"$tmp" && mv "$tmp" "$punch"
}

# ns_evidence_unavailable_text <line> <reason> — which named evidence could not be made, and why.
ns_evidence_unavailable_text() {
  local line="$1" reason="$2" file any=0
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    any=1
    printf '%s: unavailable — %s\n' "$file" "$reason"
  done <<FILES
$(ns_evidence_files "$line")
FILES
  [ "$any" -eq 1 ] || printf 'unavailable — %s\n' "$reason"
}

# ns_evidence_unavailable <project> <label> <reason> — apply the item's unavailable setting.
# hold closes the item as stopped and records the reason on the receipt and the snag log.
# park writes one parking-lot entry and leaves the item. note ticks it and records the reason.
# Prints the setting it applied.
ns_evidence_unavailable() {
  local project="$1" label="$2" reason="$3" ns punch line mode check receipt body lot snag marker
  local found=0 one id
  ns="${project%/}/.nightshift"
  ns_layout_set punch "$ns" punch-list
  [ -f "$punch" ] && [ ! -L "$punch" ] || return 1
  while IFS=$'\t' read -r one id; do
    [ "$one" = "$label" ] && found=1 && break
  done <<ROWS
$(ns_item_rows "$punch" all 2>/dev/null || true)
ROWS
  [ "$found" -eq 1 ] || return 1
  reason="$(printf '%s' "$reason" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//')"
  [ -n "$reason" ] || reason="not produced"
  line="$(ns_evidence_item_line "$punch" "$label")"
  mode="$(ns_evidence_effective "$project" "$line" unavailable)"
  case "$mode" in
    hold | park | note) ;;
    *)
      check="$(ns_evidence_effective "$project" "$line" check)"
      if [ "$check" = block ]; then mode=hold; else mode=note; fi
      ;;
  esac
  if [ "$mode" = hold ] || [ "$mode" = note ]; then
    receipt="$(ns_receipt_path "$project" "$label")"
    if [ -L "$receipt" ]; then
      return 1
    fi
    if [ ! -f "$receipt" ]; then
      mkdir -p "${receipt%/*}" || return 1
      printf '# %s\n' "$label" >"$receipt" || return 1
    fi
    body="$(mktemp "${TMPDIR:-/tmp}/ns-evidence.XXXXXX")" || return 1
    ns_evidence_unavailable_text "$line" "$reason" >"$body"
    ns_receipt_write_block "$receipt" evidence-unavailable "$body" || { rm -f "$body"; return 1; }
    rm -f "$body"
  fi
  case "$mode" in
    hold)
      ns_evidence_set_box "$punch" "$label" '-' || return 1
      ns_layout_set snag "$ns" snag-log
      mkdir -p "${snag%/*}" || return 1
      marker="${label} · ${reason} · accepted-tradeoff · $(date -u +%Y-%m-%d)"
      if [ ! -f "$snag" ]; then
        printf '# Snag Log\n\n' >"$snag"
      fi
      if [ ! -L "$snag" ] && ! grep -qxF -- "- $marker" "$snag"; then
        printf -- '- %s\n' "$marker" >>"$snag"
      fi
      ;;
    park)
      ns_layout_set lot "$ns" parking-lot
      mkdir -p "${lot%/*}" || return 1
      marker="Evidence for ${label} could not be produced"
      if [ ! -f "$lot" ]; then
        printf '# Parking Lot\n\n' >"$lot"
      fi
      if [ ! -L "$lot" ] && ! grep -qF -- "$marker" "$lot"; then
        printf -- '- %s · leave the item open and keep working · %s\n' "$marker" "$reason" >>"$lot"
      fi
      ;;
    note)
      ns_evidence_set_box "$punch" "$label" 'x' || return 1
      ;;
  esac
  printf '%s\n' "$mode"
}
