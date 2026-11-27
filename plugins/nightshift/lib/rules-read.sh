#!/usr/bin/env bash
# Strict-subset reader for Nightshift's rules.json.
#
# One owner file, one shape: the shipped template's objects, strings, bools,
# integers, and string arrays. Comments, trailing commas, unknown types, and
# unexpected nesting fail closed. Never a second store. Never a general parser.

NS_RULES_ERR=""
NS_RULES_ROWS=""
NS_RULES_FILE=""
NS_RULES_STAMP=""
NS_RULES_MAP=""
NS_RULES_MAP_SRC=""

_NS_RULES_NL='
'
_NS_RULES_TAB=$(printf '\t')

# The program sits next to this file, resolved without dirname so a hostile PATH
# cannot reach a different reader.
_NS_RULES_AWK_FILE="${BASH_SOURCE[0]%/*}"
[ "$_NS_RULES_AWK_FILE" != "${BASH_SOURCE[0]}" ] || _NS_RULES_AWK_FILE=.
_NS_RULES_AWK_FILE="$_NS_RULES_AWK_FILE/rules-read.awk"

# ns_rules_awk_bin — awk on PATH, or NS_RULES_AWK when a test pins one.
ns_rules_awk_bin() {
  if [ -n "${NS_RULES_AWK:-}" ]; then
    printf '%s' "$NS_RULES_AWK"
    return 0
  fi
  command -v awk
}

# _ns_rules_scan <mode> [file|-] — path/type/value rows on stdout. Status 1
# prints ERR<TAB>reason on stdout.
_ns_rules_scan() {
  local bin
  bin="$(ns_rules_awk_bin)" || {
    printf 'ERR%srules.json cannot be read\n' "$_NS_RULES_TAB"
    return 1
  }
  if [ ! -f "$_NS_RULES_AWK_FILE" ]; then
    printf 'ERR%sNightshift file missing: %s\n' "$_NS_RULES_TAB" "$_NS_RULES_AWK_FILE"
    return 1
  fi
  "$bin" -v mode="$1" -f "$_NS_RULES_AWK_FILE" "${2:--}"
}

# _ns_rules_ingest <mode> [file|-] — load rows or set NS_RULES_ERR.
_ns_rules_ingest() {
  local out rc
  out="$(_ns_rules_scan "$1" "${2:--}")"
  rc=$?
  case "$out" in
    ERR"$_NS_RULES_TAB"*)
      NS_RULES_ERR="${out#ERR"$_NS_RULES_TAB"}"
      NS_RULES_ERR="${NS_RULES_ERR%%"$_NS_RULES_NL"*}"
      return 1
      ;;
  esac
  [ "$rc" -eq 0 ] || {
    NS_RULES_ERR="rules.json cannot be read"
    return 1
  }
  NS_RULES_ROWS="$out"
  return 0
}

# _ns_rules_run_file <file> — the run's own rules file to lay over <file>: when <file> is the
# shared rules file of a workspace that keeps runs, and the run this caller works on has one.
# Empty otherwise.
_ns_rules_run_file() {
  local ns="${1%/*}" run f
  [ "$ns" != "$1" ] || return 0
  case "$ns" in */.nightshift) ;; *) return 0 ;; esac
  ns_layout_per_run "$ns" punch-list 2>/dev/null || return 0
  ns_layout_run_set run "$ns" || return 0
  ns_layout_rel_at f "$NS_LAYOUT_VERSION" rules || return 0
  [ "$1" = "$ns/$f" ] || return 0
  f="$ns/runs/$run/$f"
  if [ -f "$f" ] && [ ! -L "$f" ]; then printf '%s' "$f"; fi
}

