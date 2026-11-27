#!/usr/bin/env bash
# Shared clock-out decisions. Host wrappers own payload parsing and response emission.

_ns_gate_core_dir="${BASH_SOURCE[0]%/*}"
[ "$_ns_gate_core_dir" != "${BASH_SOURCE[0]}" ] || _ns_gate_core_dir=.
# shellcheck source=plugins/nightshift/lib/evidence-check.sh
. "$_ns_gate_core_dir/../../lib/evidence-check.sh"

# ns_gate_boxes — set OPEN, TICKED, TOTAL from the punch list. Return 1 when
# the file exists but cannot be read; then the counts are not a verdict and
# the caller must not release as "0 open".
# shellcheck disable=SC2034 # host wrappers read TOTAL after ns_gate_boxes
ns_gate_boxes() {
  OPEN=0
  TICKED=0
  TOTAL=0
  # shellcheck disable=SC2153 # the caller's global; a sourced local named punch is a different variable
  [ -f "$PUNCH" ] || return 0
  OPEN="$(ns_open_boxes "$PUNCH")" || {
    OPEN=0
    TICKED=0
    TOTAL=0
    return 1
  }
  TICKED="$(ns_ticked_boxes "$PUNCH")" || {
    OPEN=0
    TICKED=0
    TOTAL=0
    return 1
  }
  TOTAL=$((OPEN + TICKED))
  return 0
}

ns_gate_project_head() {
  local r
  # shellcheck disable=SC2153 # the caller's global; a sourced local named project_dir is a different variable
  if r="$(ns_work_target "$PROJECT_DIR")"; then
    git -C "$r" rev-parse HEAD 2>/dev/null || printf 'nohead'
  else
    printf 'nohead'
  fi
}

# Stall progress token: repository mode uses the work-target HEAD. Artifact mode has no HEAD to
# read, and hashing what the shift wrote about itself would make writing about the work look like
# doing it — a report update, a usage line, a rendered morning page or an archive pass would all
# read as progress. So artifact mode leans on the two signals that mean work actually moved: the
# tick count, which the caller already folds into this fingerprint, and a substantive checkpoint.
ns_gate_progress_token() {
  local mode mark ckpt
  mode="$(ns_work_mode "$PROJECT_DIR" 2>/dev/null)" || mode=repository
  if [ "$mode" = artifact ]; then
    mark=artifact
  else
    mark="$(ns_gate_project_head)"
  fi
  ckpt="$(ns_gate_checkpoint_token "$PROJECT_DIR")"
  printf '%s:%s' "$mark" "${ckpt:-none}"
}

# The gate honours the earlier of the projected deadline file and the shift policy's own
# deadlineEpoch. shift-policy.json is the authority; the file is a derived projection Start
# writes from it. A malformed or absent file falls back to the policy alone, and a malformed
# or absent policy falls back to the file alone — only when both are readable and disagree is
# the mismatch logged, naming both values, before the earlier one is used.
ns_gate_deadline_passed() {
  local now file_target="" policy_target="" target dl
  now="$(date +%s)"
  if [ ! -L "$DEADLINE" ] && [ -f "$DEADLINE" ]; then
    dl="$(tr -d '[:space:]' <"$DEADLINE" 2>/dev/null || true)"
    if [ -n "$dl" ]; then
      if printf '%s' "$dl" | grep -qE '^[0-9]+$'; then
        file_target="$dl"
      else
        file_target="$(date -d "$dl" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S' "$dl" +%s 2>/dev/null || true)"
      fi
    fi
  fi
  policy_target="$(ns_policy_deadline_epoch "$PROJECT_DIR" 2>/dev/null)" || policy_target=""
  target="$file_target"
  if [ -n "$policy_target" ]; then
    if [ -z "$target" ]; then
      target="$policy_target"
    elif [ "$policy_target" != "$target" ]; then
      log_line "deadline mismatch — deadline file $target does not match shift-policy deadlineEpoch $policy_target; honoring the earlier value"
      if [ "$policy_target" -lt "$target" ] 2>/dev/null; then
        target="$policy_target"
      fi
    fi
  fi
  [ -n "$target" ] && [ "$now" -ge "$target" ]
}

# The terminal sequence, shared so every host ends a shift the same way.
#
# Ending a shift and filing it are two different acts, and only one of them can happen inside a
# hook: filing decides which records are closed, which means reading the punch list and the work,
# which is the model's job. So the gate ends the shift, records what a later filing needs, and —
# when the owner asked for filing at clock-out — holds the session once more so the model can file
# before it stops. That is the whole transition, and it is executable: by the time the model is
# asked, the shift has genuinely ended.
#
# ns_gate_record_ending <nightshift-dir> <project-dir> <shift-id>
ns_gate_record_ending() {
  local ns="$1" project="$2" id="${3:-unknown}" pending name folder host
  # The shift's folder is claimed now, under its name when the owner gave it one, and the marker
  # remembers it: every later filing of this shift, clock-out's own included, lands there.
  name="$(ns_shift_name "$(ns_layout_path "$ns" punch-list)")"
  folder="$(ns_archive_dir "$project" "$(date +%Y-%m-%d)" "$id" "$name" 2>/dev/null)" || folder=""
  host=""
  ns_session_present "$ns" && host="$(ns_session_host "$ns")"
  ns_ended_record "$ns" "$id" \
    "$(ns_archive "$project" root)" "$(ns_archive "$project" layout)" "$name" "${folder##*/}" "$host"
  [ -d "$ns" ] || return 0
  ns_archive_automatic "$project" || return 0
  ns_layout_set pending "$ns" pending-filing
  [ -L "$pending" ] && rm -f "$pending"
  printf 'date=%s\nshiftId=%s\n' "$(date +%Y-%m-%d)" "$id" >"$pending" 2>/dev/null || :
}

