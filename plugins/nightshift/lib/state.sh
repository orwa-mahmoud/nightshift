#!/usr/bin/env bash
# Nightshift runtime state: rules, punch-list counts, schema, retention, watch-reason.

# The owner's rules file is the one copy of every knob: .nightshift/rules.json — nightshift's
# whole life lives in nightshift's folder, and deleting the folder deletes all of it. Hooks
# read the file directly — a change applies from the next tool call. An env var of the
# matching name, when set, overrides the file for the session: the test suite's lever and the
# power user's per-session exception, never a second copy the owner maintains.
# rule <project-dir> <file-key> <env-value> — prints the effective value ('' = default).
rule() {
  if [ -n "$3" ]; then printf '%s' "$3"; return; fi
  local f="$1/.nightshift/rules.json"
  [ -f "$f" ] || return 0
  ns_rules_get "$f" "$2"
}

# ns_receipts <project-dir> <field> — one field of the receipts block, or empty.
ns_receipts() {
  ns_policy_pref "$1" receipts "$2"
}

# ns_report — the old name. Same fields live under receipts now.
ns_report() {
  ns_receipts "$@"
}

# ns_receipts_enabled <project-dir> — status 0 unless the owner turned receipts off.
ns_receipts_enabled() {
  [ "$(ns_receipts "$1" enabled)" != false ]
}

ns_report_enabled() {
  ns_receipts_enabled "$1"
}

# ns_receipts_dir <project-dir> — the folder that holds the index, morning page, and item files.
ns_receipts_dir() {
  printf '%s/.nightshift/receipts' "$1"
}

# ns_receipt_slug <title> — title lowercased, non-alphanumerics collapsed to one -, trimmed, 60.
ns_receipt_slug() {
  printf '%s' "$1" | LC_ALL=C awk '
    {
      s = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        o = index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
        if (o) c = substr("abcdefghijklmnopqrstuvwxyz", o, 1)
        if (c ~ /[a-z0-9]/) s = s c
        else s = s "-"
      }
      gsub(/-+/, "-", s)
      gsub(/^-|-$/, "", s)
      if (length(s) > 60) {
        s = substr(s, 1, 60)
        gsub(/-$/, "", s)
      }
      print s
    }
  '
}

