#!/usr/bin/env bash
# catalog-sources.sh — every catalog through one model.
#
# lib/catalogs.tsv names each catalog: where its shipped entries live, its template, its order, and
# the one rule its template cannot express. Everything else follows from the name. An owner adds
# entries in .nightshift/catalogs/<name>/ (this project), in <user config>/nightshift/catalogs/<name>/
# (every project on the machine), or in the folders catalogs.<name>.paths names; the template in
# force is catalogs.<name>.template, else the shipped one. The folders and keys an earlier version
# read stay honoured, listed in the registry's legacy columns.
#
# Precedence, highest first: the project folder, the configured folders in the order given, the
# user folder, the shipped directory. A later source replaces an earlier one and the index names
# what it replaced. An owner entry that fails its check is reported on stderr and left out. A
# symlink is skipped.
#
# The template is the schema: its H2 headings are the sections every entry needs, and a section
# whose template text shows a bullet needs one in the entry.

_NS_CATALOGS_TSV="${BASH_SOURCE[0]%/*}"
[ "$_NS_CATALOGS_TSV" != "${BASH_SOURCE[0]}" ] || _NS_CATALOGS_TSV=.
_NS_CATALOGS_TSV="$_NS_CATALOGS_TSV/catalogs.tsv"

# ns_catalog_names — every catalog name, in registry order.
ns_catalog_names() {
  awk -F '\t' '!/^#/ && NF >= 9 { print $1 }' "$_NS_CATALOGS_TSV"
}

# ns_catalog_row <name> — sets NS_CAT_SHIPPED NS_CAT_TEMPLATE NS_CAT_ORDER NS_CAT_RULE
# NS_CAT_LEGACY_PROJECT NS_CAT_LEGACY_USER NS_CAT_LEGACY_PATHS NS_CAT_LEGACY_TEMPLATE from the
# registry. A "-" column reads as empty. Status 1 for a name the registry does not hold.
ns_catalog_row() {
  local row
  row="$(awk -F '\t' -v n="$1" '!/^#/ && NF >= 9 && $1 == n { print; exit }' "$_NS_CATALOGS_TSV")"
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r _ NS_CAT_SHIPPED NS_CAT_TEMPLATE NS_CAT_ORDER NS_CAT_RULE \
    NS_CAT_LEGACY_PROJECT NS_CAT_LEGACY_USER NS_CAT_LEGACY_PATHS NS_CAT_LEGACY_TEMPLATE <<EOF
$row
EOF
  [ "$NS_CAT_RULE" != - ] || NS_CAT_RULE=""
  [ "$NS_CAT_LEGACY_PROJECT" != - ] || NS_CAT_LEGACY_PROJECT=""
  [ "$NS_CAT_LEGACY_USER" != - ] || NS_CAT_LEGACY_USER=""
  [ "$NS_CAT_LEGACY_PATHS" != - ] || NS_CAT_LEGACY_PATHS=""
  [ "$NS_CAT_LEGACY_TEMPLATE" != - ] || NS_CAT_LEGACY_TEMPLATE=""
  return 0
}

