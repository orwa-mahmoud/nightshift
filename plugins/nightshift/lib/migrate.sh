#!/usr/bin/env bash
# Moving a workspace's state into the current layout.
#
# The layout table is the whole plan. Every file found at an earlier path of a key moves to that
# key's current path, whichever layout the workspace started in, so one routine serves a legacy
# workspace, a version-1 one, a move that was cut short and a folder somebody tidied by hand; a
# second run finds nothing to do. A later layout change adds rows to the table, never a step here.
#
# ns_migrate_plan prints the plan as records and changes nothing; ns_migrate_apply computes the
# same plan and performs it. Nothing is deleted or overwritten: a file moves only onto a path that
# is empty, a copy already there with the same bytes is left where it is, and a destination that
# holds anything else refuses the whole run by name. The state-version marker is written last, so
# a run that stops part way is finished by running it again.
#
# Callers: migrate-state, and Doctor and Setup to describe the move. Never a hook, Start, Status,
# Archive or recovery.

_ns_migrate_dir="${BASH_SOURCE[0]%/*}"
[ "$_ns_migrate_dir" != "${BASH_SOURCE[0]}" ] || _ns_migrate_dir=.
NS_MIGRATE_LINKS_AWK="$_ns_migrate_dir/migrate-links.awk"
NS_MIGRATE_JSON_AWK="$_ns_migrate_dir/rules-read.awk"
unset _ns_migrate_dir

_NS_MIG_TAB="$(printf '\t')"

# Every key that names a file or directory, table order.
_ns_migrate_keys() {
  printf '%s' "$NS_LAYOUT_ROWS" | awk -F '\t' '$4 != "field" && $4 != "retired" && $4 != "stray" && !seen[$1]++ { print $1 }'
}

# _ns_migrate_rows <key> — every path <key> has had, oldest first.
_ns_migrate_rows() {
  printf '%s' "$NS_LAYOUT_ROWS" | awk -F '\t' -v k="$1" '$1 == k { print $3 }'
}

# _ns_migrate_field_keys <kind> — the field or retired keys, table order.
_ns_migrate_field_keys() {
  printf '%s' "$NS_LAYOUT_ROWS" | awk -F '\t' -v kind="$1" '$4 == kind && !seen[$1]++ { print $1 }'
}

# _ns_migrate_entry <ns> <rel> — status 0 when something, even a dangling link, is at <rel>.
_ns_migrate_entry() {
  [ -e "$1/$2" ] || [ -L "$1/$2" ]
}

# _ns_migrate_carry — `old<TAB>new` for every earlier path of every key, from the table: where a
# link written against any layout lands once each file is in its current place.
_ns_migrate_carry() {
  local key cur p
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    ns_layout_rel_at cur "$NS_LAYOUT_VERSION" "$key" || continue
    case "$cur" in *'*'*) continue ;; esac
    while IFS= read -r p; do
      [ -n "$p" ] && [ "$p" != "$cur" ] || continue
      printf '%s\t%s\n' "$p" "$cur"
    done <<ROWS
$(_ns_migrate_rows "$key")
ROWS
  done <<KEYS
$(_ns_migrate_keys)
KEYS
}