# ns_receipt_nn <label> — the item number as written: leading digits, or a letter+digits id.
ns_receipt_nn() {
  printf '%s' "$1" | LC_ALL=C awk '
    {
      if (match($0, /^[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit }
      if (match($0, /^[A-Za-z]+[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit }
    }
  '
}

# ns_receipt_title <label> — the words after the written number, for the slug.
ns_receipt_title() {
  printf '%s' "$1" | LC_ALL=C awk '
    {
      sub(/^[0-9]+\.[[:space:]]*/, "")
      sub(/^[A-Za-z]+[0-9]+[[:space:]]+/, "")
      print
    }
  '
}

# ns_receipt_basename <label> — NN-slug, no suffix.
ns_receipt_basename() {
  local label="$1" nn title slug
  nn="$(ns_receipt_nn "$label")"
  title="$(ns_receipt_title "$label")"
  [ -n "$title" ] || title="$label"
  if [ -n "$nn" ] && [ "$title" = "$label" ]; then
    printf '%s' "$nn"
    return 0
  fi
  slug="$(ns_receipt_slug "$title")"
  if [ -n "$nn" ] && [ -n "$slug" ]; then
    printf '%s-%s' "$nn" "$slug"
  elif [ -n "$slug" ]; then
    printf '%s' "$slug"
  else
    printf '%s' "$(ns_receipt_slug "$label")"
  fi
}

# ns_receipt_path <project-dir> <label> — the item's file under receipts/.
ns_receipt_path() {
  printf '%s/%s.md' "$(ns_receipts_dir "$1")" "$(ns_receipt_basename "$2")"
}

# ns_receipt_has_model_text <file> — status 0 when a line exists outside the runtime block
# and the gate-written heading.
ns_receipt_has_model_text() {
  local f="$1"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  awk '
    /^[[:space:]]*$/ { next }
    /^# / { next }
    /^\*\*Usage:\*\*/ { next }
    /^\*\*Duration:\*\*/ { next }
    /^  Source:/ { next }
    /^  Cache reads/ { next }
    { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$f"
}

# ns_receipts_missing_nns <project> — one item number per ticked item with no model text.
ns_receipts_missing_nns() {
  local project="$1" punch ns label base nn
  ns="$project/.nightshift"
  punch="$ns/punch-list.md"
  [ -f "$punch" ] || return 0
  ns_receipts_enabled "$project" || return 0
  ns_items_section "$punch" 2>/dev/null | awk '
    /^- \[[xX]\]/ {
      line = $0
      sub(/^- \[[xX]\][[:space:]]*\*\*/, "", line)
      sub(/^- \[[xX]\][[:space:]]*/, "", line)
      sub(/[[:space:]]+—.*$/, "", line)
      sub(/[[:space:]]+-[[:space:]].*$/, "", line)
      sub(/\*\*.*$/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      if (line != "") print line
    }
  ' | while IFS= read -r label || [ -n "$label" ]; do
    [ -n "$label" ] || continue
    base="$(ns_receipt_basename "$label")"
    ns_receipt_has_model_text "$ns/receipts/${base}.md" && continue
    nn="$(ns_receipt_nn "$label")"
    [ -n "$nn" ] || nn="$label"
    printf '%s\n' "$nn"
  done
}

ns_receipts_missing_count() {
  local n
  n="$(ns_receipts_missing_nns "$1" | grep -c . || true)"
  printf '%s' "${n:-0}"
}

# ns_usage_scale <n> — integer below 1000, one decimal k, one decimal M.
ns_usage_scale() {
  local n="$1"
  case "$n" in '' | *[!0-9]*) printf '%s' "$n"; return 0 ;; esac
  awk -v n="$n" 'BEGIN {
    if (n < 1000) { printf "%d", n; exit }
    if (n < 1000000) { printf "%.1fk", n / 1000; exit }
    printf "%.1fM", n / 1000000
  }'
}

# ns_receipts_shift_date <project-dir> — Date: on the punch list, else the policy day, else today.
ns_receipts_shift_date() {
  local punch="$1/.nightshift/punch-list.md" policy="$1/.nightshift/shift-policy.json" day
  if [ -f "$punch" ]; then
    day="$(sed -n 's/^Date:[[:space:]]*//p' "$punch" | head -n1)"
    day="${day%%[$'\r\n']*}"
    [ -n "$day" ] && { printf '%s' "$day"; return 0; }
  fi
  if [ -f "$policy" ]; then
    day="$(sed -n 's/.*"createdAt"[[:space:]]*:[[:space:]]*"\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p' "$policy" | head -n1)"
    [ -n "$day" ] && { printf '%s' "$day"; return 0; }
  fi
  date -u +%Y-%m-%d
}

# ns_receipts_write_index <project-dir> — rewrite receipts/README.md from the list, marks, files.
ns_receipts_write_index() {
  local project="$1" punch="$1/.nightshift/punch-list.md"
  local dir index date_s state base file tokens time
  local tok_in tok_out tok_sum tok_total=0
  local label line items rows
  dir="$(ns_receipts_dir "$project")"
  [ -n "$dir" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  [ ! -L "$dir" ] || return 0
  index="$dir/README.md"
  [ -L "$index" ] && return 0
  date_s="$(ns_receipts_shift_date "$project")"
  items="$(mktemp "${TMPDIR:-/tmp}/ns-receipts-index.XXXXXX")" || return 0
  rows="$(mktemp "${TMPDIR:-/tmp}/ns-receipts-rows.XXXXXX")" || { rm -f "$items"; return 0; }
  : >"$items"
  [ -f "$punch" ] && ns_items_section "$punch" >"$items" 2>/dev/null || :
  : >"$rows"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '- [ ] '*|'- [x] '*|'- [X] '*) ;;
      *) continue ;;
    esac
    state=open
    case "$line" in '- [x] '*|'- [X] '*) state=ticked ;; esac
    label="$line"
    label="${label#- [ ] }"
    label="${label#- [x] }"
    label="${label#- [X] }"
    label="${label#\*\*}"
    label="$(printf '%s' "$label" | awk '{
      sub(/[[:space:]]+—.*$/, "")
      sub(/[[:space:]]+-[[:space:]].*$/, "")
      sub(/\*\*.*$/, "")
      gsub(/[[:space:]]+$/, "")
      print
    }')"
    [ -n "$label" ] || continue
    base="$(ns_receipt_basename "$label")"
    file="./${base}.md"
    tokens='—'; time='—'; tok_sum=0
    if [ -f "$dir/${base}.md" ]; then
      tok_in="$(sed -n 's/.*exact:[[:space:]]*\([0-9][0-9]*\) \/ [0-9][0-9]* \/ [0-9][0-9]* \/ [0-9][0-9]*.*/\1/p' "$dir/${base}.md" | head -n1)"
      tok_out="$(sed -n 's/.*exact:[[:space:]]*[0-9][0-9]* \/ [0-9][0-9]* \/ [0-9][0-9]* \/ \([0-9][0-9]*\).*/\1/p' "$dir/${base}.md" | head -n1)"
      if [ -n "$tok_in" ] && [ -n "$tok_out" ]; then
        tok_sum=$((tok_in + tok_out))
        tok_total=$((tok_total + tok_sum))
        tokens="$(ns_usage_scale "$tok_sum")"
      fi
      time="$(sed -n 's/^\*\*Duration:\*\*[[:space:]]*//p' "$dir/${base}.md" | head -n1)"
      [ -n "$time" ] || time='—'
    fi
    printf '| %s | %s | **%s** | **%s** | [%s](%s) |\n' \
      "$label" "$state" "$tokens" "$time" "$file" "$file" >>"$rows"
  done <"$items"
  {
    printf '# Receipts — %s\n\n' "$date_s"
    printf '| Item | State | **Tokens** | **Time** | Receipt |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    cat "$rows"
    if [ "$tok_total" -gt 0 ]; then
      printf '| **Totals** |  | **%s** | **%s** |  |\n' "$(ns_usage_scale "$tok_total")" '—'
    else
      printf '| **Totals** |  | **%s** | **%s** |  |\n' '—' '—'
    fi
  } >"$index" 2>/dev/null || :
  rm -f "$items" "$rows"
}

# ns_migrate_receipts_layout <workspace> — report→receipts; shift-report.md → previous-report.md.
# Idempotent. Does not bump state-version. Leaves timestamp-named receipt files untouched.
ns_migrate_receipts_layout() {
  local ws="$1" ns="$1/.nightshift" rules policy report dest dir tmp
  [ -d "$ns" ] || return 0
  for rules in "$ns/rules.json" "$ns/shift-policy.json"; do
    [ -f "$rules" ] && [ ! -L "$rules" ] || continue
    if grep -q '"report"' "$rules" 2>/dev/null; then
      tmp="$rules.receipts-mig.$$"
      if command -v jq >/dev/null 2>&1; then
        jq 'if has("report") then
              .receipts = ((.receipts // .report) | del(.legacyItemReceipts))
              | del(.report)
            else . end' "$rules" >"$tmp" 2>/dev/null && mv "$tmp" "$rules"
      elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as f:
    d = json.load(f)
if "report" in d:
    src = dict(d.get("receipts") or d["report"])
    src.pop("legacyItemReceipts", None)
    d["receipts"] = src
    del d["report"]
    with open(p, "w", encoding="utf-8") as o:
        json.dump(d, o, indent=2, ensure_ascii=False)
        o.write("\n")
' "$rules" 2>/dev/null || rm -f "$tmp"
      fi
      rm -f "$tmp"
    fi
  done
  report="$ns/shift-report.md"
  dir="$ns/receipts"
  dest="$dir/previous-report.md"
  if [ -f "$report" ] && [ ! -L "$report" ]; then
    mkdir -p "$dir" 2>/dev/null || return 0
    if [ ! -e "$dest" ]; then
      mv "$report" "$dest" 2>/dev/null || :
    fi
  fi
}

# ns_archive <project-dir> <field> — one field of the archive block, or empty.
ns_archive() {
  ns_policy_pref "$1" archive "$2"
}

# The ending marker carries what filing still needs after the live policy has moved.
#
# Clock-out archives the policy, and a later Archive would then have no shift id to name a
# directory after and no frozen archive settings to file into — so one shift's records could land
# half under its own name and half under a date, and an owner edit between the two would move the
# destination. The marker that already says the shift ended says which shift, and where it files.
# One line per field, `key=value`, and an empty marker stays a valid ending.
#
# ns_ended_record <state-dir> <shift-id> <archive-root-name> <archive-layout>
ns_ended_record() {
  local ns="$1"
  [ -d "$ns" ] || return 0
  [ -L "$ns/.ended" ] && rm -f "$ns/.ended"
  printf 'shiftId=%s\narchiveRoot=%s\narchiveLayout=%s\n' "$2" "$3" "$4" >"$ns/.ended" 2>/dev/null || :
}

# ns_ended_field <project-dir> <key> — one field of the ending marker, or empty.
ns_ended_field() {
  local f="$1/.nightshift/.ended"
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  sed -n "s/^$2=//p" "$f" 2>/dev/null | head -n1
}

# ns_state_path <state-dir> <relative-name> — a nested path under the Nightshift state area, or
# status 2. The whole chain is checked, not just its last component: a link anywhere along it is
# what an escape actually looks like, because `linked/history` reaches outside while `history` is
# an ordinary directory nobody would question.
#
# Refused: an absolute or ~ path, any component that is empty, `.`, `..` or begins with a dot,
# an existing component that is a symlink, an existing component that is not a directory, and the
# state directory itself. Then the deepest ancestor that exists is canonicalised and checked to
# be the state directory or inside it — comparing the real paths rather than trusting that the
# text of one is a prefix of the other.
ns_state_path() {
  local ns="$1" rel="$2" path comp rest deepest canon_ns canon_deep
  case "$rel" in
    '' | . | /* | '~'*) return 2 ;;
  esac
  path="$ns"
  deepest="$ns"
  rest="$rel"
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
    case "$comp" in
      '' | .*) return 2 ;;
    esac
    path="$path/$comp"
    [ ! -L "$path" ] || return 2
    if [ -e "$path" ]; then
      [ -d "$path" ] || return 2
      deepest="$path"
    fi
  done
  canon_ns="$(cd -P "$ns" 2>/dev/null && pwd -P)" || return 2
  canon_deep="$(cd -P "$deepest" 2>/dev/null && pwd -P)" || return 2
  case "$canon_deep" in
    "$canon_ns" | "$canon_ns"/*) ;;
    *) return 2 ;;
  esac
  printf '%s' "$path"
}

# ns_archive_root <project-dir> — the directory dated archives live in, as an absolute path.
# The name is the owner's; where it may sit is not. It stays inside the Nightshift state area,
# and a request to leave it is refused with status 2 so the caller says so rather than writing
# the owner's records somewhere they cannot find them. Writing outside the state area is an
# unsupported request, not a setting.
ns_archive_root() {
  local ns="$1/.nightshift" name
  name="$(ns_archive "$1" root)"
  [ -n "$name" ] || name=archive
  # The live records are not an archive destination: filing into them would file a shift on top
  # of the shift that is still running.
  case "$name" in
    receipts | receipts/*) return 2 ;;
  esac
  ns_state_path "$ns" "$name" || return 2
}

# ns_archive_dest <path> — status 0 when one file may be written at that exact path. A directory
# containment check says nothing about the leaf: a link left where a receipt is about to land
# would still carry its bytes somewhere else.
ns_archive_dest() {
  [ ! -L "$1" ] || return 2
  [ ! -e "$1" ] || [ -f "$1" ] || return 2
}

# ns_archive_dir <project-dir> <date> <shift-id> — the directory one shift is filed into.
# The date layout groups a night together; the shift layout gives each shift its own directory.
# The shift id names the files inside either way, so two shifts on one day never collide.
ns_archive_dir() {
  local root layout
  root="$(ns_archive_root "$1")" || return 2
  layout="$(ns_archive "$1" layout)"
  if [ "$layout" = shift ] && [ -n "$3" ] && [ "$3" != unknown ]; then
    printf '%s/shift-%s' "$root" "$3"
    return 0
  fi
  printf '%s/%s' "$root" "$2"
}

# ns_archive_automatic <project-dir> — status 0 when the owner asked for filing at clock-out.
# Filing is a copy; it never implies deleting anything.
ns_archive_automatic() {
  [ "$(ns_archive "$1" automatic)" = true ]
}

# ns_review_handled <text> — status 0 when the entry carries a filing disposition.
ns_review_handled() {
  printf '%s\n' "$1" | grep -qiE ' · (fixed|ignored|answered|rejected-because|accepted-tradeoff)( ·|$)'
}

# ns_archive_review_label <date> <shift-id> <layout>
ns_archive_review_label() {
  if [ "$3" = shift ] && [ -n "$2" ] && [ "$2" != unknown ]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

# ns_archive_review_dest <project> <date> <shift-id> <basename>
# Date layout names the file with the shift so two nights on one day stay distinct.
ns_archive_review_dest() {
  local group layout
  group="$(ns_archive_dir "$1" "$2" "$3")" || return 2
  layout="$(ns_archive "$1" layout)"
  if [ "$layout" != shift ] && [ -n "$3" ] && [ "$3" != unknown ]; then
    printf '%s/%s/%s' "$group" "$3" "$4"
    return 0
  fi
  printf '%s/%s' "$group" "$4"
}

# ns_archive_pointer_line <label> <relpath>
ns_archive_pointer_line() {
  printf 'Filed: [%s](%s)' "$1" "$2"
}

# ns_archive_rel_from_ns <nightshift-dir> <absolute-dest>
ns_archive_rel_from_ns() {
  local ns="$1" dest="$2"
  printf '%s' "${dest#"$ns"/}"
}

# ns_archive_file_review_source <project> <basename> <date> <shift-id>
# Moves handled entries from the live review file into the archive dest and appends one pointer.
ns_archive_file_review_source() {
  local project="$1" base="$2" date="$3" shift_id="$4"
  local ns live dest label rel layout tmp filed ptr title
  ns="$project/.nightshift"
  live="$ns/$base"
  [ -f "$live" ] && [ ! -L "$live" ] || return 0
  dest="$(ns_archive_review_dest "$project" "$date" "$shift_id" "$base")" || return 2
  layout="$(ns_archive "$project" layout)"
  label="$(ns_archive_review_label "$date" "$shift_id" "$layout")"
  rel="$(ns_archive_rel_from_ns "$ns" "$dest")"
  case "$rel" in
    '' | /*) return 2 ;;
  esac
  tmp="$(mktemp)" || return 2
  filed="$(mktemp)" || {
    rm -f "$tmp"
    return 2
  }
  awk -v filed="$filed" '
    function handled(s) {
      t = tolower(s)
      return t ~ / · (fixed|ignored|answered|rejected-because|accepted-tradeoff)( ·|$)/
    }
    /^Filed:/ { print; next }
    /^- Filed:/ { print; next }
    /^- / {
      if (handled($0)) { print $0 >> filed; next }
    }
    { print }
  ' "$live" >"$tmp" || {
    rm -f "$tmp" "$filed"
    return 2
  }
  if [ ! -s "$filed" ]; then
    rm -f "$tmp" "$filed"
    return 0
  fi
  if ! ns_archive_dest "$dest"; then
    rm -f "$tmp" "$filed"
    return 2
  fi
  mkdir -p "${dest%/*}" || {
    rm -f "$tmp" "$filed"
    return 2
  }
  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    printf '\n' >>"$dest"
    cat "$filed" >>"$dest"
  else
    if [ "$base" = snag-log.md ]; then
      title='# Snag Log'
    else
      title='# Parking Lot'
    fi
    printf '%s\n\n' "$title" >"$dest"
    cat "$filed" >>"$dest"
  fi
  ptr="$(ns_archive_pointer_line "$label" "$rel")"
  if ! grep -qxF "$ptr" "$tmp"; then
    printf '\n%s\n' "$ptr" >>"$tmp"
  fi
  mv "$tmp" "$live" || {
    rm -f "$tmp" "$filed"
    return 2
  }
  rm -f "$filed"
  return 0
}

# ns_archive_check_review_pointers <project> — one snag per missing Filed: target.
ns_archive_check_review_pointers() {
  local project="$1" ns live dest rel line snag
  ns="$project/.nightshift"
  snag="$ns/snag-log.md"
  for live in "$ns/snag-log.md" "$ns/parking-lot.md"; do
    [ -f "$live" ] && [ ! -L "$live" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\n' "$line" | grep -qE '^Filed: \[[^]]+\]\([^)]+\)$' || continue
      rel="${line#*']('}"
      rel="${rel%')'}"
      [ -n "$rel" ] || continue
      dest=""
      case "$rel" in
        /* | *..*) dest="" ;;
        *) dest="$ns/$rel" ;;
      esac
      if [ -n "$dest" ] && [ -f "$dest" ] && [ ! -L "$dest" ]; then
        continue
      fi
      if [ -f "$snag" ] && grep -qF "broken archive pointer · $rel " "$snag"; then
        continue
      fi
      if [ ! -f "$snag" ]; then
        printf '# Snag Log\n\n' >"$snag" || return 2
      fi
      printf -- '- broken archive pointer · %s is not a readable file\n' "$rel" >>"$snag"
    done <"$live"
  done
  return 0
}

# ns_archive_file_review_records <project> <date> <shift-id>
ns_archive_file_review_records() {
  ns_archive_file_review_source "$1" snag-log.md "$2" "$3" || return $?
  ns_archive_file_review_source "$1" parking-lot.md "$2" "$3" || return $?
  ns_archive_check_review_pointers "$1"
}

# ns_handoff <project-dir> <field> — one field of the handoff block, or empty when the file says
# nothing. Presentation only: none of it decides whether a check ran.
ns_handoff() {
  ns_policy_pref "$1" handoff "$2"
}

# ns_handoff_enabled <project-dir> — status 0 unless the owner turned the page off. A shift that
# writes no page still keeps every factual record it made.
ns_handoff_enabled() {
  [ "$(ns_handoff "$1" enabled)" != false ]
}

# ns_handoff_view <project-dir> — the configured reader, or owner.
ns_handoff_view() {
  local v
  v="$(ns_handoff "$1" view)"
  case "$v" in
    owner | reviewer | release | artifact) printf '%s' "$v" ;;
    *) printf 'owner' ;;
  esac
}

# ns_recovery_launch_scope <project-dir> — the permission scope a revived session starts under.
# host-grant is the documented grant for the host; host-default adds no permission argument and
# takes whatever the host gives. Anything else, or an unreadable file, is host-grant: recovery
# keeps working, and the scope in force is logged either way. The watchman never widens it.
ns_recovery_launch_scope() {
  local v=""
  if [ -n "${NIGHTSHIFT_LAUNCH_SCOPE:-}" ]; then
    v="$NIGHTSHIFT_LAUNCH_SCOPE"
  else
    v="$(ns_policy_pref "$1" recovery launchScope)"
  fi
  case "$v" in
    host-default) printf 'host-default' ;;
    host-grant) printf 'host-grant' ;;
    *) printf 'inherit-recorded-scope' ;;
  esac
}

# ns_policy_host_name — which host this session is, from what the host itself sets.
ns_policy_host_name() {
  if [ -n "${CURSOR_PLUGIN_ROOT:-}" ]; then
    printf 'cursor'
  elif [ -n "${CODEX_PROJECT_DIR:-}${CODEX_SANDBOX:-}${CODEX_SANDBOX_MODE:-}" ]; then
    printf 'codex'
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}${CLAUDE_PROJECT_DIR:-}" ]; then
    printf 'claude'
  else
    printf 'unknown'
  fi
}

# ns_launch_scope_supported <host> <scope> — true when the host can actually be asked to start a
# session at that scope. A recorded scope is only useful if a revival can name it on the command
# line, so this is the vocabulary the watchmen are allowed to pass through, and nothing else
# reaches a native flag.
ns_launch_scope_supported() {
  case "$1" in
    codex)
      case "$2" in
        read-only | workspace-write | danger-full-access) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# ns_launch_observed <host> — the execution scope this session is running under, in the host's own
# words, and whether the host actually told us. Read only from what the host already exposes; a
# scope nobody reported is unavailable, never assumed.
#
# Only Codex names a session's sandbox, and only in its own environment. Claude Code and Cursor
# hand a session its permissions at launch and expose no name for them anywhere a hook can read,
# so there is nothing to observe and this says so. Calling that 'inherited' would have been a
# label for a measurement never taken.
ns_launch_observed() {
  case "$1" in
    codex)
      if [ -n "${CODEX_SANDBOX_MODE:-}" ]; then
        printf '%s\tobserved' "$CODEX_SANDBOX_MODE"
        return 0
      fi
      if [ -n "${CODEX_SANDBOX:-}" ]; then
        printf '%s\tobserved' "$CODEX_SANDBOX"
        return 0
      fi
      ;;
  esac
  printf 'unknown\tunavailable'
}

# ns_recovery_effective_scope <project-dir> <host> — what a revival may actually ask for.
#
# The shipped choice inherits the scope the shift was started under, so recovery reproduces the
# session rather than improving on it. Nothing here ever widens what the original session had — an
# owner who wants the documented broad grant writes host-grant in their own file, and that is the
# only way it happens.
#
# There are four answers, and the caller logs the one it got:
#
#   host-default      the owner asked for it, or no scope was ever recorded. No permission
#                     argument is passed and the host decides. This is the baseline, not a proof
#                     that it is narrower than the original session — no host reports enough for
#                     that claim, and it is not made.
#   host-grant        the owner wrote it by name. Only ever from their own file.
#   recorded:<scope>  the shift recorded a scope the host observed and can be asked for again.
#   unavailable:<s>   a scope was recorded that this host has no way to request. A revival would
#                     run at some other scope, so the caller refuses rather than guess.
ns_recovery_effective_scope() {
  local configured recorded provenance
  configured="$(ns_recovery_launch_scope "$1")"
  case "$configured" in
    host-default | host-grant)
      printf '%s' "$configured"
      return 0
      ;;
  esac
  _ns_policy_load_shift "$1"
  case "$NS_POLICY_SHIFT_STATE" in
    ok) ;;
    absent)
      printf 'unavailable:unrecorded'
      return 0
      ;;
    *)
      printf 'unavailable:unreadable'
      return 0
      ;;
  esac
  recorded="$(ns_policy_launch "$1" scope 2>/dev/null)" || recorded=""
  provenance="$(ns_policy_launch "$1" provenance 2>/dev/null)" || provenance=""
  if [ "$provenance" = observed ] && [ -n "$recorded" ] && [ "$recorded" != unknown ]; then
    if ns_launch_scope_supported "$2" "$recorded"; then
      printf 'recorded:%s' "$recorded"
    else
      printf 'unavailable:unsupported:%s' "$recorded"
    fi
    return 0
  fi
  printf 'unavailable:unrecorded'
}

# ns_recovery_refusal <effective-scope> — the one sentence that says why a revival is refused.
# Status 1 for a scope that is not a refusal.
ns_recovery_refusal() {
  case "$1" in
    unavailable:unrecorded)
      printf 'the host named no scope for the session this shift was started in, so there is nothing to inherit and no way to show a revival would be no broader'
      ;;
    unavailable:unreadable)
      printf 'the policy that records the launch scope cannot be read, so what this shift was started under is unknown'
      ;;
    unavailable:unsupported:*)
      printf "the shift was started under '%s', which this host has no way to be asked for again" "${1#unavailable:unsupported:}"
      ;;
    *) return 1 ;;
  esac
}

# toolDeny requires exact key matching. The shipped reader accepts the template's
# object-of-strings shape and nothing else. Malformed input fails closed.
ns_tool_map_ok() { # stdin = a JSON object of string values
  local raw
  raw="$(cat)"
  ns_rules_map_parse "$raw" || return 1
  printf '%s' "$raw"
}

ns_tool_rules() { # $1 = project dir, $2 = session override
  local f="$1/.nightshift/rules.json" raw
  if [ -n "$2" ]; then
    raw="$2"
    ns_rules_map_parse "$raw" || {
      printf '%s' '__nightshift_invalid_tool_rules__'
      return
    }
    printf '%s' "$raw"
    return
  fi
  [ -f "$f" ] || return 0
  ns_rules_load "$f" || {
    printf '%s' '__nightshift_invalid_tool_rules__'
    return
  }
  ns_rules_tool_deny_json "$f"
}

# The punch list's `## Items` heading is the boundary between the owner's contract and the work.
# A checkbox above it is prose — an example, a note — and holds nobody. Both the gate and the
# watchman must agree on that boundary: a watchman counting a different range would keep reviving
# a shift the gate considers finished. One implementation is how they cannot disagree.
ns_items_section() { sed -n '/^## Items[[:space:]]*$/,$p' "$1" 2>/dev/null; }

# A count is a verdict about how much work is open, so it is either a number or a failure —
# never a silent zero. An absent list is the one honest zero: there is no work because there is
# no list. Everything else that can go wrong — the file exists but cannot be read, sed or grep is
# missing from a stripped PATH, the ERE is rejected — returns non-zero and prints nothing, and
# callers hold the site armed and the gate shut on that.
#
# grep -c prints the count AND exits 1 on zero matches, so status 1 is a real answer here and
# only status 2 and up is an error. The pipeline is split so the reader's status is its own.
ns_count_boxes() { # $1 = punch list, $2 = ERE for the box state
  local section n rc
  [ -e "$1" ] || { printf '0'; return 0; }
  [ -r "$1" ] || return 1
  section="$(ns_items_section "$1")" || return 1
  n="$(printf '%s\n' "$section" | grep -cE "$2" 2>/dev/null)"
  rc=$?
  [ "$rc" -le 1 ] || return 1
  case "$n" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$n"
}

ns_open_boxes()   { ns_count_boxes "$1" '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]'; }
ns_ticked_boxes() { ns_count_boxes "$1" '^[[:space:]]*-[[:space:]]*\[[xX]\]'; }

# Work orders have no ## Items heading. Count every top-level open box in the file.
ns_open_boxes_file() {
  local n
  n="$(grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' "$1" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# Drafting table: the fenced item-shape example sits above the first --- rule.
ns_open_drafts() {
  [ -f "$1" ] || { printf '0'; return 0; }
  awk '
    /^---[[:space:]]*$/ { seen=1; next }
    seen && /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/ { n++ }
    END { print n+0 }
  ' "$1"
}

# Watchman reason codes — one token, no transcript. Written to .nightshift/.watch-reason
# (line 1 = code, line 2 = optional non-sensitive detail). Status and Doctor render the same
# labels. Adding a code here is the contract; callers must not invent ad-hoc strings.
ns_reason_label() {
  case "$1" in
    completed) printf 'shift completed' ;;
    owner-stop) printf 'owner stop-work order' ;;
    owner-disarm) printf 'shift disarmed - the armed marker is gone' ;;
    stale-pid) printf 'recorded process is stale' ;;
    invalid-session) printf 'session identity is missing or unreadable' ;;
    exhausted-retry) printf 'revival retries exhausted this wake' ;;
    unknown-wedge) printf 'session looks wedged without a verified error signature' ;;
    revived) printf 'session revived into its own conversation' ;;
    stand-down) printf 'watchman stood down' ;;
    wrong-host) printf 'watchman stood down - shift belongs to another host' ;;
    deadline) printf 'quitting time passed' ;;
    clean-session-end) printf 'owner closed the session' ;;
    esc-standby) printf 'standing by - owner interrupt in the transcript' ;;
    silent-standby) printf 'standing by - session alive and quiet' ;;
    non-resumable-session) printf 'recorded Codex identity cannot be resumed' ;;
    unreadable-rules) printf 'rules file missing or incomplete' ;;
    fresh-fallback) printf 'fresh session - punch list is the handover' ;;
    unsupported-state) printf 'workspace state-version is unsupported' ;;
    recovery-scope-unavailable) printf 'recorded launch scope cannot be requested on this host' ;;
    process-evidence-unavailable) printf 'process evidence is unavailable' ;;
    clock-out-failed) printf 'terminal clock-out failed without releasing the shift' ;;
    *) printf 'unknown watchman outcome' ;;
  esac
}

ns_record_reason() { # <nightshift-dir> <code> [detail]
  local dir="$1" code="$2" detail="${3:-}"
  [ -d "$dir" ] || return 1
  case "$code" in
    completed|owner-stop|owner-disarm|stale-pid|invalid-session|exhausted-retry|unknown-wedge|revived|stand-down|wrong-host|deadline|clean-session-end|esc-standby|silent-standby|non-resumable-session|unreadable-rules|fresh-fallback|unsupported-state|process-evidence-unavailable|clock-out-failed|recovery-scope-unavailable) ;;
    *) code="stand-down" ;;
  esac
  detail="$(printf '%s' "$detail" | tr -d '\000-\037' | sed 's/[[:space:]]*$//')"
  printf '%s\n%s\n' "$code" "$detail" >"$dir/.watch-reason"
}

ns_reason_code() { sed -n 1p "$1/.watch-reason" 2>/dev/null | tr -d '[:space:]'; }
ns_reason_detail() { sed -n 2p "$1/.watch-reason" 2>/dev/null; }

# The shift log is the owner's record of what the runtime did. Append-only, one line per
# event, in the format the gate and the control helpers already write. Hooks do not load
# the control module, so this is the writer they share.
ns_shift_log() { # <nightshift-dir> <line>
  [ -d "$1" ] || return 0
  printf '%s · %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$2" >>"$1/shift-log.md"
}

# Workspace schema. One integer in .nightshift/state-version is the authority. This plugin
# supports version 1. A missing marker is legacy version 0 — existing files stay compatible,
# and only an explicit setup/Doctor repair writes the marker. Newer integers fail closed.
# Never rewrite or downgrade a future marker; never migrate from hooks, start, status,
# archive, or recovery.
NS_STATE_VERSION=1

# ns_state_kind <workspace>
# Prints: absent | legacy | current | malformed | future
# Return: 0 operable (legacy or current) · 1 malformed · 2 future · 3 absent
ns_state_kind() {
  local ws="$1" ns marker raw lines
  ns="$ws/.nightshift"
  if [ ! -d "$ns" ]; then
    printf 'absent'
    return 3
  fi
  marker="$ns/state-version"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    printf 'legacy'
    return 0
  fi
  if [ -L "$marker" ] || [ ! -f "$marker" ]; then
    printf 'malformed'
    return 1
  fi
  IFS= read -r raw <"$marker" || true
  raw="$(printf '%s' "$raw" | tr -d '\r')"
  lines="$(awk 'END { print NR + 0 }' "$marker" 2>/dev/null)"
  case "$raw" in
    '' | *[!0-9]*)
      printf 'malformed'
      return 1
      ;;
    0) ;;
    0*)
      printf 'malformed'
      return 1
      ;;
  esac
  if [ "${#raw}" -gt 8 ] || [ "$lines" -gt 1 ]; then
    printf 'malformed'
    return 1
  fi
  if [ "$raw" -gt "$NS_STATE_VERSION" ]; then
    printf 'future'
    return 2
  fi
  if [ "$raw" -eq "$NS_STATE_VERSION" ]; then
    printf 'current'
    return 0
  fi
  printf 'legacy'
  return 0
}

# ns_state_version <workspace>
# Prints the integer when it can be read (0 if the marker is missing). Empty on
# absent or malformed. Return matches ns_state_kind.
ns_state_version() {
  local ws="$1" kind raw
  kind="$(ns_state_kind "$ws")"
  case "$kind" in
    absent)
      return 3
      ;;
    legacy)
      printf '0'
      return 0
      ;;
    current)
      printf '%s' "$NS_STATE_VERSION"
      return 0
      ;;
    future)
      IFS= read -r raw <"$ws/.nightshift/state-version" || true
      raw="$(printf '%s' "$raw" | tr -d '\r')"
      printf '%s' "$raw"
      return 2
      ;;
    *)
      return 1
      ;;
  esac
}

# ns_state_refuse_message <kind> — hook and skill diagnostic; no paths, no guesses.
ns_state_refuse_message() {
  case "$1" in
    future)
      printf 'Nightshift state-version is newer than this plugin supports (supported: %s). Upgrade Nightshift; never rewrite or downgrade the marker.' "$NS_STATE_VERSION"
      ;;
    malformed)
      printf 'Nightshift state-version is malformed. Inspect it only while unarmed; never guess a version.'
      ;;
    *)
      printf 'Nightshift state-version is unsupported.'
      ;;
  esac
}

# ns_write_state_version <workspace> <integer>
# Atomic replace of the marker. Refuses a symlink destination. Touches no other file.
ns_write_state_version() {
  local ws="$1" n="$2" ns marker tmp
  ns="$ws/.nightshift"
  marker="$ns/state-version"
  case "$n" in
    '' | *[!0-9]* | 0?*) return 1 ;;
  esac
  [ -d "$ns" ] || return 1
  if [ -L "$marker" ]; then
    return 1
  fi
  tmp="$ns/.state-version.$$"
  printf '%s\n' "$n" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$marker" || { rm -f "$tmp"; return 1; }
}

# ns_migrate_state <workspace>
# Legacy 0 → 1: write only the marker. Idempotent when already current.
# Return: 0 migrated or already current · 1 armed · 2 unsupported · 3 write failed
# Callers: setup and an explicit Doctor repair only. Never hooks, start, status, archive, recovery.
ns_migrate_state() {
  local ws="$1" kind
  kind="$(ns_state_kind "$ws")"
  case "$kind" in
    current)
      ns_migrate_receipts_layout "$ws"
      return 0
      ;;
    legacy)
      if [ -f "$ws/.nightshift/.shift-armed" ]; then
        return 1
      fi
      ns_migrate_receipts_layout "$ws"
      ns_write_state_version "$ws" "$NS_STATE_VERSION" || return 3
      return 0
      ;;
    *)
      return 2
      ;;
  esac
}

# Retention — archive-only, preview-first. 0 means keep forever. Unreadable rules
# also mean 0: a broken file must never become a delete. Hooks, start, status,
# Doctor, and recovery must not call these apply helpers.

# ns_retention_days <workspace> <runtimeLogDays|archiveDays>
# Prints a non-negative integer. Missing, nested, or unreadable → 0.
ns_retention_days() {
  local ws="$1" key="$2" f="$1/.nightshift/rules.json" raw=""
  case "$key" in
    runtimeLogDays)
      [ -z "${NIGHTSHIFT_RETENTION_RUNTIME_LOG_DAYS:-}" ] || { printf '%s' "$NIGHTSHIFT_RETENTION_RUNTIME_LOG_DAYS"; return 0; }
      ;;
    archiveDays)
      [ -z "${NIGHTSHIFT_RETENTION_ARCHIVE_DAYS:-}" ] || { printf '%s' "$NIGHTSHIFT_RETENTION_ARCHIVE_DAYS"; return 0; }
      ;;
    *)
      printf '0'
      return 0
      ;;
  esac
  if [ -f "$f" ]; then
    ns_rules_load "$f" && raw="$(_ns_rules_row retention "$key" "")" && {
      raw="${raw#*"$_NS_RULES_TAB"}"
    } || raw=0
  fi
  case "$raw" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "$raw" ;;
  esac
}

# True when a dated archive still holds open punch-list work or an armed marker.
ns_archive_has_open_work() {
  local dir="$1" f
  [ -d "$dir" ] || return 1
  [ ! -e "$dir/.shift-armed" ] || return 0
  [ ! -L "$dir/.shift-armed" ] || return 0
  for f in "$dir"/*; do
    if [ ! -f "$f" ] || [ -L "$f" ]; then
      continue
    fi
    case "${f##*/}" in
      punch-list.md | shipped.md)
        [ "$(ns_open_boxes "$f")" -eq 0 ] || return 0
        ;;
    esac
  done
  return 1
}

# ns_retention_eligible <workspace>
# Print "kind<TAB>rel<TAB>age<TAB>days" for allowlisted, old-enough, unprotected targets.
ns_retention_eligible() {
  local ws="$1" ns log_days arch_days age path rel
  ns="$ws/.nightshift"
  [ -d "$ns" ] || return 0
  log_days="$(ns_retention_days "$ws" runtimeLogDays)"
  arch_days="$(ns_retention_days "$ws" archiveDays)"

  if [ "$log_days" -gt 0 ] && [ -e "$ns/scheduled.log" ]; then
    path="$(ns_under_nightshift "$ws" scheduled.log)" && {
      age="$(ns_age_days "$path")" || age=""
      if [ -n "$age" ] && [ "$age" -ge "$log_days" ]; then
        printf '%s\t%s\t%s\t%s\n' runtime-log scheduled.log "$age" "$log_days"
      fi
    }
  fi

  [ "$arch_days" -gt 0 ] || return 0
  [ -d "$ns/archive" ] && [ ! -L "$ns/archive" ] || return 0
  for rel in "$ns/archive"/*; do
    [ -e "$rel" ] || continue
    rel="${rel#"$ns/"}"
    case "$rel" in
      archive/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      archive/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) rel="${rel%/}" ;;
      *) continue ;;
    esac
    if [ ! -d "$ns/$rel" ] || [ -L "$ns/$rel" ]; then
      continue
    fi
    path="$(ns_under_nightshift "$ws" "$rel")" || continue
    ns_archive_has_open_work "$path" && continue
    age="$(ns_age_days "$path")" || continue
    [ "$age" -ge "$arch_days" ] || continue
    printf '%s\t%s\t%s\t%s\n' archive "$rel" "$age" "$arch_days"
  done
}

# ns_retention_apply <workspace> — delete currently eligible allowlisted targets.
# Return: 0 deleted or nothing eligible · 1 armed · 2 refused/failed
ns_retention_apply() {
  local ws="$1" ns kind rel path
  ns="$ws/.nightshift"
  [ -d "$ns" ] || return 2
  if [ -f "$ns/.shift-armed" ]; then
    return 1
  fi
  while IFS="$(printf '\t')" read -r kind rel _ _; do
    [ -n "$rel" ] || continue
    path="$(ns_under_nightshift "$ws" "$rel")" || return 2
    case "$kind" in
      runtime-log)
        [ -f "$path" ] && [ ! -L "$path" ] || return 2
        rm -f "$path" || return 2
        ;;
      archive)
        [ -d "$path" ] && [ ! -L "$path" ] || return 2
        ns_archive_has_open_work "$path" && return 2
        rm -rf "$path" || return 2
        ;;
      *)
        return 2
        ;;
    esac
  done <<EOF
$(ns_retention_eligible "$ws")
EOF
}

# Artifact completion receipts live in .nightshift/receipts/. They replace a work-target
# git commit only while work-mode is artifact. Repository mode still requires a real commit.

# Real receipts directory only. A symlink here would let count, latest, and
# fingerprint follow files outside .nightshift/.
ns_receipts_usable_dir() {
  local dir
  dir="$(ns_receipts_dir "$1")"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  printf '%s' "$dir"
}

ns_file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

ns_receipts_count() {
  local dir n
  dir="$(ns_receipts_usable_dir "$1")" || {
    printf '0'
    return 0
  }
  n="$(find "$dir" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s' "${n:-0}"
}

# Newest completion receipt path, or status 1 when none exist.
# Primary key is mtime. Same-second uniqueness suffixes (`stamp-slug-n.md`)
# sort before `stamp-slug.md` in C locale (`-` < `.`), so a name-only sort
# can name the first write as latest. Tie-break maps `.md` → `-0.md` so the
# unsuffixed sibling sorts first and `-n` wins.
# The sort-row helper stays outside $(...) — a `case` `)` would close the substitution.
ns_latest_receipt_sort_row() {
  local path="$1" m key
  m="$(ns_mtime "$path")" || return 0
  case "$m" in
    '' | *[!0-9]*) return 0 ;;
  esac
  case "$path" in
    *.md) key="${path%.md}-0.md" ;;
    *) key="$path" ;;
  esac
  printf '%020d\t%s\t%s\n' "$m" "$key" "$path"
}

ns_latest_receipt() {
  local dir out tab
  dir="$(ns_receipts_usable_dir "$1")" || return 1
  out="$(
    find "$dir" -maxdepth 1 -type f ! -name '.*' -print 2>/dev/null | while IFS= read -r path; do
      [ -n "$path" ] || continue
      ns_latest_receipt_sort_row "$path"
    done | LC_ALL=C sort | tail -n 1
  )"
  [ -n "$out" ] || return 1
  tab="$(printf '\t')"
  printf '%s' "${out##*"$tab"}"
}

# Stable stall token: none when the directory is empty, otherwise a cksum of every receipt.
ns_receipts_fingerprint() {
  local dir out
  dir="$(ns_receipts_usable_dir "$1")" || {
    printf 'none'
    return 0
  }
  out="$(find "$dir" -maxdepth 1 -type f ! -name '.*' -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    cksum "$f" 2>/dev/null
  done)"
  if [ -z "$out" ]; then
    printf 'none'
    return 0
  fi
  printf '%s\n' "$out" | cksum | awk '{print $1"-"$2}'
}

# ---------------------------------------------------------------------------------------------
# Reading one item out of the punch list, and holding the contract to what it was
#
# The bounded rule the gate and Status already use: a top-level checkbox line owns the indented
# lines that follow it, up to the next top-level line. Fenced code and nested lists inside an item
# are indented, so they belong to it and come through whole. This is not a Markdown parser and is
# not trying to be one.

# ns_punch_gates <punch-list> — the gates block verbatim, heading included, or nothing.
# The owner may change it mid-shift by design, so it is never digested and always reprinted.
ns_punch_gates() {
  awk '
    /^## Gates[[:space:]]*$/ { on = 1; print; next }
    on && /^## / { exit }
    on { print }
  ' "$1" 2>/dev/null
}

# ns_punch_items <punch-list> — the lines under `## Items`, stopping at the next top-level heading.
#
# Not ns_items_section, which runs to the end of the file: that is the right boundary for counting
# boxes and the wrong one for a digest, because it would put a `## Notes` section the owner is free
# to edit inside the thing the gate holds still.
ns_punch_items() {
  awk '
    { sub(/\r$/, "") }
    !on { if ($0 ~ /^##[[:space:]]*Items[[:space:]]*$/) on = 1; next }
    /^## / { exit }
    { print }
  ' "$1" 2>/dev/null
}

# ns_punch_item <punch-list> <id> — one item with its sub-bullets, exactly as written. An empty id
# means the first still-open one. Prints nothing when there is no such item.
ns_punch_item() {
  ns_punch_items "$1" | awk -v want="$2" '
    function starts_item(line) { return line ~ /^- \[[ xX]\]/ }
    # A top-level line is anything not indented: the next item, a heading, a note. Either way this
    # item has ended.
    function top_level(line) { return line !~ /^[[:space:]]/ && line != "" }
    {
      if (!on && starts_item($0)) {
        if (want == "") {
          if ($0 !~ /^- \[ \]/) next
          on = 1
          print
          next
        }
        id = $0
        sub(/^- \[[ xX]\][[:space:]]*\*\*/, "", id)
        sub(/[[:space:]]+—.*$/, "", id)
        sub(/[[:space:]]+-[[:space:]].*$/, "", id)
        sub(/\*\*.*$/, "", id)
        gsub(/[[:space:]]+$/, "", id)
        if (id != want) next
        on = 1
        print
        next
      }
      if (on) {
        if (top_level($0)) exit
        print
      }
    }
  '
}