# ns_catalog_user_root — the per-user Nightshift folder: the XDG config home, then nightshift.
ns_catalog_user_root() {
  printf '%s/nightshift' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# ns_catalog_resolve <workspace> <path> — a tilde, an absolute path, or a workspace-relative path.
ns_catalog_resolve() {
  local ws="$1" path="$2" home="${HOME:-}" tilde='~'
  case "$path" in
    '') return 0 ;;
    "$tilde") printf '%s' "$home" ;;
    "$tilde"/*) printf '%s/%s' "$home" "${path#"$tilde"/}" ;;
    /*) printf '%s' "$path" ;;
    *)
      if [ -n "$ws" ]; then
        printf '%s/%s' "${ws%/}" "$path"
      else
        printf '%s' "$path"
      fi
      ;;
  esac
}

# _ns_catalog_rules_value <workspace> <dotted-key> — one value straight from the owner's rules file,
# for a legacy key the resolved view no longer carries. Empty when absent.
_ns_catalog_rules_value() {
  local f group field
  [ -n "$1" ] || return 0
  ns_layout_set f "$1/.nightshift" rules 2>/dev/null || return 0
  [ -f "$f" ] || return 0
  group="${2%%.*}"
  field="${2#*.}"
  ns_rules_get_in "$f" "$group" "$field"
}

# ns_catalog_setting <workspace> <name> <paths|template> — the owner's value for this catalog and
# the key that holds it, tab-separated: catalogs.<name>.<field>, else the legacy key the registry
# names. Prints nothing when neither is set.
ns_catalog_setting() {
  local ws="$1" name="$2" field="$3" v="" key legacy
  [ -n "$ws" ] || return 0
  ns_catalog_row "$name" || return 1
  key="catalogs.$name.$field"
  v="$(ns_policy_pref "$ws" catalogs "$name.$field" 2>/dev/null || true)"
  case "$v" in '' | null | '[]') v="" ;; esac
  if [ -z "$v" ]; then
    if [ "$field" = paths ]; then legacy="$NS_CAT_LEGACY_PATHS"; else legacy="$NS_CAT_LEGACY_TEMPLATE"; fi
    if [ -n "$legacy" ]; then
      key="$legacy"
      v="$(_ns_catalog_rules_value "$ws" "$legacy")"
      case "$v" in null | '[]') v="" ;; esac
    fi
  fi
  [ -z "$v" ] || printf '%s\t%s' "$key" "$v"
}

# ns_catalog_template <plugin-root> <workspace> <name> — the template in force.
ns_catalog_template() {
  local root="$1" ws="$2" name="$3" setting
  ns_catalog_row "$name" || return 1
  setting="$(ns_catalog_setting "$ws" "$name" template)"
  setting="${setting#*$'\t'}"
  if [ -n "$setting" ]; then
    ns_catalog_resolve "$ws" "$setting"
  else
    printf '%s/%s' "${root%/}" "$NS_CAT_TEMPLATE"
  fi
}

# ns_catalog_shape <template> — the template as a schema, one line: the required H2 names separated
# by |, a tab, then the names of the sections that need a bullet, separated by |. Comments and
# fenced blocks are not part of the shape.
ns_catalog_shape() {
  LC_ALL=C awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    {
      line = $0
      sub(/\r$/, "", line)
      if (in_comment) {
        if (index(line, "-->")) in_comment = 0
        next
      }
      if (line ~ /^<!--/) {
        if (!index(line, "-->")) in_comment = 1
        next
      }
      if (line ~ /^```/) { in_fence = !in_fence; next }
      if (in_fence) next
      if (line ~ /^## /) {
        name = trim(substr(line, 4))
        heads = heads (heads == "" ? "" : "|") name
        cur = name
        next
      }
      if (cur != "" && line ~ /^- / && !(cur in bulleted)) {
        bulleted[cur] = 1
        bullets = bullets (bullets == "" ? "" : "|") cur
      }
    }
    END { printf "%s\t%s\n", heads, bullets }
  ' "$1"
}

# ns_catalog_read_heading <file> — the H1 as title and description, separated by a tab.
# The split is the em dash the catalogs use. No H1 prints nothing.
ns_catalog_read_heading() {
  LC_ALL=C awk '
    /^# / && !/^## / && !seen {
      seen = 1
      line = substr($0, 3)
      n = split(line, part, " \xe2\x80\x94 ")
      title = part[1]
      description = ""
      for (i = 2; i <= n; i++) {
        description = description (i == 2 ? "" : " \xe2\x80\x94 ") part[i]
      }
      gsub(/\t/, " ", title)
      gsub(/\t/, " ", description)
      printf "%s\t%s", title, description
      exit
    }
  ' "$1"
}

# ns_catalog_entry_problems <file> <shape> <rule> — one reason per line, status 1 when any was
# printed. <shape> is what ns_catalog_shape printed for the template in force. <rule> is the
# registry's rule: shift (an H1 that names the ending, and an item block with a box and a Verify
# line), fence:<lang> (a fence of that language with exactly files, min and type), match (one Match
# line), or empty.
# HTML comments are not part of the file for this check, so a commented example is not live.
ns_catalog_entry_problems() {
  local headings bullets
  headings="${2%%$'\t'*}"
  bullets="${2#*$'\t'}"
  LC_ALL=C awk -v headings="$headings" -v bullets="$bullets" -v rule="${3-}" '
    function fail(msg) { print msg; bad = 1 }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN {
      nhead = split(headings, need, "|")
      nbul = split(bullets, needbullet, "|")
      for (b = 1; b <= nbul; b++) wantbullet[needbullet[b]] = 1
      nkey = split("files min type", allowed, " ")
      ntype = split("image text json any", allowed_type, " ")
      fence = (substr(rule, 1, 6) == "fence:") ? substr(rule, 7) : ""
    }
    {
      rest = $0
      sub(/\r$/, "", rest)
      line = ""
      while (length(rest) > 0) {
        if (in_comment) {
          i = index(rest, "-->")
          if (i == 0) { rest = ""; break }
          rest = substr(rest, i + 3)
          in_comment = 0
          continue
        }
        i = index(rest, "<!--")
        if (i == 0) { line = line rest; rest = ""; break }
        line = line substr(rest, 1, i - 1)
        rest = substr(rest, i + 4)
        in_comment = 1
      }
      if (in_comment) next
      if (!seen_h1 && line ~ /^# / && line !~ /^## /) {
        seen_h1 = 1
        n = split(substr(line, 3), part, " \xe2\x80\x94 ")
        if (n < 2 || part[1] == "" || part[2] == "") fail("missing H1")
        if (rule == "shift" && (n < 3 || (part[2] != "finite" && part[2] != "open-ended"))) fail("H1 must name the ending: finite or open-ended")
        next
      }
      if (line ~ /^```/ && !in_check) {
        if (fence != "" && line ~ ("^```" fence "[[:space:]]*$")) {
          in_check = 1
          delete seenk
          next
        }
        in_block = !in_block
        if (in_block && cur == "Item" && line ~ /^```text[[:space:]]*$/) in_item = 1
        if (!in_block) in_item = 0
        next
      }
      if (in_check && line ~ /^```[[:space:]]*$/) {
        for (k = 1; k <= nkey; k++) if (!(allowed[k] in seenk)) fail("missing key")
        in_check = 0
        next
      }
      if (in_check) {
        if (line !~ /^[a-z]+:[[:space:]]*[^[:space:]].*$/) { fail("unknown key"); next }
        key = line
        sub(/:.*/, "", key)
        ok = 0
        for (k = 1; k <= nkey; k++) if (allowed[k] == key) ok = 1
        if (!ok) { fail("unknown key"); next }
        if (key in seenk) { fail("duplicate key"); next }
        val = line
        sub(/^[^:]+:[[:space:]]*/, "", val)
        if (key == "min" && val !~ /^[1-9][0-9]*$/) fail("invalid min")
        if (key == "type") {
          ok = 0
          for (k = 1; k <= ntype; k++) if (allowed_type[k] == val) ok = 1
          if (!ok) fail("invalid type")
        }
        seenk[key] = val
        next
      }
      if (in_item) {
        if (line ~ /^- \[ \] \*\*/) item_box = 1
        if (index(line, "Verify:")) item_verify = 1
        next
      }
      if (in_block) next
      if (line ~ /^## /) {
        cur = trim(substr(line, 4))
        found[cur] = 1
        next
      }
      if (cur in wantbullet && line ~ /^- /) hasbullet[cur] = 1
      if (rule == "match" && line ~ /^Match:[[:space:]]*/) {
        val = trim(substr(line, 7))
        if (val != "stack" && val != "plugin" && val != "fallback") fail("invalid match")
        if (match_seen) fail("duplicate match")
        match_seen = 1
      }
    }
    END {
      if (!seen_h1) fail("missing H1")
      for (h = 1; h <= nhead; h++) {
        if (need[h] != "" && !(need[h] in found)) fail("missing section " need[h])
      }
      for (b = 1; b <= nbul; b++) {
        if (needbullet[b] != "" && (needbullet[b] in found) && !(needbullet[b] in hasbullet)) fail("no bullet in " needbullet[b])
      }
      if (rule == "match" && !match_seen) fail("missing match")
      if (rule == "shift" && !item_box) fail("the Item section has no pasteable box")
      if (rule == "shift" && !item_verify) fail("the Item section has no Verify line")
      if (in_check || in_block) fail("unclosed fence")
      exit bad ? 1 : 0
    }
  ' "$1"
}

