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
# The template is a starting point. An entry is checked only for what code reads, which the
# registry row's rule names.

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

# ns_catalog_entry_problems <file> <rule> [notes] — one reason per line, status 1 when any was
# printed. Only what code reads is checked; the prose and its headings are the author's. <rule> is
# the registry's rule: shift (a title that names the ending, and a text block with a box and a
# Verify line), fence:<lang> (a fence of that language with exactly files, min and type), match (one
# Match line), or empty. HTML comments are not part of the file for this check. With notes, a line
# starting "note: " also says what the entry leaves to the owner, such as a fence rule with no
# fence; a note is never a problem and never changes the status.
ns_catalog_entry_problems() {
  LC_ALL=C awk -v rule="${2-}" -v notes="${3-}" '
    function fail(msg) { print msg; bad = 1 }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN {
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
      if (rule == "shift" && !seen_h1 && line ~ /^# / && line !~ /^## /) {
        seen_h1 = 1
        n = split(substr(line, 3), part, " \xe2\x80\x94 ")
        if (n < 2 || (part[2] != "finite" && part[2] != "open-ended")) fail("H1 must name the ending: finite or open-ended")
        next
      }
      if (line ~ /^```/ && !in_check) {
        if (fence != "" && line ~ ("^```" fence "[[:space:]]*$")) {
          in_check = 1
          seen_fence = 1
          delete seenk
          next
        }
        in_block = !in_block
        if (in_block && line ~ /^```text[[:space:]]*$/) { in_text = 1; box = 0; verify = 0 }
        if (!in_block) {
          if (in_text && box) { any_box = 1; if (verify) item_ok = 1 }
          in_text = 0
        }
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
      if (in_text) {
        if (line ~ /^- \[ \] \*\*/) box = 1
        if (index(line, "Verify:")) verify = 1
        next
      }
      if (in_block) next
      if (rule == "match" && line ~ /^Match:[[:space:]]*/) {
        val = trim(substr(line, 7))
        if (val != "stack" && val != "plugin" && val != "fallback") fail("invalid match")
        if (match_seen) fail("duplicate match")
        match_seen = 1
      }
    }
    END {
      if (rule == "shift" && !seen_h1) fail("H1 must name the ending: finite or open-ended")
      if (rule == "shift" && !any_box) fail("no pasteable item: a text block with a box")
      if (rule == "shift" && any_box && !item_ok) fail("the item has no Verify line")
      if (rule == "match" && !match_seen) fail("missing match")
      if (in_check || in_block) fail("unclosed fence")
      if (notes != "" && fence != "" && !seen_fence) print "note: no " fence " block, so check: block holds only the files an item names"
      exit bad ? 1 : 0
    }
  ' "$1"
}

# _ns_catalog_ingest <dir> <label> <check: yes|no> <missing: report|quiet>
# Lists the markdown files in one directory into the temp index. Defined for _ns_catalog_index,
# which owns tmp, prefix and rule.
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
      problems="$(ns_catalog_entry_problems "$f" "$rule" || true)"
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
    # An entry with no title is listed under its file name.
    case "$meta" in $'\t'*) meta="$key$meta" ;; esac
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

# _ns_catalog_sources <prefix> <plugin-root> <name> <workspace> — the folders a catalog reads, one
# per line, lowest precedence first: folder, label, check (yes|no), missing (report|quiet). The
# shipped folder, the user folders, the configured folders (the first one given wins, so they come
# last to first), then the project folders. Run after ns_catalog_row has set NS_CAT_*.
_ns_catalog_sources() {
  local prefix="$1" root="$2" name="$3" ws="$4" setting raw raw_key configured one dir
  printf '%s\tplugin\tno\tquiet\n' "${root%/}/$NS_CAT_SHIPPED"
  [ -z "$NS_CAT_LEGACY_USER" ] || printf '%s\tuser\tyes\tquiet\n' "$(ns_catalog_user_root)/$NS_CAT_LEGACY_USER"
  printf '%s\tuser\tyes\tquiet\n' "$(ns_catalog_user_root)/catalogs/$name"
  setting="$(ns_catalog_setting "$ws" "$name" paths)"
  raw_key="${setting%%$'\t'*}"
  raw="${setting#*$'\t'}"
  if [ -n "$raw" ]; then
    if ! configured="$(ns_json_string_list "$raw")"; then
      printf '%s: %s could not be read\n' "$prefix" "$raw_key" >&2
      configured=""
    fi
    printf '%s\n' "$configured" | awk 'NF { line[++n] = $0 } END { for (i = n; i >= 1; i--) print line[i] }' |
      while IFS= read -r one; do
        printf '%s\t%s\tyes\treport\n' "$(ns_catalog_resolve "$ws" "$one")" "$one"
      done
  fi
  [ -n "$ws" ] || return 0
  if [ -n "$NS_CAT_LEGACY_PROJECT" ]; then
    dir="$(ns_layout_path "$ws/.nightshift" "$NS_CAT_LEGACY_PROJECT" 2>/dev/null || true)"
    [ -z "$dir" ] || printf '%s\tproject\tyes\tquiet\n' "$dir"
  fi
  dir="$(ns_layout_path "$ws/.nightshift" "catalog-$name" 2>/dev/null || true)"
  [ -z "$dir" ] || printf '%s\tproject\tyes\tquiet\n' "$dir"
}

# _ns_catalog_index <prefix> <plugin-root> <name> <workspace> — every entry once, in the catalog's
# order: key, title, description, source, replaced, file. Problems go to stderr under <prefix>.
_ns_catalog_index() {
  local prefix="$1" root="$2" name="$3" ws="$4"
  local tmp rule sources dir label check missing key meta entry_source replaced file rank
  ns_catalog_row "$name" || return 1
  rule="$NS_CAT_RULE"
  sources="$(_ns_catalog_sources "$prefix" "$root" "$name" "$ws")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ns-catalog.XXXXXX")" || return 1
  (
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/source" "$tmp/meta" "$tmp/replaced" "$tmp/file"
    : >"$tmp/keys"
    # The index lives in files under $tmp, so the loop's writes survive its subshell.
    printf '%s\n' "$sources" | while IFS=$'\t' read -r dir label check missing; do
      [ -n "$dir" ] || continue
      _ns_catalog_ingest "$dir" "$label" "$check" "$missing"
    done
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

# ns_catalog_file <prefix> <plugin-root> <name> <workspace> <key> — the file in force for one key,
# the same one the index lists, found by checking <key>.md in each folder from the highest
# precedence down rather than building the whole index. Status 1 when no folder holds it.
ns_catalog_file() {
  local prefix="$1" root="$2" name="$3" ws="$4" key="$5" sources dir label check missing f
  ns_catalog_row "$name" || return 1
  sources="$(_ns_catalog_sources "$prefix" "$root" "$name" "$ws" 2>/dev/null)"
  while IFS=$'\t' read -r dir label check missing; do
    [ -n "$dir" ] && [ -d "$dir" ] && [ -r "$dir" ] || continue
    f="$dir/$key.md"
    [ -e "$f" ] && [ ! -L "$f" ] && [ -f "$f" ] || continue
    if [ "$check" = yes ]; then
      case "$key" in '' | *[!a-z0-9-]* | -* | *- | *--*) continue ;; esac
      ns_catalog_entry_problems "$f" "$NS_CAT_RULE" >/dev/null || continue
    fi
    printf '%s' "$f"
    return 0
  done <<EOF
$(printf '%s\n' "$sources" | awk 'NF { line[++n] = $0 } END { for (i = n; i >= 1; i--) print line[i] }')
EOF
  return 1
}