# ns_gate_filing_due <nightshift-dir> — status 0 when the model still owes this ended shift its
# filing and has not been asked yet. Asking is recorded, so the next stop releases either way: a
# session that could not file leaves the marker for the next explicit Archive rather than being
# held forever by a hook that cannot do the filing itself.
ns_gate_filing_due() {
  local ns="$1" pending ended armed
  ns_layout_set pending "$ns" pending-filing
  ns_layout_set ended "$ns" ended
  ns_layout_set armed "$ns" armed
  [ -f "$ended" ] && [ ! -L "$ended" ] || return 1
  [ ! -f "$armed" ] || return 1
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  grep -q '^asked=1$' "$pending" 2>/dev/null && return 1
  printf 'asked=1\n' >>"$pending" 2>/dev/null || return 1
  return 0
}

# ns_gate_snags_due <nightshift-dir> — status 0 when this ended shift leaves snag-log entries with
# no disposition and the model has not been told yet. Telling is recorded in the ending marker, so
# the next stop releases either way: an entry left open on purpose stays for the owner.
ns_gate_snags_due() {
  local ns="$1" ended snag
  ns_layout_set ended "$ns" ended
  [ -f "$ended" ] && [ ! -L "$ended" ] || return 1
  grep -q '^snagsAsked=1$' "$ended" 2>/dev/null && return 1
  ns_layout_set snag "$ns" snag-log
  [ -n "$(ns_snag_open_lines "$snag")" ] || return 1
  printf 'snagsAsked=1\n' >>"$ended" 2>/dev/null || return 1
}

# ns_gate_snags_message <nightshift-dir> — what the model is told when entries carry no disposition:
# each by line, the first five of them.
ns_gate_snags_message() {
  local ns="$1" snag lines count named
  ns_layout_set snag "$ns" snag-log
  lines="$(ns_snag_open_lines "$snag")"
  count="$(printf '%s\n' "$lines" | grep -c .)"
  named="$(printf '%s\n' "$lines" | head -n 5 | awk -F '\t' 'NF { t = $2; if (length(t) > 80) t = substr(t, 1, 77) "..."; printf "%sline %s: %s", sep, $1, t; sep = "; " }')"
  if [ "$count" -eq 1 ]; then
    count='1 snag-log entry carries no disposition, so Archive keeps it'
  else
    count="$count snag-log entries carry no disposition, so Archive keeps them"
  fi
  printf 'BEFORE YOU STOP - %s live for the owner (%s). Give each one that is settled its disposition after a " · " separator - fixed in <commit>, ignored, answered, rejected-because <why> or accepted-tradeoff <why> - and leave open only what the owner must decide. Stopping again releases the session either way.' \
    "$count" "$named"
}

# ns_gate_ending_hold <nightshift-dir> — the one message an ended shift holds the session for, or
# nothing: undispositioned snags first, then filing when the owner asked for it.
ns_gate_ending_hold() {
  local ns="$1" out=""
  ns_gate_snags_due "$ns" && out="$(ns_gate_snags_message "$ns")"
  if ns_gate_filing_due "$ns"; then
    out="${out:+$out }$(ns_gate_filing_message "$ns")"
  fi
  printf '%s' "$out"
}

# ns_gate_filing_message <nightshift-dir> — what the model is told when filing is due.
ns_gate_filing_message() {
  local rel=.pending-filing
  [ -z "${1:-}" ] || ns_layout_rel_set rel "$1" pending-filing
  printf '%s' "DO NOT STOP YET — this shift has ended and archive.automatic is on, so file it before the session terminates. Run Archive now: decide from the punch list and the records which belong to work that is finished with, file those, and delete .nightshift/$rel when it is done. Stopping again releases the session whether or not filing succeeded, and an unfiled marker is picked up by the next explicit Archive."
}

# What the shift cost, written where the item's section is, at the moment the item is ticked.
#
# Marks are the boundaries: a tick, a change of the item being worked, a shift ending with an item
# open. Everything spent between two marks belongs to the item the second one names, so an item
# set aside and picked up again is charged for each stretch it was worked, and nothing it did not
# do. The model writes none of this and is told not to: on no host can it see its own usage from
# inside the conversation.
#
# The tick closes the item's last session; the receipt's runtime section, Tokens and Time totals
# included, is redrawn from every session it holds (ns_receipt_add_session).
#
# ns_gate_usage_tick <nightshift-dir> <project-dir> <item-label>
ns_gate_usage_tick() {
  local ns="$1" project="$2" label="$3" receipt
  [ -d "$ns" ] || return 0
  ns_receipts_enabled "$project" || return 0
  ns_usage_mark "$ns" "$label" tick || return 0
  receipt="$(ns_receipt_path "$project" "$label")"
  # A stopped item, closed at its hard budget, ends its span as stopped: never as ticked.
  if ns_item_rows "$(ns_layout_path "$ns" punch-list)" stopped | cut -f1 | grep -qxF -- "$label"; then
    ns_gate_session_row "$ns" "$project" "$label" stopped
  else
    ns_gate_session_row "$ns" "$project" "$label" ticked
  fi
  ns_budget_forget "$ns" "$label"
  ns_receipt_track_label "$receipt" "$label"
  ns_filemap_tick "$ns" "$project" "$label" || :
  ns_architecture_tick "$ns" "$project" "$label" || :
  ns_evidence_record "$ns" "$project" "$label" || :
  rm -f "$(ns_layout_path "$ns" receipt-due)" "$(ns_layout_path "$ns" report-due)" 2>/dev/null || :
  ns_receipts_write_index "$project"
}