# _ns_catalog_ingest <dir> <label> <check: yes|no> <missing: report|quiet>
# Lists the markdown files in one directory into the temp index. Defined for _ns_catalog_index,
# which owns tmp, prefix, shape and rule.
_ns_catalog_ingest() {
  local dir="$1" label="$2" check="$3" missing="$4"
  local f base key line problems meta old prev
  [ -n "$dir" ] || return 0
  if [ ! -e "$dir" ]; then
    [ "$missing" = report ] && printf '%s: configured folder missing: %s\n' "$prefix" "$label" >&2
    return 0
  fi
  if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
    [ "$missing" = report ] && printf '%s: configured folder unreadable: %s\n' "$prefix" "$label" >&2
    return 0
  fi
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    [ -L "$f" ] && continue
    [ -f "$f" ] || continue
    base="${f##*/}"
    key="${base%.md}"
    case "$key" in
      '' | *[!a-z0-9-]* | -* | *- | *--*)
        if [ "$check" = yes ]; then
          printf '%s: %s: malformed file name\n' "$prefix" "$f" >&2
          continue
        fi
        ;;
    esac
    if [ "$check" = yes ]; then
      problems="$(ns_catalog_entry_problems "$f" "$shape" "$rule" || true)"
      if [ -n "$problems" ]; then
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          printf '%s: %s: %s\n' "$prefix" "$f" "$line" >&2
        done <<EOF