# ns_punch_contract <punch-list> — everything above `## Items` except the gates block: the shift
# contract the owner wrote and nobody may edit while a shift is armed.
#
# The gates block is excluded from this digest and from the items one. It sits above `## Items` in
# the file, but the owner is meant to be able to change it mid-shift — tightening a gate after a
# near miss, relaxing one that is costing more than it catches — and `gatesDigest` already tracks
# it on its own terms.
ns_punch_contract() {
  awk '
    { sub(/\r$/, "") }
    /^## Items[[:space:]]*$/ { exit }
    /^## Gates[[:space:]]*$/ { skip = 1; next }
    skip && /^## / { skip = 0 }
    skip { next }
    { print }
  ' "$1" 2>/dev/null
}

# ns_punch_items_normalised <punch-list> — every item line and sub-bullet with the checkbox state
# flattened, so ticking a box changes nothing and any other edit — a reworded item, a deleted one,
# an inserted one — changes everything.
#
# Line endings are flattened with it, here and in the contract. A shift can be handed from a macOS
# host to a Windows one, and a checkout that converts on the way would otherwise present a contract
# nobody touched as tampered with. The digest is a property of what the list says, not of how the
# filesystem it is sitting on ends a line.
ns_punch_items_normalised() {
  ns_punch_items "$1" | sed 's/^- \[[xX]\]/- [ ]/'
}