# _ns_migrate_canon <ns> <rel> <carry> — a Markdown file with every relative link written as the
# state path it names, so a copy written from another directory reads the same.
_ns_migrate_canon() {
  local dir=""
  case "$2" in */*) dir="${2%/*}" ;; esac
  NS_MIG_EXISTS="" NS_MIG_MOVES="$3" NS_MIG_ROOT="$1" \
    awk -v dir="$dir" -v olddirs="" -v mode=canon -f "$NS_MIGRATE_LINKS_AWK" <"$1/$2"
}

# _ns_migrate_judge <ns> <from> <to> <carry> — how one earlier path meets its current path: move,
# same (its content is already there, a Markdown file's links read from where each copy sits),
# empty (an empty directory is left behind), or conflict.
_ns_migrate_judge() {
  local ns="$1" src="$1/$2" dst="$1/$3" parent
  parent="${dst%/*}"
  while [ "$parent" != "$ns" ] && [ -n "$parent" ]; do
    if { [ -e "$parent" ] || [ -L "$parent" ]; } && { [ ! -d "$parent" ] || [ -L "$parent" ]; }; then
      printf 'conflict'
      return 0
    fi
    parent="${parent%/*}"
  done
  if ! _ns_migrate_entry "$ns" "$3"; then
    printf 'move'
  elif [ -f "$src" ] && [ ! -L "$src" ] && [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$src" "$dst"; then
    printf 'same'
  elif [ -f "$src" ] && [ ! -L "$src" ] && [ -f "$dst" ] && [ ! -L "$dst" ] \
    && case "$2$3" in *.md*.md) true ;; *) false ;; esac \
    && [ "$(_ns_migrate_canon "$ns" "$2" "$4")" = "$(_ns_migrate_canon "$ns" "$3" "$4")" ]; then
    printf 'same'
  elif [ -d "$src" ] && [ ! -L "$src" ] && [ -d "$dst" ] && [ -z "$(ls -A "$src" 2>/dev/null)" ]; then
    printf 'empty'
  else
    printf 'conflict'
  fi
}

# _ns_migrate_json <mode> <file> [key] [value] — the bundled JSON reader in one of its modes.
_ns_migrate_json() {
  LC_ALL=C awk -v mode="$1" -v key="${3-}" -v value="${4-}" -f "$NS_MIGRATE_JSON_AWK" <"$2" 2>/dev/null
}

# _ns_migrate_live_file <ns> <key> — where a file key sits right now, relative: its current path
# when that exists, else the first earlier one that does. Empty when neither does.
_ns_migrate_live_file() {
  local cur p
  ns_layout_rel_at cur "$NS_LAYOUT_VERSION" "$2"
  if _ns_migrate_entry "$1" "$cur"; then
    printf '%s' "$cur"
    return 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] && [ "$p" != "$cur" ] || continue
    if _ns_migrate_entry "$1" "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done <<EOF
$(_ns_migrate_rows "$2")
EOF
}

# ns_migrate_plan <workspace> — the plan as records, one per line, tab separated:
#   state <version>                  where the workspace starts
#   refuse <reason>                  the run cannot apply until this is resolved
#   move <from> <to>                 a rename onto an empty path
#   leave <from> <to> same|empty     already done: the same content, or an empty directory, stay put
#   conflict <from> <to> [why]       a destination that holds something else
#   rename <file> <from> <to>        a settings block that moves to its current name
#   drop <file> <from> <to>          an earlier block whose value is already under its current name
#   retire <file> <path>             a setting no version reads any more
#   link <file> <old> <new>          a relative link written again so it resolves
#   original <file>                  the archived file, kept as it was beside the rewritten one
#   ignore <file> <line>             a line the receipts repository needs to leave run/ out
#   unknown <path>                   something that is not a Nightshift file, left in place
#   stray <path>                     a file an earlier plugin wrote by mistake, left in place
#   note <text>                      what the owner should know about a move
#   marker <from> <to>               the state-version written last
# Status 0 printed · 2 no usable state directory.
ns_migrate_plan() {
  local ws="$1" ns kind ver key cur p prefix suffix parent lead name inst to verdict groups
  local moves="" work armed pid start file fkey fcur fold oldv newv doc line key2
  local archive_root f rel d known strays carry
  ns="$ws/.nightshift"
  kind="$(ns_state_kind "$ws")"
  case "$kind" in
    absent)
      printf 'refuse\tno .nightshift/ at %s - run Setup first\n' "$ws"
      return 2
      ;;
    future | malformed)
      printf 'refuse\t%s\n' "$(ns_state_refuse_message "$kind")"
      return 2
      ;;
  esac
  ver="$(ns_state_version "$ws")"
  printf 'state\t%s\n' "$ver"

  # Nothing moves under a running shift, a live watchman or a held lock: each of them may be
  # writing to a path this is about to take away.
  armed=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -f "$ns/$p" ] && [ "$armed" -eq 0 ]; then
      printf 'refuse\tthe shift is armed (%s) - clock out, or run Reset, first\n' "$p"
      armed=1
    fi
  done <<EOF
$(_ns_migrate_rows armed)
EOF
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$ns/$p" ] && [ ! -L "$ns/$p" ] || continue
    pid="$(sed -n 1p "$ns/$p" 2>/dev/null | tr -d '[:space:]')"
    start="$(sed -n 2p "$ns/$p" 2>/dev/null)"
    case "$pid" in '' | *[!0-9]*) continue ;; esac
    if ns_recorded_process "$pid" "$start"; then
      printf 'refuse\ta watchman is running (pid %s, %s) - stop it with Stop or Reset first\n' "$pid" "$p"
    fi
  done <<EOF
$(_ns_migrate_rows watchman)
EOF
  for key in lock lease-lock; do
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if _ns_migrate_entry "$ns" "$p"; then
        printf 'refuse\ta lock is held (%s) - let the operation finish, or run Reset if nothing is running\n' "$p"
      fi
    done <<EOF
$(_ns_migrate_rows "$key")
EOF
  done

  # Every file found at an earlier path of its key, bound for its current one.
  carry="$(_ns_migrate_carry)"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    ns_layout_rel_at cur "$NS_LAYOUT_VERSION" "$key" || continue
    while IFS= read -r p; do
      [ -n "$p" ] && [ "$p" != "$cur" ] || continue
      case "$p" in
        *'*'*)
          prefix="${p%%\**}"
          suffix="${p#*\*}"
          parent=""
          lead="$prefix"
          case "$prefix" in */*) parent="${prefix%/*}" lead="${prefix##*/}" ;; esac
          while IFS= read -r name; do
            [ -n "$name" ] || continue
            case "$name" in "$lead"*"$suffix") ;; *) continue ;; esac
            # A family's * never matches a leading dot, as a shell pattern would not.
            if [ -z "$lead" ]; then case "$name" in .*) continue ;; esac; fi
            inst="${name#"$lead"}"
            inst="${inst%"$suffix"}"
            [ -n "$inst" ] || continue
            rel="${parent:+$parent/}$name"
            to="${cur%%\**}$inst${cur#*\*}"
            verdict="$(_ns_migrate_judge "$ns" "$rel" "$to" "$carry")"
            case "$verdict" in
              move) printf 'move\t%s\t%s\n' "$rel" "$to"; moves="$moves$rel$_NS_MIG_TAB$to