# ns_gate_session_row <nightshift-dir> <project-dir> <item-label> <ended> — the span the last mark
# just closed, recorded as one session in the item's receipt.
#
# Beside the seven positional fields the row carries every token dimension, the recorded pause and
# its reason, the hosts and models whose readings moved in the span, the commits the work target
# took inside it, and the progress note the receipt held when it closed. A row whose host differs
# from the row before it is a handoff, and the shift log records what the outgoing session did.
ns_gate_session_row() {
  local ns="$1" project="$2" label="$3" ended="$4" span start end fields paused work in out sid
  local marks two hosts dim v extras="" paused_sec why receipt prev target commits note generation
  local earlier later nr turn host source
  span="$(ns_usage_last_item "$ns")" || return 0
  fields="$(printf '%s' "$span" | cut -f1)"
  marks="$(ns_usage_dir "$ns")/marks.tsv"
  two="$(tail -n2 "$marks")"
  earlier="$(printf '%s\n' "$two" | head -n1 | cut -f5)"
  later="$(printf '%s\n' "$two" | tail -n1 | cut -f5)"
  hosts="$(ns_usage_span_hosts "$earlier" "$later")"
  source="$hosts"
  if [ -z "$hosts" ] && ns_session_present "$ns"; then
    host="$(ns_session_host "$ns")"
    source="$(ns_usage_bound_source "$ns" "$host")"
    hosts="${source:-$host/-}"
    [ -n "$source" ] || fields=""
  fi
  # Cursor's readings are attributed by turn. The other hosts contribute only their own figures.
  if [ -n "$earlier$later" ] && { [ -n "$source" ] || [ -z "$hosts" ]; }; then
    fields="$(ns_usage_span_fields "$earlier" "$later" cursor "$source")"
  fi
  end="$(tail -n1 "$marks" | cut -f1)"
  case "$end" in '' | *[!0-9]*) return 0 ;; esac
  start=$((end - $(printf '%s' "$span" | cut -f2)))
  paused="$(ns_usage_paused_between "$ns" "$start" "$end")" || paused=0
  paused_sec="${paused%%$'\t'*}"
  why=""
  case "$paused" in *$'\t'*) why="${paused#*$'\t'}" ;; esac
  work=$((end - start - paused_sec))
  [ "$work" -ge 0 ] || work=0
  if [ "$(ns_receipts "$project" duration)" = off ]; then
    work=off
    paused_sec=off
  fi
  if [ "$(ns_receipts "$project" usage)" = off ]; then
    in=off
    out=off
    extras="cw=off cr=off rea=off"
  else
    in="$(ns_usage_field "$fields" input)" || in=-
    out="$(ns_usage_field "$fields" output)" || out=-
    for dim in cache_write:cw cache_read:cr reasoning:rea; do
      v="$(ns_usage_field "$fields" "${dim%%:*}")" || v=-
      extras="$extras${extras:+ }${dim#*:}=${v:--}"
    done
  fi
  extras="$extras paused=$paused_sec"
  [ -z "$why" ] || extras="$extras why=$(ns_receipt_encode "$why")"
  if [ -z "$hosts" ]; then
    hosts="$(ns_usage_hosts "$ns" 2>/dev/null | sed 's/; /+/g; s/ /\//g')" || hosts=""
  fi
  [ -z "$hosts" ] || extras="$extras host=$hosts"
  commits=""
  if [ "$(ns_work_mode "$project" 2>/dev/null)" = repository ] &&
    target="$(ns_work_target "$project" 2>/dev/null)" && [ -n "$target" ]; then
    commits="$(git -C "$target" log --since="@$start" --until="@$end" --format=%h 2>/dev/null | awk 'NF { printf "%s%s", s, $0; s = "," }')"
  fi
  [ -z "$commits" ] || extras="$extras commits=$commits"
  receipt="$(ns_receipt_path "$project" "$label")"
  note="$(ns_receipt_progress_note "$receipt")" || note=""
  [ -z "$note" ] || extras="$extras note=$(ns_receipt_encode "$note")"
  for v in soft hard; do
    if dim="$(ns_budget_reached "$ns" "$label" "$v")"; then
      extras="$extras $v=$dim"
      [ "${extras#* limit=}" != "$extras" ] ||
        extras="$extras limit=$(ns_receipt_encode "$(ns_budget_text "$project" "$label")")"
    fi
  done
  prev="$(ns_receipt_last_session "$receipt")" || prev=""
  sid="$(ns_policy_shift_id "$project" 2>/dev/null)" || sid=""
  generation="$(ns_usage_generation "$ns" "$sid")"
  nr="$(awk 'END { print NR }' "$marks")"
  extras="$extras checkpoint=$generation:$nr"
  if [ "$(ns_receipts "$project" usage)" != off ]; then
    ns_usage_turn_resolve "$ns" "$label" "$nr" || :
    while IFS= read -r turn; do
      [ -z "$turn" ] || extras="$extras turn=$turn"
    done < <(ns_usage_turns_for "$ns" "$label" "$nr")
  fi
  local park_keys snag_keys park_n snag_n
  park_keys="$(mktemp)"
  snag_keys="$(mktemp)"
  _ns_inbox_unseen_keys "$ns" parking-lot >"$park_keys" || :
  _ns_inbox_unseen_keys "$ns" snag-log >"$snag_keys" || :
  park_n="$(grep -c . "$park_keys" 2>/dev/null || true)"
  snag_n="$(grep -c . "$snag_keys" 2>/dev/null || true)"
  [ "${park_n:-0}" -gt 0 ] && extras="$extras parked=$park_n"
  [ "${snag_n:-0}" -gt 0 ] && extras="$extras snags=$snag_n"
  if ns_receipt_add_session "$receipt" "$label" "${sid:--}" \
    "$start" "$end" "$work" "${in:--}" "${out:--}" "$ended" "$extras"; then
    _ns_inbox_remember "$ns" parking-lot "$park_keys" || :
    _ns_inbox_remember "$ns" snag-log "$snag_keys" || :
  fi
  rm -f "$park_keys" "$snag_keys"
  ns_gate_handoff_log "$ns" "$label" "$prev" "$hosts"
}