$problems
EOF
        continue
      fi
    fi
    meta="$(ns_catalog_read_heading "$f")"
    case "$meta" in *$'\t'*) ;; *) meta="$meta"$'\t' ;; esac
    if [ -f "$tmp/source/$key" ]; then
      old=""
      IFS= read -r old <"$tmp/source/$key" || true
      prev=""
      IFS= read -r prev <"$tmp/replaced/$key" || true
      if [ -n "$prev" ]; then
        printf '%s, %s' "$old" "$prev" >"$tmp/replaced/$key"
      else
        printf '%s' "$old" >"$tmp/replaced/$key"
      fi
    else
      printf '%s\n' "$key" >>"$tmp/keys"
      : >"$tmp/replaced/$key"
    fi
    printf '%s' "$label" >"$tmp/source/$key"
    printf '%s' "$meta" >"$tmp/meta/$key"
    printf '%s' "$f" >"$tmp/file/$key"
  done
}

# _ns_catalog_rank <file> — 0 for Match: stack or none, 1 for plugin, 2 for fallback.
_ns_catalog_rank() {
  case "$(awk '/^Match:[[:space:]]*/ { sub(/^Match:[[:space:]]*/, ""); print; exit }' "$1")" in
    plugin) printf 1 ;;
    fallback) printf 2 ;;
    *) printf 0 ;;
  esac
}