" ;;
              same | empty) printf 'leave\t%s\t%s\t%s\n' "$rel" "$to" "$verdict" ;;
              *) printf 'conflict\t%s\t%s\n' "$rel" "$to" ;;
            esac
          done <<NAMES
$(_ns_migrate_ls "$ns${parent:+/$parent}")
NAMES
          ;;
        *)
          _ns_migrate_entry "$ns" "$p" || continue
          verdict="$(_ns_migrate_judge "$ns" "$p" "$cur" "$carry")"
          case "$verdict" in
            move) printf 'move\t%s\t%s\n' "$p" "$cur"; moves="$moves$p$_NS_MIG_TAB$cur
" ;;
            same | empty) printf 'leave\t%s\t%s\t%s\n' "$p" "$cur" "$verdict" ;;
            *) printf 'conflict\t%s\t%s\n' "$p" "$cur" ;;
          esac
          ;;
      esac
    done <<EOF
$(_ns_migrate_rows "$key")
EOF
  done <<EOF
$(_ns_migrate_keys)
EOF

  # Settings blocks under their current names, then settings no version reads. The document is
  # read wherever it sits now and judged as it will be once the renames are made.
  work="$(mktemp -d "${TMPDIR:-/tmp}/ns-migrate.XXXXXX")" || return 2
  while IFS= read -r fkey; do
    [ -n "$fkey" ] || continue
    fold=""
    fcur=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      fold="${fold:+$fold }$fcur"
      fcur="$line"
    done <<EOF