# ns_gate_handoff_log <nightshift-dir> <item-label> <previous-session-line> <hosts> — when the
# session that just closed ran on another host or model than the one before it, record the handoff
# and what the outgoing session left: its commits and its last progress note.
ns_gate_handoff_log() {
  local ns="$1" label="$2" prev="$3" hosts="$4" was commits note line
  [ -n "$prev" ] && [ -n "$hosts" ] || return 0
  was="$(ns_session_extra "$prev" host)"
  [ -n "$was" ] && [ "$was" != "$hosts" ] || return 0
  commits="$(ns_session_extra "$prev" commits)"
  note="$(ns_receipt_decode "$(ns_session_extra "$prev" note)")"
  line="handoff · $label · $(ns_session_host_words "$was") → $(ns_session_host_words "$hosts")"
  line="$line · outgoing commits: $(printf '%s' "${commits:-none}" | sed 's/,/, /g')"
  [ -z "$note" ] || line="$line · last note: $note"
  ns_shift_log "$ns" "$line"
}

# ns_gate_item_is_open <punch-list> <item-label> — status 0 when that item is still an open box.
ns_gate_item_is_open() {
  ns_item_rows "$1" open | cut -f1 | grep -qxF -- "$2"
}

# ns_gate_session_end <nightshift-dir> <item-label> — how a session that is not a tick ended: blocked
# when the parking lot records the item as stalled, switched away otherwise.
ns_gate_session_end() {
  local lot
  ns_layout_set lot "$1" parking-lot
  if [ -f "$lot" ] && grep -F -- "$2" "$lot" 2>/dev/null | grep -qi 'stalled'; then
    printf 'blocked'
  else
    printf 'switched-away'
  fi
}

# ns_gate_usage_accounting <nightshift-dir> <project-dir> — status 0 when an armed shift with the
# receipts on is keeping marks, which is when the item being worked is followed. Marks are taken
# whatever the usage and duration settings say; those decide only what a receipt shows.
ns_gate_usage_accounting() {
  [ -d "$1" ] && [ -f "$(ns_layout_path "$1" armed)" ] || return 1
  ns_receipts_enabled "$2" || return 1
  [ -s "$(ns_usage_dir "$1")/marks.tsv" ]
}

# ns_gate_usage_switch <nightshift-dir> <project-dir> <active-label> — follow the item being worked.
# When it changes, the span so far closes on the item that was being worked, which gets a session,
# and the running span is charged to the new one from here.
ns_gate_usage_switch() {
  local ns="$1" project="$2" active="$3" owner
  [ -n "$active" ] || return 0
  # The pulse runs this on every tool call, so the common case, the same item still being worked,
  # is decided before anything reads the policy.
  owner="$(ns_usage_active "$ns")"
  [ "$owner" != "$active" ] || return 0
  ns_gate_usage_accounting "$ns" "$project" || return 0
  if [ -n "$owner" ] && ns_gate_item_is_open "$(ns_layout_path "$ns" punch-list)" "$owner"; then
    ns_usage_mark "$ns" "$owner" switch || return 0
    ns_gate_session_row "$ns" "$project" "$owner" "$(ns_gate_session_end "$ns" "$owner")"
  fi
  ns_usage_set_active "$ns" "$active"
}

# ns_gate_usage_flush <nightshift-dir> <project-dir> [epoch] — a shift ending with an item open closes that
# item's session as paused. The next shift continues the same receipt.
ns_gate_usage_flush() {
  local ns="$1" project="$2" at="${3:-}" owner
  ns_gate_usage_accounting "$ns" "$project" || return 0
  owner="$(ns_usage_active "$ns")"
  [ -n "$owner" ] || return 0
  if ns_gate_item_is_open "$(ns_layout_path "$ns" punch-list)" "$owner"; then
    ns_usage_mark "$ns" "$owner" pause "$at" || return 1
    ns_gate_session_row "$ns" "$project" "$owner" paused
  fi
  ns_usage_set_active "$ns"
}