# ns_punch_digest — a stable digest of stdin, from whatever the machine has. Same shape as every
# other digest Nightshift records: 64 lowercase hex characters.
ns_punch_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | cut -d' ' -f1
  else
    return 1
  fi
}

# ns_punch_contract_digest <punch-list> / ns_punch_items_digest <punch-list>
ns_punch_contract_digest() { ns_punch_contract "$1" | ns_punch_digest; }
ns_punch_items_digest() { ns_punch_items_normalised "$1" | ns_punch_digest; }

# ---------------------------------------------------------------- preflight explanations
#
# The explanation belongs on the verdict line that occurred, not in a paragraph the model reads on
# every Start for verdicts that did not. It is printed here from lib/preflight-explain.txt, which
# the PowerShell twin reads too: one copy of the text, so the two hosts cannot word the same
# verdict differently.

# ns_explain_lines <kind> <topic> — the records of that kind for that topic, in file order.
# Prints nothing when the topic has none, which is not an error: a topic without a record keeps
# its verdict and its own repairs.
ns_explain_lines() {
  local file
  file="${NS_EXPLAIN_FILE:-}"
  [ -n "$file" ] || return 0
  [ -f "$file" ] || return 0
  awk -F '\t' -v kind="$1" -v topic="$2" '
    /^#/ || NF < 3 { next }
    $1 == kind && $2 == topic { print $3 }
  ' "$file" 2>/dev/null
}