$(_ns_migrate_rows "$fkey")
EOF
    file="${fcur%%#*}"
    newv="${fcur#*#}"
    rel="$(_ns_migrate_live_file "$ns" "$file")"
    [ -n "$rel" ] && [ -f "$ns/$rel" ] && [ ! -L "$ns/$rel" ] || continue
    ns_layout_rel_at to "$NS_LAYOUT_VERSION" "$file"
    doc="$work/$file.json"
    [ -f "$doc" ] || cp "$ns/$rel" "$doc" 2>/dev/null || continue
    if ! _ns_migrate_json canon "$doc" >/dev/null; then
      printf 'conflict\t%s\t%s\tis not readable JSON, so its settings cannot be checked\n' "$rel" "$to"
      continue
    fi
    for oldv in $fold; do
      oldv="${oldv#*#}"
      [ -n "$(_ns_migrate_json canonat "$doc" "$oldv")" ] || continue
      if [ -z "$(_ns_migrate_json canonat "$doc" "$newv")" ]; then
        printf 'rename\t%s\t%s\t%s\n' "$to" "$oldv" "$newv"
        _ns_migrate_json renamekey "$doc" "$oldv" "$newv" >"$doc.next" && mv "$doc.next" "$doc"
      elif [ "$(_ns_migrate_json canonat "$doc" "$oldv")" = "$(_ns_migrate_json canonat "$doc" "$newv")" ]; then
        printf 'drop\t%s\t%s\t%s\n' "$to" "$oldv" "$newv"
        _ns_migrate_json dropkey "$doc" "$oldv" >"$doc.next" && mv "$doc.next" "$doc"
      else
        printf 'conflict\t%s\t%s\tholds both %s and %s with different values\n' "$rel" "$to" "$oldv" "$newv"
      fi
    done
  done <<EOF
$(_ns_migrate_field_keys field)
EOF
  while IFS= read -r key2; do
    [ -n "$key2" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      file="${line%%#*}"
      p="${line#*#}"
      doc="$work/$file.json"
      if [ ! -f "$doc" ]; then
        rel="$(_ns_migrate_live_file "$ns" "$file")"
        [ -n "$rel" ] && [ -f "$ns/$rel" ] && [ ! -L "$ns/$rel" ] || continue
        cp "$ns/$rel" "$doc" 2>/dev/null || continue
      fi
      [ -n "$(_ns_migrate_json canonat "$doc" "$p")" ] || continue
      ns_layout_rel_at to "$NS_LAYOUT_VERSION" "$file"
      printf 'retire\t%s\t%s\n' "$to" "$p"
    done <<EOF
$(_ns_migrate_rows "$key2")
EOF
  done <<EOF
$(_ns_migrate_field_keys retired)
EOF
  rm -rf "$work"

  # Links that would stop resolving once the moves are made, written again so they do.
  _ns_migrate_links "$ws" "$moves" plan

  # The receipts repository leaves the runtime's directory out, as Setup writes it.
  ns_layout_rel_at f "$NS_LAYOUT_VERSION" gitignore
  if ns_layout_rel_at d "$NS_LAYOUT_VERSION" run && [ -f "$ns/$f" ] && [ ! -L "$ns/$f" ] \
    && ! grep -qxF "$d/" "$ns/$f" 2>/dev/null; then
    printf 'ignore\t%s\t%s/\n' "$f" "$d"
  fi

  # Anything this layout has no name for stays where it is, and is named so nothing is a surprise.
  archive_root="$(ns_archive "$ws" root)"
  [ -n "$archive_root" ] || ns_layout_rel_at archive_root "$NS_LAYOUT_VERSION" archive
  known="$(printf '%s' "$NS_LAYOUT_ROWS" | awk -F '\t' '$4 != "field" && $4 != "retired" && $4 != "stray" { print $3 }')"
  strays="$(printf '%s' "$NS_LAYOUT_ROWS" | awk -F '\t' '$4 == "stray" { print $3 }')"
  groups="$(printf '%s' "$NS_LAYOUT_ROWS" | awk -F '\t' '$4 == "group" { print $3 }')"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ "$rel" != "$archive_root" ] || continue
    if _ns_migrate_known "$rel" "$strays"; then
      printf 'stray\t%s\n' "$rel"
      continue
    fi
    _ns_migrate_known "$rel" "$known" || { printf 'unknown\t%s\n' "$rel"; continue; }
    # A folder that holds only other keys: anything else inside it is named too.
    if [ -d "$ns/$rel" ] && [ ! -L "$ns/$rel" ] && _ns_migrate_known "$rel" "$groups"; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        _ns_migrate_known "$rel/$f" "$known" || printf 'unknown\t%s\n' "$rel/$f"
      done <<NAMES
$(_ns_migrate_ls "$ns/$rel")
NAMES
    fi
  done <<NAMES
