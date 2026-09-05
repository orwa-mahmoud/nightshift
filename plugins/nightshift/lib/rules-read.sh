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
    NS_RULES_ERR="rules.json cannot be read"
    return 1
  }
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

# ns_rules_load <file> — parse rules.json into NS_RULES_ROWS. Status 1 names
# the reason in NS_RULES_ERR.
ns_rules_load() {
  local f="$1" stamp
  NS_RULES_ERR=""
  if [ ! -f "$f" ]; then
    NS_RULES_ERR="missing"
    NS_RULES_FILE=""
    NS_RULES_STAMP=""
    NS_RULES_ROWS=""
    return 1
  fi
  stamp=""
  if command -v wc >/dev/null 2>&1 && command -v cksum >/dev/null 2>&1; then
    stamp="$(wc -c <"$f" | tr -d ' '):$(cksum <"$f")"
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
  NS_RULES_FILE="$f"
  NS_RULES_STAMP="$stamp"
  return 0
}

# ns_rules_check <workspace> — status 0 the file is the accepted shape.
# Status 1 prints one named reason. Status 3 the file is absent.
ns_rules_check() {
  local f="$1/.nightshift/rules.json"
  if [ ! -f "$f" ]; then
    printf 'missing\n'
    return 3
  fi
  ns_rules_load "$f" && return 0
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
    [ "$p1" = "$1" ] && [ "$p2" = "$2" ] && [ -n "$p3" ] || continue
    case "$typ" in s | n | b) ;; *) continue ;; esac
    [ "$first" -eq 1 ] || out="$out,"
    first=0
    out="$out$val"
  done
  printf '[%s]' "$out"
}

# ns_rules_set_block <file> <key> <compact-json> — the same document with one top-level key set
# to that value, sorted and indented, on stdout. Every other key survives byte for byte, including
# one this version does not know: a plugin update fills settings in, it never takes them away.
ns_rules_set_block() {
  local bin
  bin="$(ns_rules_awk_bin)" || return 1
  LC_ALL=C "$bin" -v mode=setblock -v key="$2" -v value="$3" -f "$_NS_RULES_AWK_FILE" <"$1"
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

# ns_rules_facts <file> — the policy fact stream _ns_policy_load_rules consumes.
# Status 1 when the file is not the accepted shape.
ns_rules_facts() {
  local k c row typ val present pol pat
  ns_rules_load "$1" || return 1
  for k in forbiddenCommands neverCommitPatterns expectedEmail protectedDirs stallMax watchMinutes; do
    row="$(_ns_rules_row "$k" "" "")" && present=1 || present=0
    if [ "$present" -eq 1 ]; then
      typ="${row%%"$_NS_RULES_TAB"*}"
      val="${row#*"$_NS_RULES_TAB"}"
      case "$typ" in
        s | n | b) ;;
        *) val=null ;;
      esac
    else
      val=null
    fi
    printf 'r\t%s\t%s\t%s\n' "$k" "$present" "$val"
  done
  for c in sudo containers global-packages daemons external-services; do
    if _ns_rules_row elevation "$c" "" >/dev/null; then
      present=1
    else
      present=0
    fi
    pol=""
    row="$(_ns_rules_row elevation "$c" policy)" && {
      typ="${row%%"$_NS_RULES_TAB"*}"
      val="${row#*"$_NS_RULES_TAB"}"
      [ "$typ" = s ] && pol="$(ns_json_text "$val")"
    }
    pol="$(printf '%s' "$pol" | tr '\000-\037\177' ' ')"
    printf 'e\t%s\t%s\t%s\n' "$c" "$present" "$pol"
    row="$(_ns_rules_row elevation "$c" pattern)" || continue
    typ="${row%%"$_NS_RULES_TAB"*}"
    val="${row#*"$_NS_RULES_TAB"}"
    [ "$typ" = s ] || continue
    pat="$(ns_json_text "$val")"
    [ -n "$pat" ] || continue
    pat="$(printf '%s' "$pat" | tr '\000-\037\177' ' ')"
    printf 'p\t%s\t%s\n' "$c" "$pat"
  done
}