# _ns_rules_member_file <var> <file> — sets <var> to the member settings file the run this caller
# works on selected, to lay over <file> beneath the run's own: settings/<name>.json, named in the
# run's member-settings record. Empty when the run selected none. Status 1, with NS_RULES_ERR set,
# when the selection names a file that is not there.
_ns_rules_member_file() {
  local ns="${2%/*}" run rec name dir
  printf -v "$1" '%s' ""
  [ "$ns" != "$2" ] || return 0
  case "$ns" in */.nightshift) ;; *) return 0 ;; esac
  ns_layout_per_run "$ns" punch-list 2>/dev/null || return 0
  ns_layout_run_set run "$ns" || return 0
  ns_layout_set rec "$ns" member-settings || return 0
  [ -f "$rec" ] && [ ! -L "$rec" ] || return 0
  IFS= read -r name <"$rec" || name=""
  name="${name%$'\r'}"
  [ -n "$name" ] || return 0
  ns_layout_set dir "$ns" settings || return 0
  if [ ! -f "$dir/$name.json" ] || [ -L "$dir/$name.json" ]; then
    NS_RULES_ERR="settings/$name.json is selected for run $run but is not there"
    return 1
  fi
  printf -v "$1" '%s' "$dir/$name.json"
}

# ns_member_settings_problems <workspace> <name> — why settings/<name>.json cannot be selected for a
# run, one line each: a name that is not one, or a missing or malformed file. Nothing when it can be.
ns_member_settings_problems() (
  local ws="$1" name="$2" ns dir="" file
  case "$name" in
    '' | -* | *[!a-z0-9-]*)
      printf 'the name %s is not a settings name: lowercase letters, digits and hyphens\n' "$name"
      exit 0
      ;;
  esac
  ns="$ws/.nightshift"
  ns_layout_set dir "$ns" settings || { printf 'this layout keeps no member settings\n'; exit 0; }
  file="$dir/$name.json"
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    printf 'settings/%s.json is not there\n' "$name"
    exit 0
  fi
  _ns_rules_ingest rules "$file" || printf 'settings/%s.json: %s\n' "$name" "$NS_RULES_ERR"
)

# _ns_rules_overlay <run-rows> <shared-rows> — one set of rows where the run's settings replace the
# shared ones key by key: a value at the same path, or a whole array at the same name. The run's
# rows come first, so a lookup finds them.
_ns_rules_overlay() {
  NS_OVERLAY_RUN="$1" NS_OVERLAY_SHARED="$2" awk '
    BEGIN {
      FS = "\t"
      nr = split(ENVIRON["NS_OVERLAY_RUN"], run, "\n")
      for (i = 1; i <= nr; i++) {
        if (run[i] == "") continue
        print run[i]
        split(run[i], f, "\t")
        if (f[4] == "a") arr[f[1] SUBSEP f[2]] = 1
        else have[f[1] SUBSEP f[2] SUBSEP f[3]] = 1
      }
      ns = split(ENVIRON["NS_OVERLAY_SHARED"], shared, "\n")
      for (i = 1; i <= ns; i++) {
        if (shared[i] == "") continue
        split(shared[i], f, "\t")
        if ((f[1] SUBSEP f[2]) in arr) continue
        if ((f[1] SUBSEP f[2] SUBSEP f[3]) in have) continue
        print shared[i]
      }
    }'
}

# _ns_rules_stamp <file> — size and checksum, or empty without wc and cksum.
_ns_rules_stamp() {
  if command -v wc >/dev/null 2>&1 && command -v cksum >/dev/null 2>&1; then
    printf '%s:%s' "$(wc -c <"$1" | tr -d ' ')" "$(cksum <"$1")"
  fi
}

