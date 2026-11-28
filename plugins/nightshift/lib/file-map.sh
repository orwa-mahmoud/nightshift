#!/usr/bin/env bash
# file-map.sh — the files an item and a shift changed, drawn by the runtime at each tick.
#
# With receipts.evidence.fileMap on, the gate's tick writes two maps and the model writes neither:
# the item's, from the commits made since the previous tick, as a generated block at the end of its
# receipt; and the shift's, from the commit the shift started on to HEAD, as receipts/shift-map.md.
# In artifact mode there is no git, so the item map lists the paths the receipt declares under
# any heading, and the shift map is the union over the ticked items. A map that cannot be built
# says `unavailable — <reason>`. PowerShell draws the same bytes (Nightshift.07.ps1).
#
# run/file-map records, one key=value per line, the shift it belongs to (shift), the commit that
# shift started on (base) and HEAD at the last tick (last).

# The programs this module runs sit beside it.
_ns_file_map_dir="${BASH_SOURCE[0]%/*}"
[ "$_ns_file_map_dir" != "${BASH_SOURCE[0]}" ] || _ns_file_map_dir=.

NS_FILEMAP_COLLAPSE=40
NS_FILEMAP_FENCE="\`\`\`"

# ns_filemap_enabled <project> — status 0 when the owner asked for file maps.
ns_filemap_enabled() {
  [ "$(ns_receipts "$1" evidence.fileMap 2>/dev/null)" = on ]
}

# ns_filemap_field <project> <key> — one value from run/file-map, or nothing.
ns_filemap_field() {
  ns_record_get "$(ns_layout_path "$1/.nightshift" file-map)" "$2"
}

# ns_filemap_set <project> <key> <value> — write one value into run/file-map, keeping the others.
ns_filemap_set() {
  ns_record_set "$(ns_layout_path "$1/.nightshift" file-map)" "$2" "$3"
}

# ns_filemap_start <project> — record the commit tonight's shift starts on, once per shift. Nothing
# is written while file maps are off or the work target is not a repository.
ns_filemap_start() {
  local project="$1" sid target head
  ns_filemap_enabled "$project" || return 0
  [ "$(ns_work_mode "$project" 2>/dev/null)" = repository ] || return 0
  sid="$(ns_policy_shift_id "$project" 2>/dev/null)" || sid=""
  if [ -n "$(ns_filemap_field "$project" base)" ]; then
    case "$(ns_filemap_field "$project" shift)" in
      "$sid") return 0 ;;
      # A continued shift keeps the commit it started on under its new id.
      "$NS_SHIFT_CONTINUED")
        ns_filemap_set "$project" shift "$sid"
        return
        ;;
    esac
  fi
  target="$(ns_work_target "$project" 2>/dev/null)" || return 0
  head="$(git -C "$target" rev-parse --verify --quiet HEAD 2>/dev/null)" || return 0
  ns_filemap_set "$project" shift "$sid" &&
    ns_filemap_set "$project" base "$head" &&
    ns_filemap_set "$project" last "$head"
}

# ns_filemap_git_rows <dir> <from> <to> — one row per changed path, `path\tstatus\told\tadd\tdel`,
# renames and copies under their new path. Status 1 when git cannot read the range.
ns_filemap_git_rows() {
  local dir="$1" from="$2" to="$3" names counts st p old rec add rest del
  names="$(mktemp "${TMPDIR:-/tmp}/ns-filemap-names.XXXXXX")" || return 1
  counts="$(mktemp "${TMPDIR:-/tmp}/ns-filemap-counts.XXXXXX")" || { rm -f "$names"; return 1; }
  if ! git -C "$dir" diff -M --name-status -z "$from" "$to" >"$names.raw" 2>/dev/null ||
    ! git -C "$dir" diff -M --numstat -z "$from" "$to" >"$counts.raw" 2>/dev/null; then
    rm -f "$names" "$counts" "$names.raw" "$counts.raw"
    return 1
  fi
  while IFS= read -r -d '' st; do
    case "$st" in
      R* | C*)
        IFS= read -r -d '' old
        IFS= read -r -d '' p
        printf '%s\t%s\t%s\n' "$p" "${st:0:1}" "$old"
        ;;
      *)
        IFS= read -r -d '' p
        printf '%s\t%s\t\n' "$p" "${st:0:1}"
        ;;
    esac
  done <"$names.raw" >"$names"
  while IFS= read -r -d '' rec; do
    add="${rec%%$'\t'*}"
    rest="${rec#*$'\t'}"
    del="${rest%%$'\t'*}"
    p="${rest#*$'\t'}"
    if [ -z "$p" ]; then
      IFS= read -r -d '' old
      IFS= read -r -d '' p
    fi
    printf '%s\t%s\t%s\n' "$p" "$add" "$del"
  done <"$counts.raw" >"$counts"
  awk -F '\t' -f "$_ns_file_map_dir/file-map-git-rows.awk" "$counts" "$names"
  rm -f "$names" "$counts" "$names.raw" "$counts.raw"
}