# _ns_catalog_index <prefix> <plugin-root> <name> <workspace> — every entry once, in the catalog's
# order: key, title, description, source, replaced, file. Problems go to stderr under <prefix>.
_ns_catalog_index() {
  local prefix="$1" root="$2" name="$3" ws="$4"
  local tmp shape rule template setting raw raw_key project_dir legacy_project_dir user_dir legacy_user_dir
  local configured one key meta entry_source replaced file rank
  ns_catalog_row "$name" || return 1
  rule="$NS_CAT_RULE"
  template="$(ns_catalog_template "$root" "$ws" "$name")"
  shape="$(ns_catalog_shape "$template" 2>/dev/null)" || shape=""
  project_dir=""
  legacy_project_dir=""
  if [ -n "$ws" ]; then
    project_dir="$(ns_layout_path "$ws/.nightshift" "catalog-$name" 2>/dev/null || true)"
    if [ -n "$NS_CAT_LEGACY_PROJECT" ]; then
      legacy_project_dir="$(ns_layout_path "$ws/.nightshift" "$NS_CAT_LEGACY_PROJECT" 2>/dev/null || true)"
    fi
  fi
  user_dir="$(ns_catalog_user_root)/catalogs/$name"
  legacy_user_dir=""
  [ -z "$NS_CAT_LEGACY_USER" ] || legacy_user_dir="$(ns_catalog_user_root)/$NS_CAT_LEGACY_USER"
  setting="$(ns_catalog_setting "$ws" "$name" paths)"
  raw_key="${setting%%$'\t'*}"
  raw="${setting#*$'\t'}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ns-catalog.XXXXXX")" || return 1
  (
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/source" "$tmp/meta" "$tmp/replaced" "$tmp/file"
    : >"$tmp/keys"
    _ns_catalog_ingest "${root%/}/$NS_CAT_SHIPPED" plugin no quiet
    _ns_catalog_ingest "$legacy_user_dir" user yes quiet
    _ns_catalog_ingest "$user_dir" user yes quiet
    if [ -n "$raw" ]; then
      if ! configured="$(ns_json_string_list "$raw")"; then
        printf '%s: %s could not be read\n' "$prefix" "$raw_key" >&2
        configured=""
      fi
      # The first configured folder wins, so they are ingested last to first. The index lives in
      # files under $tmp, so the loop's writes survive its subshell.
      printf '%s\n' "$configured" | awk 'NF { line[++n] = $0 } END { for (i = n; i >= 1; i--) print line[i] }' |
        while IFS= read -r one; do
          _ns_catalog_ingest "$(ns_catalog_resolve "$ws" "$one")" "$one" yes report
        done
    fi
    _ns_catalog_ingest "$legacy_project_dir" project yes quiet
    _ns_catalog_ingest "$project_dir" project yes quiet
    [ -s "$tmp/keys" ] || exit 0
    LC_ALL=C sort -u "$tmp/keys" | while IFS= read -r key; do
      [ -n "$key" ] || continue
      meta="$(cat "$tmp/meta/$key")"
      entry_source="$(cat "$tmp/source/$key")"
      replaced="$(cat "$tmp/replaced/$key")"
      file="$(cat "$tmp/file/$key")"
      rank=0
      [ "$NS_CAT_ORDER" != match ] || rank="$(_ns_catalog_rank "$file")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rank" "$key" "$meta" "$entry_source" "$replaced" "$file"
    done | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 | cut -f 2-
  )
}

# ns_catalog_list <prefix> <plugin-root> <name> <workspace> — the index: key, title, description,
# source, and the sources a same key replaced, tab-separated, in the catalog's order.
ns_catalog_list() {
  _ns_catalog_index "$@" | cut -f 1-5
}

# ns_catalog_file <prefix> <plugin-root> <name> <workspace> <key> — the file in force for one key.
# Status 1 when no source holds it.
ns_catalog_file() {
  local line
  line="$(_ns_catalog_index "$1" "$2" "$3" "$4" 2>/dev/null | awk -F '\t' -v k="$5" '$1 == k { print; exit }')"
  [ -n "$line" ] || return 1
  printf '%s' "${line##*$'\t'}"
}