# ns_rules_load <file> — parse rules.json into NS_RULES_ROWS. In a workspace that keeps runs, the
# shared file is read with the run's own rules file laid over it (see _ns_rules_overlay). Status 1
# names the reason in NS_RULES_ERR.
ns_rules_load() {
  local f="$1" stamp runf="" memf="" shared
  NS_RULES_ERR=""
  if [ ! -f "$f" ]; then
    NS_RULES_ERR="missing"
    NS_RULES_FILE=""
    NS_RULES_STAMP=""
    NS_RULES_ROWS=""
    return 1
  fi
  if [ "${NS_RULES_HELD-}" = "$f|${NIGHTSHIFT_RUN-}" ] && [ "$NS_RULES_FILE" = "$f" ] && [ -n "$NS_RULES_ROWS" ]; then
    return 0
  fi
  runf="$(_ns_rules_run_file "$f")"
  if ! _ns_rules_member_file memf "$f"; then
    NS_RULES_FILE=""
    NS_RULES_STAMP=""
    NS_RULES_ROWS=""
    return 1
  fi
  stamp="$(_ns_rules_stamp "$f")"
  if [ -n "$stamp" ] && [ -n "$memf" ]; then
    stamp="$stamp|$memf:$(_ns_rules_stamp "$memf")"
  fi
  if [ -n "$stamp" ] && [ -n "$runf" ]; then
    stamp="$stamp|$runf:$(_ns_rules_stamp "$runf")"
  fi
  if [ -n "$stamp" ] && [ "$NS_RULES_FILE" = "$f" ] && [ "$NS_RULES_STAMP" = "$stamp" ] && [ -n "$NS_RULES_ROWS" ]; then
    return 0
  fi
  NS_RULES_FILE=""
  NS_RULES_STAMP=""
  NS_RULES_ROWS=""
  _ns_rules_ingest rules "$f" || {
    NS_RULES_FILE=""
    NS_RULES_STAMP=""
    NS_RULES_ROWS=""
    return 1
  }
  # Narrowest first: the run's own file, then the member settings the run selected, then the team's.
  if [ -n "$memf" ]; then
    shared="$NS_RULES_ROWS"
    NS_RULES_ROWS=""
    _ns_rules_ingest rules "$memf" || {
      NS_RULES_ERR="${memf##*/.nightshift/}: $NS_RULES_ERR"
      NS_RULES_FILE=""
      NS_RULES_STAMP=""
      NS_RULES_ROWS=""
      return 1
    }
    NS_RULES_ROWS="$(_ns_rules_overlay "$NS_RULES_ROWS" "$shared")"
  fi
  if [ -n "$runf" ]; then
    shared="$NS_RULES_ROWS"
    NS_RULES_ROWS=""
    _ns_rules_ingest rules "$runf" || {
      NS_RULES_ERR="${runf##*/.nightshift/}: $NS_RULES_ERR"
      NS_RULES_FILE=""
      NS_RULES_STAMP=""
      NS_RULES_ROWS=""
      return 1
    }
    NS_RULES_ROWS="$(_ns_rules_overlay "$NS_RULES_ROWS" "$shared")"
  fi
  NS_RULES_FILE="$f"
  NS_RULES_STAMP="$stamp"
  return 0
}

# ns_rules_hold <nightshift-dir> — load the site's rules for the run in scope and hold them for the
# rest of this process: a later load of the same file for the same run reads the held rows, in every
# subshell too, instead of checking and parsing the files again. For a hook call, which is short and
# never rewrites the rules; a long-running process does not hold them. Nothing is held when the rules
# cannot be read, so each load reports that itself.
ns_rules_hold() {
  local f
  ns_layout_set f "$1" rules 2>/dev/null || return 0
  [ -f "$f" ] || return 0
  ns_rules_load "$f" 2>/dev/null || return 0
  NS_RULES_HELD="$f|${NIGHTSHIFT_RUN-}"
}

# ns_rules_check <workspace> — status 0 the file is the accepted shape.
# Status 1 prints one named reason. Status 3 the file is absent.
ns_rules_check() {
  local f row budget
  ns_layout_set f "$1/.nightshift" rules
  if [ ! -f "$f" ]; then
    printf 'missing\n'
    return 3
  fi
  if ns_rules_load "$f"; then
    row="$(_ns_rules_row shift itemBudget '')"
    budget="$(ns_json_text "${row#*"$_NS_RULES_TAB"}")"
    if [ -n "$budget" ] && ! ns_budget_parse "$budget" >/dev/null; then
      printf 'shift.itemBudget is not a valid budget\n'
      return 1
    fi
    return 0
  fi
  printf '%s\n' "$NS_RULES_ERR"
  return 1
}

# _ns_rules_row <p1> <p2> <p3> — type<TAB>json-value of that path, or status 1.
_ns_rules_row() {
  local rest="$NS_RULES_ROWS" line p1 p2 p3
  while [ -n "$rest" ]; do
    line="${rest%%"$_NS_RULES_NL"*}"
    case "$rest" in *"$_NS_RULES_NL"*) rest="${rest#*"$_NS_RULES_NL"}" ;; *) rest="" ;; esac
    [ -n "$line" ] || continue
    p1="${line%%"$_NS_RULES_TAB"*}"
    line="${line#*"$_NS_RULES_TAB"}"
    p2="${line%%"$_NS_RULES_TAB"*}"
    line="${line#*"$_NS_RULES_TAB"}"
    p3="${line%%"$_NS_RULES_TAB"*}"
    line="${line#*"$_NS_RULES_TAB"}"
    if [ "$p1" != "$1" ] || [ "$p2" != "$2" ] || [ "$p3" != "$3" ]; then
      continue
    fi
    printf '%s' "$line"
    return 0
  done
  return 1
}

