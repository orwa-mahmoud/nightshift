#!/usr/bin/env bash
# catalog-sources.sh — where a catalog's entries live, and one index of them.
#
# The catalog name and the entry-folder name are arguments. This file resolves the per-user
# folder, a path the owner wrote (a tilde, an absolute path, or a path relative to the workspace),
# and lists every entry once: project, then the configured folders in the order given, then the
# user folder, then the shipped directory. A later source replaces an earlier one and the line
# names what it replaced. A file that fails the caller's structural check is reported and left
# out. A symlink is skipped.
#
# The structural check reads three globals the caller sets, so this file stays a catalog tool and
# not a catalog of its own:
#   NS_CATALOG_HEADINGS    required H2 names, separated by |
#   NS_CATALOG_BULLET      the H2 that must contain one "- " line, or empty
#   NS_CATALOG_FENCE       a fence language that, when present, must carry the keys below
#   NS_CATALOG_FENCE_KEYS  those keys, separated by spaces
#   NS_CATALOG_FENCE_TYPES allowed values of a key named type, separated by spaces
#   NS_CATALOG_MATCH       yes when the file must carry one Match line of stack, plugin, or fallback
#
# ns_catalog_entry_problems prints one reason per line and returns 1 when the file fails.
# ns_catalog_list prints the index on stdout and the reasons on stderr, and returns 0.

# ns_catalog_user_dir <catalog> <entries> — the per-user folder for this catalog.
# One formula: the XDG config home, then nightshift, then the catalog and its entry folder.
ns_catalog_user_dir() {
  printf '%s/nightshift/%s/%s' "${XDG_CONFIG_HOME:-$HOME/.config}" "$1" "$2"
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

# ns_catalog_entry_problems <file> — one reason per line. Status 1 when any reason was printed.
# HTML comments are not part of the file for this check, so a commented example is not live.
ns_catalog_entry_problems() {
  LC_ALL=C awk \
    -v headings="${NS_CATALOG_HEADINGS-}" \
    -v bullet="${NS_CATALOG_BULLET-}" \
    -v fence="${NS_CATALOG_FENCE-}" \
    -v keys="${NS_CATALOG_FENCE_KEYS-}" \
    -v types="${NS_CATALOG_FENCE_TYPES-}" \
    -v matchmode="${NS_CATALOG_MATCH-}" '
    function fail(msg) { print msg; bad = 1 }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN {
      nhead = split(headings, need, "|")
      nkey = split(keys, allowed, " ")
      ntype = split(types, allowed_type, " ")
      bad = 0
      in_comment = 0
      in_fence = 0
      seen_h1 = 0
      bullet_on = 0
      bullet_found = 0
      match_seen = 0
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
        next
      }
      if (line ~ /^## /) {
        name = trim(substr(line, 4))
        found[name] = 1
        bullet_on = (bullet != "" && name == bullet) ? 1 : 0
        next
      }
      if (bullet_on && line ~ /^- /) bullet_found = 1
      if (matchmode == "yes" && line ~ /^Match:[[:space:]]*/) {
        val = trim(substr(line, 7))
        if (val != "stack" && val != "plugin" && val != "fallback") fail("invalid match")
        if (match_seen) fail("duplicate match")
        match_seen = 1
        next
      }
      if (fence != "" && line ~ ("^```" fence "[[:space:]]*$")) {
        if (in_fence) fail("nested fence")
        in_fence = 1
        delete seenk
        next
      }
      if (in_fence && line ~ /^```[[:space:]]*$/) {
        for (k = 1; k <= nkey; k++) {
          if (allowed[k] != "" && !(allowed[k] in seenk)) fail("missing key")
        }
        in_fence = 0
        next
      }
      if (in_fence) {
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
    }
    END {
      if (!seen_h1) fail("missing H1")
      for (h = 1; h <= nhead; h++) {
        if (need[h] != "" && !(need[h] in found)) fail("missing section " need[h])
      }
      if (bullet != "" && (bullet in found) && !bullet_found) fail("no bullet")
      if (matchmode == "yes" && !match_seen) fail("missing match")
      if (in_fence) fail("unclosed fence")
      exit bad ? 1 : 0
    }
  ' "$1"
}

# _ns_catalog_ingest <dir> <label> <check: yes|no> <missing: report|quiet>
# Lists the markdown files in one directory into the temp index. Defined for ns_catalog_list.
_ns_catalog_ingest() {
  local dir="$1" label="$2" check="$3" missing="$4"
  local f base key line problems meta title description old prev
  if [ -z "$dir" ]; then
    return 0
  fi
  if [ ! -e "$dir" ]; then
    if [ "$missing" = report ]; then
      printf '%s: configured folder missing: %s\n' "$prefix" "$label" >&2
    fi
    return 0
  fi
  if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
    if [ "$missing" = report ]; then
      printf '%s: configured folder unreadable: %s\n' "$prefix" "$label" >&2
    fi
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
      problems="$(ns_catalog_entry_problems "$f" || true)"
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
    title="${meta%%$'\t'*}"
    case "$meta" in
      *$'\t'*) description="${meta#*$'\t'}" ;;
      *) description="" ;;
    esac
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
    printf '%s\t%s' "$title" "$description" >"$tmp/meta/$key"
  done
}

# ns_catalog_list <prefix> <plugin-dir> <project-dir> <user-dir> [<label> <dir>]...
# Configured folders follow the four fixed arguments, as label/dir pairs. The first pair wins
# over the pairs after it. Project wins over every pair, the pairs win over the user folder, and
# the user folder wins over the shipped directory. A missing project or user directory is normal.
# A missing configured directory is reported under <prefix>.
ns_catalog_list() {
  local prefix="$1" plugin_dir="$2" project_dir="$3" user_dir="$4"
  shift 4
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ns-catalog.XXXXXX")" || return 1
  (
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/source" "$tmp/meta" "$tmp/replaced"
    : >"$tmp/keys"
    _ns_catalog_ingest "$plugin_dir" plugin no quiet
    _ns_catalog_ingest "$user_dir" user yes quiet
    if [ "$#" -gt 0 ]; then
      pairs=("$@")
      i=$((${#pairs[@]} - 2))
      while [ "$i" -ge 0 ]; do
        _ns_catalog_ingest "${pairs[$((i + 1))]}" "${pairs[$i]}" yes report
        i=$((i - 2))
      done
    fi
    _ns_catalog_ingest "$project_dir" project yes quiet
    if [ -s "$tmp/keys" ]; then
      LC_ALL=C sort -u "$tmp/keys" | while IFS= read -r key; do
        [ -n "$key" ] || continue
        IFS= read -r meta <"$tmp/meta/$key" || true
        IFS= read -r source <"$tmp/source/$key" || true
        replaced=""
        IFS= read -r replaced <"$tmp/replaced/$key" || true
        printf '%s\t%s\t%s\t%s\n' "$key" "$meta" "$source" "$replaced"
      done
    fi
  )
}