# ns_explain_emit <topic> — the explanation for a topic, then any repairs the table carries for it.
# Called by the warn and refuse emitters, so no verdict site has to remember to do it.
ns_explain_emit() {
  ns_explain_lines explain "$1" | while IFS= read -r line; do
    [ -n "$line" ] && printf 'explain %s %s\n' "$1" "$line"
  done
  ns_explain_lines repair "$1" | while IFS= read -r line; do
    [ -n "$line" ] && printf 'repair %s\n' "$line"
  done
}

# ns_explain_topic <verdict text> — the first word, which every verdict leads with.
ns_explain_topic() {
  case "$1" in
    *' '*) printf '%s' "${1%% *}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------- the facts Status renders
#
# Counting is mechanics — the boxes below a heading, drafting-table boxes only after the first
# rule, the deadline against the clock, the stall counter. The skill renders; these produce, so
# none of it is derived by hand.
#
# Bounded readers, never Markdown parsers: each one takes the first line of an entry under the
# shape the file already has, so a file the owner has written prose into still yields facts rather
# than a guess.

# ns_status_open_title <punch-list> — the title line of the first still-open item, without its
# checkbox or bold markers. Empty when nothing is open.
ns_status_open_title() {
  ns_punch_item "$1" "" 2>/dev/null | awk '
    NR == 1 {
      sub(/^- \[[ xX]\][[:space:]]*/, "")
      gsub(/\*\*/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  '
}

# ns_status_entry_titles <file> <max> — the first line of each top-level `- ` entry, trimmed.
# Used for the parking lot and the snag log, which share that shape.
ns_status_entry_titles() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  awk -v max="${2:-0}" '
    /^Filed:/ { next }
    /^- Filed:/ { next }
    /^- / {
      line = $0
      sub(/^- /, "", line)
      gsub(/\*\*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (length(line) > 100) line = substr(line, 1, 97) "..."
      out[++n] = line
    }
    END {
      first = 1
      if (max > 0 && n > max) first = n - max + 1
      for (i = first; i <= n; i++) print out[i]
    }
  ' "$1" 2>/dev/null
}

# ns_status_entry_count <file> — how many such entries the file holds.
ns_status_entry_count() {
  if ! { [ -f "$1" ] && [ ! -L "$1" ]; }; then printf '0'; return 0; fi
  awk '/^Filed:/ { next } /^- Filed:/ { next } /^- / { n++ } END { printf "%d", n + 0 }' "$1" 2>/dev/null || printf '0'
}

# ns_status_opportunity_counts <opportunity-map> — `candidate=N building=N shipped=N rejected=N
# parked=N` from the `Status:` lines the map already carries.
ns_status_opportunity_counts() {
  if ! { [ -f "$1" ] && [ ! -L "$1" ]; }; then printf 'candidate=0 building=0 shipped=0 rejected=0 parked=0'; return 0; fi
  awk '
    /<!--/ { comment = 1 }
    /-->/  { comment = 0; next }
    comment { next }
    /^[[:space:]]*Status:[[:space:]]*/ {
      s = $0
      sub(/^[[:space:]]*Status:[[:space:]]*/, "", s)
      sub(/[[:space:]].*$/, "", s)
      gsub(/[^a-zA-Z]/, "", s)
      if (s != "") c[tolower(s)]++
    }
    END {
      printf "candidate=%d building=%d shipped=%d rejected=%d parked=%d",
        c["candidate"] + 0, c["building"] + 0, c["shipped"] + 0, c["rejected"] + 0, c["parked"] + 0
    }
  ' "$1" 2>/dev/null || printf 'candidate=0 building=0 shipped=0 rejected=0 parked=0'
}

# ns_status_building <opportunity-map> — the building entry's title, then its `Phase:`, `Next:` and
# `Verify remaining:` lines, one per line. Nothing when none is building.
#
# An entry runs from a heading to the next heading. More than one building entry is inconsistent
# state the model reports without changing; this prints the first, and the count says there is more.
ns_status_building() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  awk '
    /<!--/ { comment = 1 }
    /-->/  { comment = 0; next }
    comment { next }
    /^#{2,}[[:space:]]/ {
      if (found) exit
      title = $0
      sub(/^#+[[:space:]]*/, "", title)
      gsub(/\*\*/, "", title)
      building = 0
      next
    }
    /^[[:space:]]*Status:[[:space:]]*building/ {
      building = 1
      found = 1
      print "title\t" title
      next
    }
    building && /^[[:space:]]*(Phase|Next|Verify remaining):/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      key = line
      sub(/:.*$/, "", key)
      sub(/^[^:]*:[[:space:]]*/, "", line)
      print tolower(key) "\t" line
    }
  ' "$1" 2>/dev/null
}