# ns_json_text <compact-json> — a JSON string unquoted; any other scalar as-is.
ns_json_text() {
  local s="$1" bin
  case "$s" in
    '"'*)
      case "$s" in
        *\\*)
          bin="$(ns_rules_awk_bin)" || {
            s="${s#\"}"
            printf '%s' "${s%\"}"
            return 0
          }
          printf '%s' "$s" | "$bin" -v mode=unquote -f "$_NS_RULES_AWK_FILE"
          ;;
        *)
          s="${s#\"}"
          printf '%s' "${s%\"}"
          ;;
      esac
      ;;
    *) printf '%s' "$s" ;;
  esac
}

# _ns_rules_array <p1> <p2> — the string array at that path as compact JSON.
_ns_rules_array() {
  local rest="$NS_RULES_ROWS" line p1 p2 p3 typ val out="" first=1
  while [ -n "$rest" ]; do
    line="${rest%%"$_NS_RULES_NL"*}"
    case "$rest" in *"$_NS_RULES_NL"*) rest="${rest#*"$_NS_RULES_NL"}" ;; *) rest="" ;; esac
    [ -n "$line" ] || continue
    p1="${line%%"$_NS_RULES_TAB"*}"
    line="${line#*"$_NS_RULES_TAB"}"
    p2="${line%%"$_NS_RULES_TAB"*}"
    line="${line#*"$_NS_RULES_TAB"}"
    p3="${line%%"$_NS_RULES_TAB"*}"
    line="${line#*"$_NS_RULES_TAB"}"
    typ="${line%%"$_NS_RULES_TAB"*}"
    val="${line#*"$_NS_RULES_TAB"}"
    if ! { [ "$p1" = "$1" ] && [ "$p2" = "$2" ] && [ -n "$p3" ]; }; then continue; fi
    case "$typ" in s | n | b) ;; *) continue ;; esac
    [ "$first" -eq 1 ] || out="$out,"
    first=0
    out="$out$val"
  done
  printf '[%s]' "$out"
}

# ns_json_string_list <json> — each string of a JSON array on its own line, read with awk alone.
# An empty argument or null prints nothing. Status 1 when the value is not a list of strings.
ns_json_string_list() {
  local out
  [ -n "$1" ] || return 0
  out="$(printf '%s' "$1" | _ns_rules_scan stringlist -)" || return 1
  case "$out" in ERR"$_NS_RULES_TAB"*) return 1 ;; esac
  [ -z "$out" ] || printf '%s\n' "$out"
}

# ns_rules_set_block <file> <key> <compact-json> — the same document with one top-level key set
# to that value, sorted and indented, on stdout. Every other key survives byte for byte, including
# one this version does not know: a plugin update fills settings in, it never takes them away.
ns_rules_set_block() {
  local bin
  bin="$(ns_rules_awk_bin)" || return 1
  LC_ALL=C "$bin" -v mode=setblock -v key="$2" -v value="$3" -f "$_NS_RULES_AWK_FILE" <"$1"
}

