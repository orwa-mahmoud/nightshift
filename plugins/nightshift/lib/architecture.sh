#!/usr/bin/env bash
# architecture.sh — one diagram of what the shift touched, kept current item by item.
#
# With receipts.evidence.architecture on, the model keeps receipts/architecture.md (Mermaid, with a
# short legend) covering only the components the shift touched, and each receipt says whether its
# item changed it: `Diagram: updated — <what changed>` or `Diagram: unchanged — <why>`. At the tick
# the runtime copies the diagram into the item's evidence folder when it differs from the last copy,
# and links the receipt to the diagram as it stood after that item. run/architecture records the
# shift and the receipt whose folder holds the last copy. PowerShell does the same (Nightshift.07.ps1).

# ns_architecture_enabled <project> — status 0 when the owner asked for the diagram.
ns_architecture_enabled() {
  [ "$(ns_receipts "$1" evidence.architecture 2>/dev/null)" = on ]
}

# ns_architecture_tick <nightshift-dir> <project> <item-label> — snapshot the diagram when it changed
# and link the receipt to the diagram as it stands now.
ns_architecture_tick() {
  local ns="$1" project="$2" label="$3" receipt dir page state sid last base body
  ns_architecture_enabled "$project" || return 0
  receipt="$(ns_receipt_path "$project" "$label")"
  { [ -f "$receipt" ] && [ ! -L "$receipt" ]; } || return 0
  dir="$(ns_receipts_dir "$project")"
  page="$(ns_layout_path "$ns" architecture)"
  state="$(ns_layout_path "$ns" architecture-state)"
  sid="$(ns_policy_shift_id "$project" 2>/dev/null)" || sid=""
  last=""
  [ "$(ns_record_get "$state" shift)" != "$sid" ] || last="$(ns_record_get "$state" last)"
  body="$(mktemp "${TMPDIR:-/tmp}/ns-architecture.XXXXXX")" || return 0
  if [ -f "$page" ] && [ ! -L "$page" ]; then
    base="${receipt##*/}"
    base="${base%.md}"
    if [ -z "$last" ] || ! cmp -s "$page" "$dir/$last/architecture.md"; then
      if mkdir -p "$dir/$base" && [ ! -L "$dir/$base" ] && cp "$page" "$dir/$base/architecture.md"; then
        last="$base"
        ns_record_set "$state" shift "$sid" && ns_record_set "$state" last "$last" || :
      fi
    fi
    if [ -n "$last" ]; then
      printf '**Architecture after this item:** [architecture.md](./%s/architecture.md)\n' "$last" >"$body"
    else
      printf '**Architecture after this item:** unavailable — the diagram could not be copied\n' >"$body"
    fi
  else
    printf '**Architecture after this item:** no diagram yet.\n' >"$body"
  fi
  ns_receipt_write_block "$receipt" architecture "$body" || :
  rm -f "$body"
}

# ns_architecture_changes <project> — `<label>\t<what changed>` for each ticked item whose receipt
# says `Diagram: updated — …`, list order.
ns_architecture_changes() {
  local project="$1" punch dir label id f what
  ns_layout_set punch "$project/.nightshift" punch-list
  dir="$(ns_receipts_dir "$project")"
  [ -f "$punch" ] || return 0
  while IFS=$'\t' read -r label id || [ -n "$label" ]; do
    [ -n "$label" ] || continue
    f="$dir/$(ns_receipt_base "$project" "$label" "$id").md"
    { [ -f "$f" ] && [ ! -L "$f" ]; } || continue
    what="$(awk '{ sub(/\r$/, "") } sub(/^[-*[:space:]]*Diagram: updated — /, "") { print; exit }' "$f")"
    [ -z "$what" ] || printf '%s\t%s\n' "$label" "$what"
  done <<EOF
$(ns_item_rows "$punch" ticked)
EOF
}

# ns_architecture_missing <project> — the label of each ticked item whose receipt has no `Diagram:`
# line, list order. Nothing while the diagram is off.
ns_architecture_missing() {
  local project="$1" punch dir label id f
  ns_architecture_enabled "$project" || return 0
  ns_layout_set punch "$project/.nightshift" punch-list
  dir="$(ns_receipts_dir "$project")"
  [ -f "$punch" ] || return 0
  while IFS=$'\t' read -r label id || [ -n "$label" ]; do
    [ -n "$label" ] || continue
    f="$dir/$(ns_receipt_base "$project" "$label" "$id").md"
    if [ -f "$f" ] && [ ! -L "$f" ] && grep -Eq '^[-*[:space:]]*Diagram: (updated|unchanged) — ' "$f"; then
      continue
    fi
    printf '%s\n' "$label"
  done <<EOF
$(ns_item_rows "$punch" ticked)
EOF
}

# ns_architecture_notice <project> — the item-start notice's instruction while the diagram is on.
ns_architecture_notice() {
  ns_architecture_enabled "$1" || return 0
  printf 'after the commit and before the tick, update %s/architecture.md only if this item changed the structure, then write %s or %s in the receipt' \
    "$(ns_layout_name "$1/.nightshift" receipts)" "\`Diagram: updated — <what changed>\`" "\`Diagram: unchanged — <why>\`"
}