# A continued ledger keeps its checkpoints. Each Start gives the new work its own baseline and
# selects the first open box. Only a receipt written during this run can move that selection.
ns_gate_usage_start() { # <nightshift-dir> <project-dir> <punch-list> [prior-end]
  local ns="$1" project="$2" list="$3" prior_end="${4:-}" ref marks last first
  ns_receipts_enabled "$project" || return 0
  first="$(ns_item_rows "$list" open | awk -F '\t' 'NR == 1 { print $1 }')"
  [ -n "$first" ] || return 0
  ref="$(ns_usage_start_ref "$ns")"
  [ ! -L "$ref" ] || return 1
  mkdir -p "${ref%/*}" || return 1
  marks="$(_ns_usage_marks "$ns")"
  [ ! -L "$marks" ] || return 1
  if [ -s "$marks" ]; then
    last="$(tail -n1 "$marks" | cut -f1)"
    # A Stop from an older runtime can leave an open span. Close it at the recorded pause.
    if [ -n "$prior_end" ] && [ "$last" -lt "$prior_end" ] 2>/dev/null; then
      ns_gate_usage_flush "$ns" "$project" "$prior_end" || return 1
    fi
    ns_gate_uncharged_labels "$ns" "$list" observe >/dev/null || return 1
    ns_usage_mark "$ns" '' resume || return 1
  fi
  : >"$ref" || return 1
  ns_usage_set_active "$ns" "$first"
}

# ns_gate_usage_sync <nightshift-dir> <project-dir> <punch-list> <ticked> — catch the marks up to
# the boxes.
#
# The gate does not see a tick happen; it sees which boxes are ticked when a stop is attempted.
# Each completion gets one mark. An observed open box supersedes its earlier completion, so its
# next tick closes a new span. A second stop attempt with nothing newly ticked adds nothing.
ns_gate_usage_sync() {
  local ns="$1" project="$2" list="$3" ticked="$4" marked labels label owner
  [ -d "$ns" ] || return 0
  [ -f "$list" ] || return 0
  # Accounting belongs to an armed shift with the report on. Before Start there is no shift to bill,
  # and an arm mark written then would stand in the way of the baseline the real arming records.
  [ -f "$(ns_layout_path "$ns" armed)" ] || return 0
  ns_receipts_enabled "$project" || return 0
  case "$ticked" in '' | *[!0-9]*) return 0 ;; esac
  # The arm mark is the shift's own start, and is not an item. When no pulse has written it yet,
  # arm here with whatever transcripts the caller has, so reading begins where they stand now.
  marked="$(ns_usage_mark_count "$ns")"
  case "$marked" in '' | *[!0-9]*) marked=0 ;; esac
  if [ "$marked" -eq 0 ]; then
    shift 4
    ns_usage_mark_arm "$ns" "$@"
  fi
  labels="$(ns_gate_uncharged_labels "$ns" "$list" observe)" || return 1
  [ -n "$labels" ] || return 0
  # The span running now belongs to the item being worked. When that item is among the newly
  # ticked it closes first; when it is still open it closes as a switch, so a box ticked for work
  # done earlier is not charged for the work in hand.
  owner="$(ns_usage_active "$ns")"
  if [ -n "$owner" ]; then
    if printf '%s\n' "$labels" | grep -qxF -- "$owner"; then
      labels="$(printf '%s\n' "$owner"; printf '%s\n' "$labels" | awk -v o="$owner" '$0 != o || seen++')"
    elif ns_gate_item_is_open "$list" "$owner"; then
      ns_usage_mark "$ns" "$owner" switch &&
        ns_gate_session_row "$ns" "$project" "$owner" "$(ns_gate_session_end "$ns" "$owner")"
    fi
  fi
  while IFS= read -r label; do
    ns_gate_usage_tick "$ns" "$project" "$label" </dev/null || return 0
  done <<<"$labels"
  ns_usage_set_active "$ns"
}

# ns_gate_uncharged_labels <nightshift-dir> <punch-list> [observe] — closed items that still need
# a mark, in list order. Observing an open box records how many of its marks belong to earlier
# completions. The counts are cumulative so every later hook can ignore just those marks.
ns_gate_uncharged_labels() {
  local dir marks reopened observed=""
  dir="$(ns_usage_dir "$1")"
  marks="$dir/marks.tsv"
  reopened="$dir/reopened.tsv"
  [ -f "$marks" ] && [ ! -L "$marks" ] || marks=/dev/null
  if [ "${3:-}" = observe ]; then
    [ ! -L "$reopened" ] || return 1
    observed="$reopened"
  fi
  [ -f "$reopened" ] && [ ! -L "$reopened" ] || reopened=/dev/null
  {
    ns_item_rows "$2" open | cut -f1 | sed 's/^/+/'
    ns_gate_ticked_labels "$2" | sed 's/^/-/'
  } | awk -v marks="$marks" -v reopened="$reopened" -v observed="$observed" '
    BEGIN {
      while ((getline row < reopened) > 0) {
        if (split(row, f, "\t") == 2 && f[1] ~ /^[0-9]+$/) ignored[f[2]] = f[1] + 0
      }
      close(reopened)
      while ((getline row < marks) > 0) {
        rows++
        n = split(row, f, "\t")
        # The first mark is the shift arming, not an item, and only a tick closes an item: a switch
        # or a pause charges a span to an item that is still open.
        if (rows == 1 && f[2] == "arm") continue
        if (n >= 4 && f[4] != "" && f[4] != "tick") continue
        charged[f[2]]++
      }
      close(marks)
    }
    /^\+/ { open[substr($0, 2)] = 1; next }
    { label = substr($0, 2); labels[++nlabels] = label; closed[label]++ }
    END {
      if (observed != "") {
        for (label in open) {
          count = charged[label] - closed[label]
          if (count <= ignored[label]) continue
          ignored[label] = count
          print count "\t" label >> observed
        }
      }
      for (i = 1; i <= nlabels; i++) {
        label = labels[i]
        if (charged[label] > ignored[label]) charged[label]--
        else print label
      }
    }
  '
}