# ns_rules_merge_block <file> <key> <compact-json-object> — the same document with those
# keys set inside the named object, sorted and indented, on stdout. Every other key of that
# object survives, including one this version does not know. An absent object is created.
ns_rules_merge_block() {
  local bin
  bin="$(ns_rules_awk_bin)" || return 1
  LC_ALL=C "$bin" -v mode=mergeblock -v key="$2" -v value="$3" -f "$_NS_RULES_AWK_FILE" <"$1"
}

# ns_rules_get_in <file> <block> <key> — one field of a settings block, as the
# effective scalar, null, or compact JSON for an array. Empty when absent.
ns_rules_get_in() {
  local row typ val
  ns_rules_load "$1" || return 0
  row="$(_ns_rules_row "$2" "$3" "")" || return 0
  typ="${row%%"$_NS_RULES_TAB"*}"
  val="${row#*"$_NS_RULES_TAB"}"
  case "$typ" in
    s | n | b) ns_json_text "$val" ;;
    z) printf 'null' ;;
    a) _ns_rules_array "$2" "$3" ;;
  esac
}

# ns_rules_get <file> <key> — the effective scalar (or compact JSON for an
# object/array). Empty when the key is absent or the file fails closed.
ns_rules_get() {
  local row typ val p1 p2 p3 parts first=1 rest line child_typ child_val
  ns_rules_load "$1" || return 0
  row="$(_ns_rules_row "$2" "" "")" || return 0
  typ="${row%%"$_NS_RULES_TAB"*}"
  val="${row#*"$_NS_RULES_TAB"}"
  case "$typ" in
    s | n | b) ns_json_text "$val" ;;
    z) printf 'null' ;;
    o | a)
      parts=""
      rest="$NS_RULES_ROWS"
      while [ -n "$rest" ]; do
        line="${rest%%"$_NS_RULES_NL"*}"
        case "$rest" in *"$_NS_RULES_NL"*) rest="${rest#*"$_NS_RULES_NL"}" ;; *) rest="" ;; esac
        [ -n "$line" ] || continue
        p1="${line%%"$_NS_RULES_TAB"*}"
        [ "$p1" = "$2" ] || continue
        line="${line#*"$_NS_RULES_TAB"}"
        p2="${line%%"$_NS_RULES_TAB"*}"
        line="${line#*"$_NS_RULES_TAB"}"
        p3="${line%%"$_NS_RULES_TAB"*}"
        line="${line#*"$_NS_RULES_TAB"}"
        child_typ="${line%%"$_NS_RULES_TAB"*}"
        child_val="${line#*"$_NS_RULES_TAB"}"
        if [ -z "$p2" ] || [ -n "$p3" ]; then
          continue
        fi
        # A field is carried whatever it holds. Skipping a shape here would drop
        # it from the object silently, which reads as a setting the owner never
        # wrote rather than one this reader could not render.
        case "$child_typ" in
          s | n | b) ;;
          z) child_val=null ;;
          a) child_val="$(_ns_rules_array "$2" "$p2")" ;;
          *) continue ;;
        esac
        if [ "$typ" = a ]; then
          [ "$first" -eq 1 ] || parts="$parts,"
          first=0
          parts="$parts$child_val"
        else
          [ "$first" -eq 1 ] || parts="$parts,"
          first=0
          parts="$parts$(ns_rules_json_key "$p2"):$child_val"
        fi
      done
      if [ "$typ" = a ]; then
        printf '[%s]' "$parts"
      else
        printf '{%s}' "$parts"
      fi
      ;;
  esac
}

# ns_rules_json_key <text> — the key as a JSON string. Keys from this reader
# never carry controls.
ns_rules_json_key() {
  local s="$1"
  s="$(printf '%s' "$s" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '"%s"' "$s"
}