# ns_status_stop_reason <ns> — the first line of the stop-work marker, or nothing.
ns_status_stop_reason() {
  ns_marker="$1/STOP"
  [ -f "$ns_marker" ] && [ ! -L "$ns_marker" ] || return 0
  IFS= read -r ns_line <"$ns_marker" 2>/dev/null || return 0
  printf '%s' "$ns_line"
}

# ns_status_transitions <shift-log> <max> — the journal lines that record a shift changing hands:
# a stand-down, a revival, a host change. Compacted to their first sentence.
ns_status_transitions() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  awk -v max="${2:-3}" '
    {
      line = $0
      # Both writers lead with a dash, a timestamp and a separator before the message. Everything up
      # to the first letter is that preamble, in any locale and with any separator byte.
      sub(/^[^A-Za-z]*/, "", line)
    }
    # A transition is a line whose SUBJECT is the shift changing hands. Matching the words anywhere
    # would catch an item summary that merely mentions one.
    tolower(line) ~ /^(watchman|the watchman|shift started|shift ended|the session ended|revived|host change)/ {
      if (length(line) > 120) line = substr(line, 1, 117) "..."
      out[++n] = line
    }
    END {
      first = 1
      if (max > 0 && n > max) first = n - max + 1
      for (i = first; i <= n; i++) print out[i]
    }
  ' "$1" 2>/dev/null
}

# ns_status_deadline_remaining <ns> — `<n>h<m>m remaining`, `passed`, or nothing when there is no
# deadline. The clock is read once, here, rather than in the skill.
ns_status_deadline_remaining() {
  ns_file="$1/deadline"
  [ -f "$ns_file" ] && [ ! -L "$ns_file" ] || return 0
  IFS= read -r ns_epoch <"$ns_file" 2>/dev/null || return 0
  case "$ns_epoch" in '' | *[!0-9]*) return 0 ;; esac
  ns_now="$(date +%s 2>/dev/null)" || return 0
  if [ "$ns_epoch" -le "$ns_now" ]; then
    printf 'passed'
    return 0
  fi
  ns_left=$((ns_epoch - ns_now))
  printf '%dh%02dm remaining' "$((ns_left / 3600))" "$(((ns_left % 3600) / 60))"
}