# ns_gate_ticked_labels <punch-list> — every closed item's id, list order, one per line, as the
# report heads its section. `- [x] **P03 — …**` gives `P03`. A capital `[X]` is a tick here as it
# is in the counts, and a stopped item (`- [-]`, closed at its hard budget) closes its span too.
# An item whose id cannot be read is `item <n>`, n its place among the closed.
ns_gate_ticked_labels() {
  ns_items_section "$1" 2>/dev/null | awk "$NS_AWK_ITEM"'
    /^- \[[xX-]\]/ {
      n++
      line = ns_item_label($0)
      if (line == "") line = "item " n
      print line
    }
  '
}

# Which form the block takes: the whole contract, or one line saying nothing has changed.
#
# The push never changes. Every turn that ends with open boxes is still blocked, with a reason the
# host feeds back into the conversation. What changes is the repetition: a model ends turns to
# narrate — "gate green, committing" — many times per item, and each block was re-injecting a
# message it had read a few calls earlier. One shift here took 106 blocks in four hours across
# eleven items.
#
# The gate already knows everything needed to tell "something moved" from "nothing did": the open
# and ticked counts, which item is open, whether a stop-work order exists, the deadline state, the
# stall counter and the list itself. It writes that down after each block and compares on the
# next, so a list the owner changed is always answered with the whole reminder.
#
# Unknown always means the full text. A missing, empty or malformed comparison file, a context
# reset, the first block of a shift, and too many short lines in a row all send the whole thing.
# No branch here may produce an empty reason or no block at all.

# ns_gate_reminder_fingerprint <open> <ticked> <item> <stopped> <deadline> <stall> <list>
ns_gate_reminder_fingerprint() {
  printf 'open=%s ticked=%s item=%s stopped=%s deadline=%s stall=%s list=%s' \
    "${1:-?}" "${2:-?}" "${3:-?}" "${4:-?}" "${5:-?}" "${6:-?}" "${7:-?}"
}

# ns_gate_list_fingerprint <punch-list> — one digest of the contract and every item, ticks aside.
ns_gate_list_fingerprint() {
  ns_punch_list_view "$1" 2>/dev/null | ns_punch_digest
}

# ns_gate_stall_state <stall-file> <warn-every> — `warned` once the stall guard has begun saying
# so, `quiet` before that.
#
# Deliberately not the raw attempt count. That count rises on every stop attempt without progress,
# which is the very repetition this shortens, so a fingerprint carrying it could never compare
# equal twice and the short line would never be sent at all. Crossing into warning is a real
# change and sends the whole contract; counting narration turns is not.
ns_gate_stall_state() {
  local n warn
  if ! { [ -f "$1" ] && [ ! -L "$1" ]; }; then printf 'quiet'; return 0; fi
  n="$(sed -n 2p "$1" 2>/dev/null | tr -d '[:space:]')"
  case "$n" in '' | *[!0-9]*) printf 'quiet'; return 0 ;; esac
  warn="$2"
  case "$warn" in '' | *[!0-9]* | 0) printf 'quiet'; return 0 ;; esac
  if [ "$n" -ge "$warn" ]; then printf 'warned'; else printf 'quiet'; fi
}

# ns_gate_reminder_text <project-dir> <full-text> <open> <ticked> <item> <fingerprint>
#
# Prints the reason this block should carry. The full owner text unless the gate positively knows
# nothing has changed since the last block, in which case the owner's short line with the item and
# counts put in.
# ns_gate_receipts_missing_note <project> — "Receipts missing model text: NN, NN" or empty.
ns_gate_receipts_missing_note() {
  local list
  list="$(ns_receipts_missing_nns "$1" | awk 'NF { if (n++) printf ", "; printf "%s", $0 }')" || list=""
  [ -n "$list" ] || return 0
  printf 'Receipts missing model text: %s' "$list"
}

ns_gate_receipts_missing_append() {
  local note
  note="$(ns_gate_receipts_missing_note "$1")"
  if [ -n "$note" ]; then
    printf '%s %s' "$2" "$note"
  else
    printf '%s' "$2"
  fi
}

ns_gate_reminder_text() {
  local project="$1" full="$2" open="$3" ticked="$4" item="$5" fp="$6"
  local ns="$1/.nightshift" mode file previous count limit short text
  text="$(ns_gate_reminder_text_body "$project" "$full" "$open" "$ticked" "$item" "$fp")"
  ns_gate_receipts_missing_append "$project" "$text"
}