# ns_rules_keys <file> — top-level key names, one per line, file order.
ns_rules_keys() {
  local rest line p1 seen
  ns_rules_load "$1" || return 1
  seen="$_NS_RULES_NL"
  rest="$NS_RULES_ROWS"
  while [ -n "$rest" ]; do
    line="${rest%%"$_NS_RULES_NL"*}"
    case "$rest" in *"$_NS_RULES_NL"*) rest="${rest#*"$_NS_RULES_NL"}" ;; *) rest="" ;; esac
    [ -n "$line" ] || continue
    p1="${line%%"$_NS_RULES_TAB"*}"
    [ -n "$p1" ] || continue
    case "$seen" in *"$_NS_RULES_NL$p1$_NS_RULES_NL"*) continue ;; esac
    seen="$seen$p1$_NS_RULES_NL"
    printf '%s\n' "$p1"
  done
}

# ns_rules_tool_state <file> <tool> — deny | allow | missing | invalid
ns_rules_tool_state() {
  local row typ val
  ns_rules_load "$1" || {
    printf 'invalid\n'
    return 0
  }
  row="$(_ns_rules_row toolDeny "" "")" || {
    printf 'missing\n'
    return 0
  }
  typ="${row%%"$_NS_RULES_TAB"*}"
  [ "$typ" = o ] || {
    printf 'invalid\n'
    return 0
  }
  row="$(_ns_rules_row toolDeny "$2" "")" || {
    printf 'missing\n'
    return 0
  }
  typ="${row%%"$_NS_RULES_TAB"*}"
  val="${row#*"$_NS_RULES_TAB"}"
  [ "$typ" = s ] || {
    printf 'invalid\n'
    return 0
  }
  val="$(ns_json_text "$val")"
  if [ -z "$val" ]; then
    printf 'allow\n'
  else
    printf 'deny\n'
  fi
}

# ns_rules_tool_deny_json <file> — compact JSON object of toolDeny, or {}.
ns_rules_tool_deny_json() {
  local rest line p1 p2 p3 typ val first=1
  ns_rules_load "$1" || {
    printf '{}'
    return 1
  }
  printf '{'
  rest="$NS_RULES_ROWS"
  while [ -n "$rest" ]; do
    line="${rest%%"$_NS_RULES_NL"*}"
    case "$rest" in *"$_NS_RULES_NL"*) rest="${rest#*"$_NS_RULES_NL"}" ;; *) rest="" ;; esac
    [ -n "$line" ] || continue
    p1="${line%%"$_NS_RULES_TAB"*}"
    [ "$p1" = toolDeny ] || continue
    line="${line#*"$_NS_RULES_TAB"}"
    p2="${line%%"$_NS_RULES_TAB"*}"
    line="${line#*"$_NS_RULES_TAB"}"
    p3="${line%%"$_NS_RULES_TAB"*}"
    line="${line#*"$_NS_RULES_TAB"}"
    typ="${line%%"$_NS_RULES_TAB"*}"
    val="${line#*"$_NS_RULES_TAB"}"
    if [ -z "$p2" ] || [ -n "$p3" ] || [ "$typ" != s ]; then
      continue
    fi
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '%s:%s' "$(ns_rules_json_key "$p2")" "$val"
  done
  printf '}'
}

# ns_rules_map_parse <json-object> — object-of-strings into NS_RULES_MAP
# (key<TAB>decoded-value lines). Status 1 when the text is not that shape.
ns_rules_map_parse() {
  local src="$1" rows rest line p1 p2 p3 typ val
  if [ "$NS_RULES_MAP_SRC" = "$src" ] && [ -n "$NS_RULES_MAP_SRC" ]; then
    return 0
  fi
  NS_RULES_MAP=""
  NS_RULES_MAP_SRC=""
  rows="$(printf '%s' "$src" | _ns_rules_scan strings -)" || {
    NS_RULES_ERR="invalid tool map"
    return 1
  }
  case "$rows" in
    ERR"$_NS_RULES_TAB"*)
      NS_RULES_ERR="${rows#ERR"$_NS_RULES_TAB"}"
      NS_RULES_ERR="${NS_RULES_ERR%%"$_NS_RULES_NL"*}"
      return 1
      ;;
  esac
  rest="$rows"
  while [ -n "$rest" ]; do
    line="${rest%%"$_NS_RULES_NL"*}"
    case "$rest" in *"$_NS_RULES_NL"*) rest="${rest#*"$_NS_RULES_NL"}" ;; *) rest="" ;; esac
    [ -n "$line" ] || continue
    p1="${line%%"$_NS_RULES_TAB"*}"
    line="${line#*"$_NS_RULES_TAB"}"
    p2="${line%%"$_NS_RULES_TAB"*}"
    line="${line#*"$_NS_RULES_TAB"}"
    p3="${line%%"$_NS_RULES_TAB"*}"
    line="${line#*"$_NS_RULES_TAB"}"
    typ="${line%%"$_NS_RULES_TAB"*}"
    val="${line#*"$_NS_RULES_TAB"}"
    if [ -z "$p1" ] || [ -n "$p2" ] || [ -n "$p3" ] || [ "$typ" != s ]; then
      continue
    fi
    NS_RULES_MAP="$NS_RULES_MAP$p1$_NS_RULES_TAB$(ns_json_text "$val")$_NS_RULES_NL"
  done
  NS_RULES_MAP_SRC="$src"
  return 0
}

