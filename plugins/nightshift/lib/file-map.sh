#!/usr/bin/env bash
# file-map.sh — the files an item and a shift changed, drawn by the runtime at each tick.
#
# With receipts.evidence.fileMap on, the gate's tick writes two maps and the model writes neither:
# the item's, from the commits made since the previous tick, as a generated block at the end of its
# receipt; and the shift's, from the commit the shift started on to HEAD, as receipts/shift-map.md.
# In artifact mode there is no git, so the item map lists the paths the receipt's Outputs section
# declares, and the shift map is the union over the ticked items. A map that cannot be built says
# `unavailable — <reason>`. PowerShell draws the same bytes (Nightshift.07.ps1).
#
# run/file-map records, one key=value per line, the shift it belongs to (shift), the commit that
# shift started on (base) and HEAD at the last tick (last).

NS_FILEMAP_COLLAPSE=40
NS_FILEMAP_OPEN='<!-- nightshift:file-map -->'
NS_FILEMAP_CLOSE='<!-- /nightshift:file-map -->'
NS_FILEMAP_FENCE="\`\`\`"

# ns_filemap_enabled <project> — status 0 when the owner asked for file maps.
ns_filemap_enabled() {
  [ "$(ns_receipts "$1" evidence.fileMap 2>/dev/null)" = on ]
}

# ns_filemap_field <project> <key> — one value from run/file-map, or nothing.
ns_filemap_field() {
  local f line
  ns_layout_set f "$1/.nightshift" file-map
  { [ -f "$f" ] && [ ! -L "$f" ]; } || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) printf '%s' "${line#*=}"; return 0 ;; esac
  done <"$f"
}