ns_gate_reminder_text_body() {
  local project="$1" full="$2" open="$3" ticked="$4" item="$5" fp="$6"
  local ns="$1/.nightshift" mode file reset previous count limit short
  mode="$(rule "$project" clockOutReminderMode "${NIGHTSHIFT_CLOCKOUT_REMINDER_MODE:-}")"
  case "$mode" in
    changed-only) ;;
    # `full` is the shipped default, and so is anything unreadable: a mode nobody can parse is not
    # a licence to say less.
    *)
      ns_gate_reminder_remember "$ns" "$fp" 0
      printf '%s' "$full"
      return 0
      ;;
  esac
  ns_layout_set file "$ns" clock-out-reminder
  ns_layout_set reset "$ns" context-reset
  # A context reset means the conversation no longer holds what it was told. Consume the marker
  # and send everything.
  if [ -f "$reset" ] || [ -L "$reset" ]; then
    rm -f "$reset" 2>/dev/null || :
    ns_gate_reminder_remember "$ns" "$fp" 0
    printf '%s' "$full"
    return 0
  fi
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -s "$file" ]; then
    ns_gate_reminder_remember "$ns" "$fp" 0
    printf '%s' "$full"
    return 0
  fi
  previous="$(sed -n 1p "$file" 2>/dev/null)"
  count="$(sed -n 2p "$file" 2>/dev/null | tr -d '[:space:]')"
  case "$count" in '' | *[!0-9]*) count="" ;; esac
  if [ -z "$previous" ] || [ -z "$count" ] || [ "$previous" != "$fp" ]; then
    ns_gate_reminder_remember "$ns" "$fp" 0
    printf '%s' "$full"
    return 0
  fi
  limit="$(rule "$project" clockOutReminderLimit "${NIGHTSHIFT_CLOCKOUT_REMINDER_LIMIT:-}")"
  case "$limit" in '' | *[!0-9]* | 0) limit=10 ;; esac
  if [ "$count" -ge "$limit" ]; then
    ns_gate_reminder_remember "$ns" "$fp" 0
    printf '%s' "$full"
    return 0
  fi
  short="$(rule "$project" clockOutReminder "${NIGHTSHIFT_CLOCKOUT_REMINDER:-}")"
  if [ -z "$short" ]; then
    ns_gate_reminder_remember "$ns" "$fp" 0
    printf '%s' "$full"
    return 0
  fi
  ns_gate_reminder_remember "$ns" "$fp" "$((count + 1))"
  ns_gate_reminder_fill "$short" "$item" "$open" "$ticked"
}

# ns_gate_reminder_remember <nightshift-dir> <fingerprint> <count>
ns_gate_reminder_remember() {
  local file
  [ -d "$1" ] || return 0
  ns_layout_set file "$1" clock-out-reminder
  [ -L "$file" ] && rm -f "$file"
  printf '%s\n%s\n' "$2" "$3" >"$file" 2>/dev/null || :
}

# ns_gate_reminder_fill <short> <item> <open> <ticked> — the owner's own wording with the facts
# put in. Substitution is by name, so an owner who drops one keeps their own sentence, and
# {total} is offered because "4 of 7 remain" reads better than making them add.
ns_gate_reminder_fill() {
  local out="$1" total=$(( ${3:-0} + ${4:-0} ))
  out="${out//\{item\}/$2}"
  out="${out//\{open\}/$3}"
  out="${out//\{ticked\}/$4}"
  out="${out//\{total\}/$total}"
  printf '%s' "$out"
}

# ns_gate_open_item <punch-list> — the id of the first still-open item, for the short line.
ns_gate_open_item() {
  ns_items_section "$1" 2>/dev/null | awk "$NS_AWK_ITEM"'
    /^- \[ \]/ { print ns_item_label($0); exit }
  '
}

# The one terminal sequence. Every host gate and the Cursor watchman end a shift here:
# .ended, disarm, lease release, morning receipt, policy and findings archive, receipts commit.
# Later steps log and continue. The release stands once .ended is a real file and the armed
# marker is gone. Returns 1 when that marker cannot be written. Does not hold the session.

render_morning_receipt() { # <shift-id>
  local project="$NS_SHIFT_END_PROJECT" ns="$NS_SHIFT_END_NS"
  local renderer="$_ns_gate_core_dir/../../runtime/morning-receipt.sh" dir err out
  ns_layout_set dir "$ns" receipts
  if [ ! -f "$renderer" ]; then
    ns_shift_log "$ns" "morning receipt skipped: runtime/morning-receipt.sh is not installed"
    return 0
  fi
  if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
    ns_shift_log "$ns" "morning receipt render failed: receipts path is not a directory"
    return 0
  fi
  mkdir -p "$dir" 2>/dev/null || {
    ns_shift_log "$ns" "morning receipt render failed: cannot create $dir"
    return 0
  }
  out="$dir/morning-$(date '+%Y-%m-%d')${1:+-$1}.md"
  if [ -e "$out" ] || [ -L "$out" ]; then
    ns_shift_log "$ns" "morning receipt kept: $out already exists for this shift"
    return 0
  fi
  if err="$(bash "$renderer" --project "$project" --out "$out" 2>&1)"; then
    if ns_receipts_enabled "$project"; then ns_receipts_write_index "$project"; fi
    return 0
  fi
  ns_shift_log "$ns" "morning receipt render failed: $(printf '%s' "$err" | head -n1)"
}