$(_ns_migrate_ls "$ns")
NAMES

  ns_layout_rel_at d "$NS_LAYOUT_VERSION" scheduled-log
  case "$moves" in
    *"$_NS_MIG_TAB$d
"*)
      printf 'note\ta schedule registered before this move still appends to scheduled.log; print it again with Schedule\n' ;;
  esac
  ns_layout_rel_at f "$NS_LAYOUT_VERSION" receipts-repo
  if [ -d "$ns/$f" ] && [ -n "$moves" ]; then
    printf 'note\tthe receipts repository shows each move once you commit; run/ is left out of it from now on\n'
  fi
  if [ "$kind" = legacy ]; then
    printf 'marker\t%s\t%s\n' "$ver" "$NS_STATE_VERSION"
  fi
  return 0
}

# _ns_migrate_ls <dir> — the names in a directory, dot names included, one per line in byte order,
# so both runtimes list a directory the same way whatever the locale.
_ns_migrate_ls() {
  local e
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    printf '%s\n' "${e##*/}"
  done | LC_ALL=C sort
}

# _ns_migrate_known <rel> <known-paths> — status 0 when <rel> is a path some layout gives a key,
# or an instance of a family such as usage-*.
_ns_migrate_known() {
  local rel="$1" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      *'*'*)
        # shellcheck disable=SC2254 # the family is a pattern on purpose
        case "$rel" in $p) return 0 ;; esac
        ;;
      *) [ "$rel" = "$p" ] && return 0 ;;
    esac
  done <<EOF
$2
EOF
  return 1
}