# ns_filemap_outputs <receipt> [<work-target> [missing]] — the paths a receipt declares, under any
# heading: relative link targets and backticked paths, one per line, without a leading `./`, sorted
# and unique. Generated blocks and HTML comments are skipped. With a work target, only paths that
# name a file in it are kept; with missing, only the declared paths that name nothing, neither in
# the work target nor beside the receipt where its evidence lives.
ns_filemap_outputs() {
  local path
  { [ -f "$1" ] && [ ! -L "$1" ]; } || return 0
  awk -f "$_ns_file_map_dir/file-map-outputs.awk" "$1" | sed 's#^\./##' | awk 'NF' | LC_ALL=C sort -u | while IFS= read -r path; do
    case "$path" in .. | ../* | */.. | */../*) continue ;; esac
    if [ -z "${2-}" ]; then
      printf '%s\n' "$path"
    elif [ -f "$2/$path" ] && [ ! -L "$2/$path" ]; then
      [ "${3-}" = missing ] || printf '%s\n' "$path"
    elif [ "${3-}" = missing ] && [ ! -e "${1%/*}/$path" ]; then
      printf '%s\n' "$path"
    fi
  done
}

# ns_filemap_render <rows-file> <git|artifact> — the map's summary line and tree. Each row is
# `path\tstatus\told\tadd\tdel`; artifact rows carry the path alone. Paths are grouped under their
# folder; above NS_FILEMAP_COLLAPSE paths, folders collapse into counts at the deepest level that
# fits, and the totals still count every path.
ns_filemap_render() {
  local rows="$1" kind="$2" n lines tab=$'\t'
  n="$(awk 'NF' "$rows" | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then
    if [ "$kind" = git ]; then printf 'No files changed.\n'; else printf 'No outputs declared.\n'; fi
    return 0
  fi
  if [ "$n" -le "$NS_FILEMAP_COLLAPSE" ]; then
    lines="$(awk -F '\t' -f "$_ns_file_map_dir/file-map-split-dir.awk" "$rows" | LC_ALL=C sort -t "$tab" -k1,1 -k2,2 | awk -F '\t' -v kind="$kind" -f "$_ns_file_map_dir/file-map-render-grouped.awk")"
  else
    lines="$(awk -F '\t' -v kind="$kind" -v limit="$NS_FILEMAP_COLLAPSE" -f "$_ns_file_map_dir/file-map-render-collapsed.awk" "$rows" | LC_ALL=C sort -t "$tab" -k1,1 | cut -f2-)"
  fi
  if [ "$kind" = git ]; then
    awk -F '\t' -v n="$n" -v collapsed="$([ "$n" -gt "$NS_FILEMAP_COLLAPSE" ] && echo 1 || echo 0)" -f "$_ns_file_map_dir/file-map-totals.awk" "$rows"
  else
    printf '%s %s declared' "$n" "$([ "$n" -eq 1 ] && echo output || echo outputs)"
    [ "$n" -le "$NS_FILEMAP_COLLAPSE" ] || printf ', folders collapsed'
    printf '\n'
  fi
  printf '\n%stext\n%s\n%s\n' "$NS_FILEMAP_FENCE" "$lines" "$NS_FILEMAP_FENCE"
}

# ns_filemap_summary <page> — the summary line of a drawn map: its counts, that nothing changed, or
# why it is unavailable. Status 1 when there is no page.
ns_filemap_summary() {
  { [ -f "$1" ] && [ ! -L "$1" ]; } || return 1
  awk -f "$_ns_file_map_dir/file-map-summary.awk" "$1"
}

# ns_filemap_tick <nightshift-dir> <project> <item-label> — draw the item's map into its receipt and
# the shift's into receipts/shift-map.md. Called by the gate when it records a tick.
ns_filemap_tick() {
  local ns="$1" project="$2" label="$3" receipt dir target base last head rows body page names f missing
  ns_filemap_enabled "$project" || return 0
  receipt="$(ns_receipt_path "$project" "$label")"
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 0
  dir="$(ns_receipts_dir "$project")"
  rows="$(mktemp "${TMPDIR:-/tmp}/ns-filemap-rows.XXXXXX")" || return 0
  body="$(mktemp "${TMPDIR:-/tmp}/ns-filemap-body.XXXXXX")" || { rm -f "$rows"; return 0; }
  page="$(ns_layout_path "$ns" shift-map)"
  if [ "$(ns_work_mode "$project" 2>/dev/null)" = artifact ]; then
    target="$(ns_work_target "$project" 2>/dev/null)" || target=""
    ns_filemap_outputs "$receipt" "$target" >"$rows"
    missing=""
    [ -z "$target" ] || missing="$(ns_filemap_outputs "$receipt" "$target" missing | awk 'NF { printf "%s`%s`", (n++ ? ", " : ""), $0 }')"
    {
      printf '## File map\n\n'
      ns_filemap_render "$rows" artifact
      # A declared output that names nothing is shown, so a mistyped path is seen at review.
      [ -z "$missing" ] || printf '\nDeclared but not found in the work target: %s\n' "$missing"
    } >"$body"
    ns_receipt_write_block "$receipt" file-map "$body" || :
    names="$(ns_receipts_ticked_names "$project")"
    : >"$rows"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      ns_filemap_outputs "$dir/$f" "$target" >>"$rows"
    done <<EOF
$names
EOF
    LC_ALL=C sort -u "$rows" -o "$rows"
    { printf '# Shift file map\n\nThe outputs the ticked items declare.\n\n'; ns_filemap_render "$rows" artifact; } >"$page" || :
    rm -f "$rows" "$body"
    return 0
  fi
  base="$(ns_filemap_field "$project" base)"
  last="$(ns_filemap_field "$project" last)"
  [ -n "$last" ] || last="$base"
  head=""
  target="$(ns_work_target "$project" 2>/dev/null)" && head="$(git -C "$target" rev-parse --verify --quiet HEAD 2>/dev/null)" || head=""
  if [ -z "$base" ]; then
    printf '## File map\n\nunavailable — no starting commit was recorded when the shift started\n' >"$body"
  elif [ -z "$head" ]; then
    printf '## File map\n\nunavailable — the work target has no readable HEAD\n' >"$body"
  elif ns_filemap_git_rows "$target" "$last" "$head" >"$rows"; then
    { printf '## File map\n\n'; ns_filemap_render "$rows" git; } >"$body"
  else
    printf '## File map\n\nunavailable — git could not read %s..%s\n' "${last:0:12}" "${head:0:12}" >"$body"
  fi
  ns_receipt_write_block "$receipt" file-map "$body" || :
  if [ -n "$base" ] && [ -n "$head" ] && ns_filemap_git_rows "$target" "$base" "$head" >"$rows"; then
    {
      printf '# Shift file map\n\nFrom %s, where the shift started, to %s.\n\n' "${base:0:12}" "${head:0:12}"
      ns_filemap_render "$rows" git
    } >"$page" || :
  elif [ -n "$base" ] && [ -n "$head" ]; then
    printf '# Shift file map\n\nunavailable — git could not read %s..%s\n' "${base:0:12}" "${head:0:12}" >"$page" || :
  else
    printf '# Shift file map\n\nunavailable — no starting commit was recorded when the shift started\n' >"$page" || :
  fi
  [ -z "$head" ] || ns_filemap_set "$project" last "$head" || :
  rm -f "$rows" "$body"
}