archive_shift_policy() {
  local project="$NS_SHIFT_END_PROJECT" ns="$NS_SHIFT_END_NS" policy err
  ns_layout_set policy "$ns" shift-policy
  [ -f "$policy" ] && [ ! -L "$policy" ] || return 0
  err="$(bash "$_ns_gate_core_dir/../../runtime/shift-policy.sh" --project "$project" archive 2>&1)" && return 0
  ns_shift_log "$ns" "shift policy archive failed: $(printf '%s' "$err" | head -n1)"
}

archive_findings_ledger() { # <shift-id>
  local project="$NS_SHIFT_END_PROJECT" ns="$NS_SHIFT_END_NS"
  local archiver="$_ns_gate_core_dir/../../runtime/evidence-archive.sh" err
  [ -f "$archiver" ] || {
    ns_shift_log "$ns" "findings archive skipped: runtime/evidence-archive.sh is not installed"
    return 0
  }
  err="$(bash "$archiver" --project "$project" --shift-id "$1" 2>&1)" && return 0
  ns_shift_log "$ns" "findings archive failed: $(printf '%s' "$err" | head -n1)"
}

receipts_commit() { # <summary>
  local project="$NS_SHIFT_END_PROJECT" ns="$NS_SHIFT_END_NS" err auto repo
  ns_layout_set repo "$ns" receipts-repo
  [ -d "$repo" ] || return 0
  auto="$(rule "$project" receiptsAutoCommit "${NIGHTSHIFT_RECEIPTS_AUTO_COMMIT:-}")"
  case "$auto" in true | TRUE | 1 | yes | YES) ;; *) return 0 ;; esac
  git -C "$ns" add -A >/dev/null 2>&1 || true
  err="$(git -C "$ns" -c user.name=nightshift -c user.email=nightshift@localhost \
    -c commit.gpgsign=false commit -q -m "$1" 2>&1)" && return 0
  case "$err" in
    *"nothing to commit"* | *"nothing added"*) : ;;
    *) ns_shift_log "$ns" "receipts commit failed: $(printf '%s' "$err" | head -n1)" ;;
  esac
}

ns_shift_whistle() { # <summary>
  local project="$NS_SHIFT_END_PROJECT" ns="$NS_SHIFT_END_NS" notify notified rc=0
  notify="$(rule "$project" notifyCommand "${NIGHTSHIFT_NOTIFY_CMD:-}")"
  [ -n "$notify" ] || return 0
  ns_layout_set notified "$ns" notified
  [ -L "$notified" ] && rm -f "$notified"
  (set -C; : >"$notified") 2>/dev/null || return 0
  # The command's output stays discarded, since it may carry a token; its status is the record.
  NIGHTSHIFT_SUMMARY="$1" sh -c "$notify" nightshift "$1" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || ns_shift_log "$ns" "whistle: notifyCommand exited $rc"
}

# ns_shift_end <project-dir> <summary>
ns_shift_end() {
  local project="$1" summary="${2:-}"
  local ns ended armed shift_id pending
  [ -n "$project" ] && [ -d "$project" ] || return 1
  ns="${project%/}/.nightshift"
  [ -d "$ns" ] || return 1
  NS_SHIFT_END_PROJECT="$project"
  NS_SHIFT_END_NS="$ns"
  ns_layout_set ended "$ns" ended
  ns_layout_set armed "$ns" armed
  if [ -L "$ended" ]; then rm -f "$ended"; fi
  if ! : >"$ended" 2>/dev/null; then
    ns_shift_log "$ns" "clock-out refused: cannot write $(ns_layout_name "$ns" ended)"
    return 1
  fi
  ns_gate_usage_flush "$ns" "$project"
  rm -f "$armed"
  ns_lease_release_retry "$ns" \
    || ns_shift_log "$ns" "process lease release deferred: lease mutex remained busy"
  shift_id="$(ns_policy_shift_id "$project" 2>/dev/null)" || shift_id=""
  if ns_handoff_enabled "$project"; then
    render_morning_receipt "$shift_id"
  else
    ns_shift_log "$ns" "morning receipt disabled by the owner (handoff.enabled) - every record stands"
  fi
  ns_gate_record_ending "$ns" "$project" "${shift_id:-unknown}"
  archive_shift_policy
  archive_findings_ledger "${shift_id:-unknown}"
  receipts_commit "$summary"
  ns_layout_set pending "$ns" pending-filing
  if [ -f "$pending" ]; then
    ns_shift_log "$ns" "archive.automatic is on - filing is due for this shift"
  fi
  ns_shift_whistle "$summary"
  [ -f "$ended" ] && [ ! -L "$ended" ] && [ ! -e "$armed" ]
}

# Stall progress is a tick plus either work-target HEAD (repository mode) or the artifact
# receipts fingerprint (artifact mode). ns_gate_progress_token chooses.
deadline_passed() { ns_gate_deadline_passed; }

# The terminal sequence lives once, in gate-core.sh. The watchman calls the same function.
end_shift() { ns_shift_end "$PROJECT_DIR" "$1"; }

honor_stop() {
  local reason
  reason="$(head -n1 "$STOP" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  end_and_stop "shift ended${reason:+ ($reason)}: $TICKED/$TOTAL done"
}