# ns_filemap_set <project> <key> <value> — write one value into run/file-map, keeping the others.
ns_filemap_set() {
  local f tmp line
  ns_layout_set f "$1/.nightshift" file-map
  [ ! -L "$f" ] || return 1
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  tmp="$f.$$"
  {
    if [ -f "$f" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$2="*) ;; *) printf '%s\n' "$line" ;; esac
      done <"$f"
    fi
    printf '%s=%s\n' "$2" "$3"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# ns_filemap_start <project> — record the commit tonight's shift starts on, once per shift. Nothing
# is written while file maps are off or the work target is not a repository.
ns_filemap_start() {
  local project="$1" sid target head
  ns_filemap_enabled "$project" || return 0
  [ "$(ns_work_mode "$project" 2>/dev/null)" = repository ] || return 0
  sid="$(ns_policy_shift_id "$project" 2>/dev/null)" || sid=""
  if [ -n "$(ns_filemap_field "$project" base)" ] && [ "$(ns_filemap_field "$project" shift)" = "$sid" ]; then
    return 0
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
  awk -F '\t' '
    NR == FNR { add[$1] = $2; del[$1] = $3; next }
    { a = ($1 in add) ? add[$1] : "0"; d = ($1 in del) ? del[$1] : "0"; print $1 "\t" $2 "\t" $3 "\t" a "\t" d }
  ' "$counts" "$names"
  rm -f "$names" "$counts" "$names.raw" "$counts.raw"
}

# ns_filemap_outputs <receipt> — the paths a receipt's Outputs section declares: relative link
# targets and backticked paths, one per line, without a leading `./`, sorted and unique.
ns_filemap_outputs() {
  { [ -f "$1" ] && [ ! -L "$1" ]; } || return 0
  awk '
    { sub(/\r$/, "") }
    /^## / { inside = ($0 == "## Outputs"); next }
    !inside { next }
    {
      line = $0
      while (match(line, /\]\([^)]+\)/)) {
        t = substr(line, RSTART + 2, RLENGTH - 3)
        line = substr(line, RSTART + RLENGTH)
        sub(/[ \t].*$/, "", t)
        if (t ~ /^[a-z][a-z0-9+.-]*:/ || t ~ /^#/ || t ~ /^\//) continue
        print t
      }
      line = $0
      while (match(line, /`[^`]+`/)) {
        t = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        if (t ~ /[ \t]/ || t ~ /^[a-z][a-z0-9+.-]*:/ || t ~ /^\//) continue
        if (t !~ /\// && t !~ /\.[A-Za-z0-9]+$/) continue
        print t
      }
    }
  ' "$1" | sed 's#^\./##' | awk 'NF' | LC_ALL=C sort -u
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
    lines="$(awk -F '\t' 'NF {
        p = $1; d = ""; b = p
        i = match(p, /\/[^\/]*$/)
        if (i) { d = substr(p, 1, i - 1); b = substr(p, i + 1) }
        print d "\t" b "\t" $2 "\t" $3 "\t" $4 "\t" $5
      }' "$rows" | LC_ALL=C sort -t "$tab" -k1,1 -k2,2 | awk -F '\t' -v kind="$kind" '
      function counts() { return ($5 == "-") ? "binary" : "+" $5 " -" $6 }
      {
        if (NR == 1 || $1 != dir) { dir = $1; print (dir == "" ? "./" : dir "/") }
        if (kind == "git") {
          line = "  " $3 " " $2 "  " counts()
          if ($4 != "") line = line "  (from " $4 ")"
        } else {
          line = "  " $2
        }
        print line
      }')"
  else
    lines="$(awk -F '\t' -v kind="$kind" -v limit="$NS_FILEMAP_COLLAPSE" '
      NF { n++; path[n] = $1; st[n] = $2; old[n] = $3; add[n] = $4; del[n] = $5 }
      function keyof(p, depth,    parts, c, k, j) {
        c = split(p, parts, "/")
        if (c - 1 < depth) return p
        k = parts[1]
        for (j = 2; j <= depth; j++) k = k "/" parts[j]
        return k "/"
      }
      END {
        for (depth = 3; depth >= 1; depth--) {
          split("", seen); rows = 0
          for (i = 1; i <= n; i++) { k = keyof(path[i], depth); if (!(k in seen)) { seen[k] = 1; rows++ } }
          if (rows <= limit || depth == 1) break
        }
        for (i = 1; i <= n; i++) {
          k = keyof(path[i], depth)
          if (k ~ /\/$/) {
            files[k]++
            if (add[i] != "-") { plus[k] += add[i]; minus[k] += del[i] }
            continue
          }
          if (kind == "git") {
            line = st[i] " " path[i] "  " ((add[i] == "-") ? "binary" : "+" add[i] " -" del[i])
            if (old[i] != "") line = line "  (from " old[i] ")"
          } else {
            line = path[i]
          }
          print k "\t" line
        }
        for (k in files) {
          if (kind == "git") line = k "  " files[k] (files[k] == 1 ? " file" : " files") "  +" (plus[k] + 0) " -" (minus[k] + 0)
          else line = k "  " files[k] (files[k] == 1 ? " output" : " outputs")
          print k "\t" line
        }
      }' "$rows" | LC_ALL=C sort -t "$tab" -k1,1 | cut -f2-)"
  fi
  if [ "$kind" = git ]; then
    awk -F '\t' -v n="$n" -v collapsed="$([ "$n" -gt "$NS_FILEMAP_COLLAPSE" ] && echo 1 || echo 0)" '
      NF && $4 != "-" { a += $4; d += $5 }
      END {
        printf "%d %s changed, +%d -%d", n, (n == 1 ? "file" : "files"), a, d
        if (collapsed) printf ", folders collapsed"
        printf "\n"
      }' "$rows"
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
  awk '
    { sub(/\r$/, "") }
    /^[0-9]+ (file|files|output|outputs) / || /^No (files changed|outputs declared)\.$/ || /^unavailable — / { print; exit }
  ' "$1"
}

# ns_filemap_write_block <receipt> <body-file> — put the generated block at the end of the receipt,
# replacing the one already there, so a refresh never draws it twice. The receipt keeps its time.
ns_filemap_write_block() {
  local f="$1" body="$2" ref tmp rc=0
  { [ -f "$f" ] && [ ! -L "$f" ]; } || return 1
  ref="$f.mtime.$$"
  touch -r "$f" "$ref" 2>/dev/null || return 1
  tmp="$f.filemap.$$"
  if awk -v first="$NS_FILEMAP_OPEN" -v last="$NS_FILEMAP_CLOSE" -v bodyfile="$body" '
    { line = $0; sub(/\r$/, "", line) }
    line == first { skip = 1; next }
    skip && line == last { skip = 0; next }
    skip { next }
    { kept[++n] = $0 }
    END {
      while (n > 0 && kept[n] ~ /^[[:space:]]*\r?$/) n--
      for (i = 1; i <= n; i++) print kept[i]
      if (n > 0) print ""
      print first
      while ((getline l < bodyfile) > 0) print l
      print last
    }' "$f" >"$tmp" && mv "$tmp" "$f"; then
    :
  else
    rm -f "$tmp"
    rc=1
  fi
  touch -r "$ref" "$f" 2>/dev/null || rc=1
  rm -f "$ref"
  return "$rc"
}

# ns_filemap_tick <nightshift-dir> <project> <item-label> — draw the item's map into its receipt and
# the shift's into receipts/shift-map.md. Called by the gate when it records a tick.
ns_filemap_tick() {
  local ns="$1" project="$2" label="$3" receipt dir target base last head rows body page names f
  ns_filemap_enabled "$project" || return 0
  receipt="$(ns_receipt_path "$project" "$label")"
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 0
  dir="$(ns_receipts_dir "$project")"
  rows="$(mktemp "${TMPDIR:-/tmp}/ns-filemap-rows.XXXXXX")" || return 0
  body="$(mktemp "${TMPDIR:-/tmp}/ns-filemap-body.XXXXXX")" || { rm -f "$rows"; return 0; }
  page="$(ns_layout_path "$ns" shift-map)"
  if [ "$(ns_work_mode "$project" 2>/dev/null)" = artifact ]; then
    ns_filemap_outputs "$receipt" >"$rows"
    { printf '## File map\n\n'; ns_filemap_render "$rows" artifact; } >"$body"
    ns_filemap_write_block "$receipt" "$body" || :
    names="$(ns_receipts_ticked_names "$project")"
    : >"$rows"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      ns_filemap_outputs "$dir/$f" >>"$rows"
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
  ns_filemap_write_block "$receipt" "$body" || :
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