# ns_rules_map_has <json-object> <key>
ns_rules_map_has() {
  ns_rules_map_parse "$1" || return 1
  case "$_NS_RULES_NL$NS_RULES_MAP" in
    *"$_NS_RULES_NL$2$_NS_RULES_TAB"*) return 0 ;;
  esac
  return 1
}

# ns_rules_map_msg <json-object> <key> — decoded value, or status 1.
ns_rules_map_msg() {
  local rest line
  ns_rules_map_parse "$1" || return 1
  rest="$NS_RULES_MAP"
  while [ -n "$rest" ]; do
    line="${rest%%"$_NS_RULES_NL"*}"
    case "$rest" in *"$_NS_RULES_NL"*) rest="${rest#*"$_NS_RULES_NL"}" ;; *) rest="" ;; esac
    case "$line" in
      "$2$_NS_RULES_TAB"*)
        printf '%s' "${line#*"$_NS_RULES_TAB"}"
        return 0
        ;;
    esac
  done
  return 1
}

# The owner preference blocks the resolved view carries, in the byte order it prints them.
# One list, so the fact stream and the setting names cannot drift apart.
NS_RULES_GROUP_KEYS='archive.automatic
archive.layout
archive.root
archive.templatePath
catalogs.edge-cases.paths
catalogs.edge-cases.template
catalogs.evidence.paths
catalogs.evidence.template
catalogs.gates.paths
catalogs.gates.template
catalogs.shifts.paths
catalogs.shifts.template
handoff.detail
handoff.enabled
handoff.language
handoff.sections
handoff.templatePath
handoff.view
recovery.launchScope
receipts.duration
receipts.enabled
receipts.evidence.architecture
receipts.evidence.check
receipts.evidence.default
receipts.evidence.fileMap
receipts.evidence.review
receipts.evidence.unavailable
receipts.progressMinutes
receipts.progressMode
receipts.progressTokens
receipts.templatePath
receipts.usage
shift.copyIn
shift.execution
shift.hours
shift.isolation
shift.itemBudget
shift.prepare
shift.toolingPolicy
shift.verificationProfile
shift.worktreeRoot'

# The top-level settings the fact stream carries as `r` rows.
NS_RULES_TOP_FACT_KEYS='forbiddenCommands
neverCommitPatterns
expectedEmail
protectedDirs
stallMax
watchMinutes'

# ns_rules_facts <file> — the policy fact stream _ns_policy_load_rules consumes, read from the loaded
# rows in one awk pass. Status 1 when the file is not the accepted shape.
ns_rules_facts() {
  local bin
  ns_rules_load "$1" || return 1
  bin="$(ns_rules_awk_bin)" || return 1
  # One awk pass over the loaded rows prints every fact.
  printf '%s\n' "$NS_RULES_ROWS" |
    NS_FACTS_TOP="$NS_RULES_TOP_FACT_KEYS" NS_FACTS_ELEVATION="$NS_POLICY_CATEGORIES" \
      NS_FACTS_GROUPS="$NS_RULES_GROUP_KEYS" "$bin" -v mode=facts -f "$_NS_RULES_AWK_FILE"
}
