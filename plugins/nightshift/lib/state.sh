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

# ns_report <project-dir> <field> — one field of the report block, or empty.
ns_report() {
  local f="$1/.nightshift/rules.json"
  [ -f "$f" ] || return 0
  ns_rules_get_in "$f" report "$2"
}

# ns_report_enabled <project-dir> — status 0 unless the owner turned the report off. A shift that
# writes no report still keeps its punch status, its outputs, its continuity and its verification.
ns_report_enabled() {
  [ "$(ns_report "$1" enabled)" != false ]
}

# ns_report_legacy_receipts <project-dir> — status 0 when the owner still wants the separate
# per-item receipt file beside the report section. Off by default: the section completes the item.
ns_report_legacy_receipts() {
  [ "$(ns_report "$1" legacyItemReceipts)" = true ]
}

# ns_report_path <project-dir> — the one report for the current shift.
ns_report_path() {
  printf '%s/.nightshift/shift-report.md' "$1"
}

# ns_archive <project-dir> <field> — one field of the archive block, or empty.
ns_archive() {
  local f="$1/.nightshift/rules.json"
  [ -f "$f" ] || return 0
  ns_rules_get_in "$f" archive "$2"
}

# ns_archive_root <project-dir> — the directory dated archives live in, as an absolute path.
# The name is the owner's; where it may sit is not. It stays inside the Nightshift state area:
# an absolute path, a path that climbs out with .., or a symlink is refused with status 2, and
# the caller says so rather than writing the owner's records somewhere they cannot find them.
# Writing outside the state area is an unsupported request, not a setting.
ns_archive_root() {
  local ns="$1/.nightshift" name resolved
  name="$(ns_archive "$1" root)"
  [ -n "$name" ] || name=archive
  case "$name" in
    /* | ~*) return 2 ;;
    *..*) return 2 ;;
  esac
  resolved="$ns/$name"
  [ ! -L "$resolved" ] || return 2
  printf '%s' "$resolved"
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

# ns_handoff <project-dir> <field> — one field of the handoff block, or empty when the file says
# nothing. Presentation only: none of it decides whether a check ran.
ns_handoff() {
  local f="$1/.nightshift/rules.json"
  [ -f "$f" ] || return 0
  ns_rules_get_in "$f" handoff "$2"
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
  local f="$1/.nightshift/rules.json" v=""
  if [ -n "${NIGHTSHIFT_LAUNCH_SCOPE:-}" ]; then
    v="$NIGHTSHIFT_LAUNCH_SCOPE"
  elif [ -f "$f" ]; then
    v="$(ns_rules_get_in "$f" recovery launchScope)"
  fi
  case "$v" in
    host-default) printf 'host-default' ;;
    *) printf 'host-grant' ;;
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
    process-evidence-unavailable) printf 'process evidence is unavailable' ;;
    clock-out-failed) printf 'terminal clock-out failed without releasing the shift' ;;
    *) printf 'unknown watchman outcome' ;;
  esac
}

ns_record_reason() { # <nightshift-dir> <code> [detail]
  local dir="$1" code="$2" detail="${3:-}"
  [ -d "$dir" ] || return 1
  case "$code" in
    completed|owner-stop|owner-disarm|stale-pid|invalid-session|exhausted-retry|unknown-wedge|revived|stand-down|wrong-host|deadline|clean-session-end|esc-standby|silent-standby|non-resumable-session|unreadable-rules|fresh-fallback|unsupported-state|process-evidence-unavailable|clock-out-failed) ;;
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
      return 0
      ;;
    legacy)
      if [ -f "$ws/.nightshift/.shift-armed" ]; then
        return 1
      fi
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

ns_receipts_dir() {
  printf '%s' "$1/.nightshift/receipts"
}

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

ns_receipt_slug() {
  local s
  s="$(printf '%s' "$1" | tr -cs 'A-Za-z0-9' '-' | tr '[:upper:]' '[:lower:]')"
  s="${s#-}"
  s="${s%-}"
  s="$(printf '%s' "$s" | cut -c1-40)"
  [ -n "$s" ] || s=item
  printf '%s' "$s"
}