# _ns_migrate_links <workspace> <moves> <plan|apply> — the Markdown files under the state directory
# with a link that would not resolve once the moves are made. `plan` prints link and original
# records; `apply` rewrites each file in place, keeping an archived file's original beside it.
_ns_migrate_links() {
  local ws="$1" moves="$2" mode="$3" ns exists f rel now dir olddirs key cur p out base orig
  local archive_root tmp carry
  ns="$ws/.nightshift"
  archive_root="$(ns_archive "$ws" root)"
  [ -n "$archive_root" ] || ns_layout_rel_at archive_root "$NS_LAYOUT_VERSION" archive
  # A link is carried by the table, not by this run's moves: every earlier path of a key reaches
  # its current one, so a run that finishes an interrupted one repoints what the first one moved.
  carry="$(_ns_migrate_carry)"
  # What exists once the moves are made: every path now, carried through the moves.
  exists="$(find "$ns" -mindepth 1 -name .git -prune -o -print 2>/dev/null | while IFS= read -r p; do
    printf '%s\n' "${p#"$ns"/}"
  done | NS_MIG_MOVES="$moves" awk '
    BEGIN {
      n = split(ENVIRON["NS_MIG_MOVES"], pairs, "\n")
      for (k = 1; k <= n; k++) {
        if (pairs[k] == "") continue
        split(pairs[k], pr, "\t")
        moves[pr[1]] = pr[2]
      }
    }
    {
      p = $0
      out = p
      for (src in moves) {
        if (p == src) { out = moves[src]; break }
        if (index(p, src "/") == 1) { out = moves[src] substr(p, length(src) + 1); break }
      }
      print out
      while (index(out, "/") > 0) { sub(/\/[^\/]*$/, "", out); print out }
    }' | sort -u)"
  find "$ns" -name .git -prune -o -type f -name '*.md' -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    [ -L "$f" ] && continue
    rel="${f#"$ns"/}"
    case "$rel" in *.original.md) continue ;; esac
    now="$(printf '%s\n' "$rel" | NS_MIG_MOVES="$moves" awk '
      BEGIN {
        n = split(ENVIRON["NS_MIG_MOVES"], pairs, "\n")
        for (k = 1; k <= n; k++) { if (pairs[k] == "") continue; split(pairs[k], pr, "\t"); moves[pr[1]] = pr[2] }
      }
      { p = $0; out = p; for (src in moves) { if (p == src) { out = moves[src]; break } if (index(p, src "/") == 1) { out = moves[src] substr(p, length(src) + 1); break } } print out }')"
    [ "$mode" = plan ] || now="$rel"
    dir=""
    case "$now" in */*) dir="${now%/*}" ;; esac
    olddirs="$dir"
    case "$rel" in */*) p="${rel%/*}" ;; *) p="" ;; esac
    [ "$p" = "$dir" ] || olddirs="$olddirs$_NS_MIG_TAB$p"
    # A file with a key may have been written in any directory an earlier layout gave it.
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      ns_layout_rel_at cur "$NS_LAYOUT_VERSION" "$key" || continue
      [ "$cur" = "$now" ] || continue
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in */*) p="${p%/*}" ;; *) p="" ;; esac
        case "$_NS_MIG_TAB$olddirs$_NS_MIG_TAB" in *"$_NS_MIG_TAB$p$_NS_MIG_TAB"*) ;; *) olddirs="$olddirs$_NS_MIG_TAB$p" ;; esac
      done <<ROWS
$(_ns_migrate_rows "$key")
ROWS
    done <<KEYS
$(_ns_migrate_keys)
KEYS
    out="$(NS_MIG_EXISTS="$exists" NS_MIG_MOVES="$carry" NS_MIG_ROOT="$ns" \
      awk -v dir="$dir" -v olddirs="$olddirs" -v mode=plan -f "$NS_MIGRATE_LINKS_AWK" <"$f")"
    [ -n "$out" ] || continue
    base="${now##*/}"
    orig=""
    case "$now" in "$archive_root"/*) orig="${now%.md}.original.md" ;; esac
    if [ "$mode" = plan ]; then
      printf '%s\n' "$out" | while IFS="$_NS_MIG_TAB" read -r p cur; do
        printf 'link\t%s\t%s\t%s\n' "$now" "$p" "$cur"
      done
      if [ -n "$orig" ] && ! _ns_migrate_entry "$ns" "$orig"; then
        printf 'original\t%s\n' "$orig"
      fi
      continue
    fi
    if [ -n "$orig" ] && ! _ns_migrate_entry "$ns" "$orig"; then
      cp -p "$f" "$ns/$orig" || return 3
    fi
    tmp="${f%/*}/.$base.migrate.$$"
    if ! NS_MIG_EXISTS="$exists" NS_MIG_MOVES="$carry" NS_MIG_ROOT="$ns" \
      awk -v dir="$dir" -v olddirs="$olddirs" -v mode=apply -f "$NS_MIGRATE_LINKS_AWK" <"$f" >"$tmp" \
      || ! mv "$tmp" "$f"; then
      rm -f "$tmp"
      return 3
    fi
  done
}

# ns_migrate_render <preview|apply> — the plan records on stdin as lines an owner reads.
ns_migrate_render() {
  awk -F '\t' -v mode="$1" '
    $1 == "state" { next }
    $1 == "refuse" { printf "  refuse    %s\n", $2; refused = 1; next }
    $1 == "move" { printf "  move      %s -> %s\n", $2, $3; n++; next }
    $1 == "leave" && $4 == "same" { printf "  leave     %s (the same content is already at %s)\n", $2, $3; next }
    $1 == "leave" { printf "  leave     %s/ (empty; %s/ is already there)\n", $2, $3; next }
    $1 == "conflict" && $4 != "" { printf "  conflict  %s %s\n", $2, $4; conflict = 1; next }
    $1 == "conflict" { printf "  conflict  %s and %s are both there and differ - keep one by hand\n", $2, $3; conflict = 1; next }
    $1 == "rename" { printf "  rename    %s: %s -> %s\n", $2, $3, $4; n++; next }
    $1 == "drop" { printf "  drop      %s: %s (the same value is already under %s)\n", $2, $3, $4; n++; next }
    $1 == "retire" { printf "  retire    %s: %s (no version reads it)\n", $2, $3; n++; next }
    $1 == "link" { printf "  link      %s: %s -> %s\n", $2, $3, $4; n++; next }
    $1 == "original" { printf "  original  %s keeps the archived file as it was\n", $2; next }
    $1 == "ignore" { printf "  ignore    %s: add %s\n", $2, $3; n++; next }
    $1 == "unknown" { printf "  unknown   %s (no Nightshift file has this name; left in place)\n", $2; next }
    $1 == "stray" { printf "  stray     %s (an earlier Setup copied a template here and nothing reads it; left in place, safe to delete)\n", $2; next }
    $1 == "note" { printf "  note      %s\n", $2; next }
    $1 == "marker" { printf "  marker    state-version %s -> %s\n", $2, $3; n++; next }
    END {
      if (refused || conflict) {
        print "Refused - nothing was changed."
      } else if (mode == "apply") {
        print "Applied. Nothing was deleted or overwritten."
      } else if (n == 0) {
        print "Every file is where the current layout keeps it; nothing to do."
      } else {
        print "Preview only - nothing was changed. Run it again with --apply to make these changes; nothing is deleted or overwritten."
      }
    }'
}

# ns_migrate_offer <plan-file> <preview-command> — the move a plan makes, in one line for Doctor
# and Setup: each file with its old and new path, what else it changes, and the command that
# previews it. Status 1 when the plan changes nothing.
ns_migrate_offer() {
  awk -F '\t' -v cmd="$2" -v version="$NS_STATE_VERSION" '
    $1 == "move" { moves = moves (moves == "" ? "" : ", ") $2 " -> " $3; n++ }
    $1 == "rename" { other = other "; " $2 " " $3 " -> " $4; n++ }
    $1 == "drop" || $1 == "retire" { settings++; n++ }
    $1 == "link" { links++; n++ }
    $1 == "ignore" { other = other "; " $2 " leaves " $3 " out"; n++ }
    $1 == "marker" { marker = "; state-version " $2 " -> " $3; n++ }
    END {
      if (n == 0) exit 1
      out = "move the state files into layout " version
      if (moves != "") out = out ": " moves
      out = out other
      if (settings) out = out "; " settings " retired setting" (settings == 1 ? "" : "s") " removed"
      if (links) out = out "; " links " link" (links == 1 ? "" : "s") " written again so they still resolve"
      out = out marker "; nothing is deleted or overwritten. Preview it with " cmd ", then run it again with --apply"
      print out
    }' "$1"
}

# ns_migrate_apply <workspace> <plan-file> — perform a plan ns_migrate_plan wrote. The caller has
# checked it holds no refuse or conflict record.
# Return: 0 done · 3 a move or write failed (whatever finished stands; running it again completes it)
ns_migrate_apply() {
  local ws="$1" plan="$2" ns kind a b c d moves="" tmp
  ns="$ws/.nightshift"
  while IFS="$_NS_MIG_TAB" read -r kind a b c; do
    case "$kind" in
      move)
        _ns_migrate_entry "$ns" "$b" && return 3
        mkdir -p "$ns/${b%/*}" 2>/dev/null || [ "${b%/*}" = "$b" ] || return 3
        mv "$ns/$a" "$ns/$b" || return 3
        moves="$moves$a$_NS_MIG_TAB$b
"
        ;;
    esac
  done <"$plan"
  while IFS="$_NS_MIG_TAB" read -r kind a b c; do
    case "$kind" in
      rename | drop | retire)
        tmp="$ns/${a%/*}/.${a##*/}.migrate.$$"
        [ "${a%/*}" != "$a" ] || tmp="$ns/.$a.migrate.$$"
        case "$kind" in
          rename) _ns_migrate_json renamekey "$ns/$a" "$b" "$c" >"$tmp" ;;
          drop | retire) _ns_migrate_json dropkey "$ns/$a" "$b" >"$tmp" ;;
        esac
        if [ ! -s "$tmp" ] || ! mv "$tmp" "$ns/$a"; then
          rm -f "$tmp"
          return 3
        fi
        ;;
    esac
  done <"$plan"
  if grep -q "^link$_NS_MIG_TAB" "$plan"; then
    _ns_migrate_links "$ws" "" apply || return 3
  fi
  while IFS="$_NS_MIG_TAB" read -r kind a b c; do
    [ "$kind" = ignore ] || continue
    # A last line without its newline would otherwise run into the one added.
    if [ -s "$ns/$a" ] && [ -n "$(tail -c 1 "$ns/$a")" ]; then
      printf '\n' >>"$ns/$a" || return 3
    fi
    printf '%s\n' "$b" >>"$ns/$a" || return 3
  done <"$plan"
  d="$(awk -F '\t' '$1 == "marker" { print $3 }' "$plan")"
  if [ -n "$d" ]; then
    ns_write_state_version "$ws" "$d" || return 3
  fi
  return 0
}
