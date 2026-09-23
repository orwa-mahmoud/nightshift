#!/usr/bin/env bash
# Shared clock-out decisions. Host wrappers own payload parsing and response emission.

# ns_gate_boxes — set OPEN, TICKED, TOTAL from the punch list. Return 1 when
# the file exists but cannot be read; then the counts are not a verdict and
# the caller must not release as "0 open".
# shellcheck disable=SC2034 # host wrappers read TOTAL after ns_gate_boxes
ns_gate_boxes() {
  OPEN=0
  TICKED=0
  TOTAL=0
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
  local ns="$1" project="$2" id="${3:-unknown}"
  ns_ended_record "$ns" "$id" \
    "$(ns_archive "$project" root)" "$(ns_archive "$project" layout)"
  [ -d "$ns" ] || return 0
  ns_archive_automatic "$project" || return 0
  [ -L "$ns/.pending-filing" ] && rm -f "$ns/.pending-filing"
  printf 'date=%s\nshiftId=%s\n' "$(date +%Y-%m-%d)" "$id" >"$ns/.pending-filing" 2>/dev/null || :
}

# ns_gate_filing_due <nightshift-dir> — status 0 when the model still owes this ended shift its
# filing and has not been asked yet. Asking is recorded, so the next stop releases either way: a
# session that could not file leaves the marker for the next explicit Archive rather than being
# held forever by a hook that cannot do the filing itself.
ns_gate_filing_due() {
  local ns="$1" pending="$1/.pending-filing"
  [ -f "$ns/.ended" ] && [ ! -L "$ns/.ended" ] || return 1
  [ ! -f "$ns/.shift-armed" ] || return 1
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  grep -q '^asked=1$' "$pending" 2>/dev/null && return 1
  printf 'asked=1\n' >>"$pending" 2>/dev/null || return 1
  return 0
}

# ns_gate_filing_message <nightshift-dir> — what the model is told when filing is due.
ns_gate_filing_message() {
  printf '%s' "DO NOT STOP YET — this shift has ended and archive.automatic is on, so file it before the session terminates. Run Archive now: decide from the punch list and the records which belong to work that is finished with, file those, and delete .nightshift/.pending-filing when it is done. Stopping again releases the session whether or not filing succeeded, and an unfiled marker is picked up by the next explicit Archive."
}

# What the shift cost, written where the item's section is, at the moment the item is ticked.
#
# Marks are the boundaries: a tick, a change of the item being worked, a shift ending with an item
# open. Everything spent between two marks belongs to the item the second one names, so an item
# set aside and picked up again is charged for each stretch it was worked, and nothing it did not
# do. The model writes none of this and is told not to: on no host can it see its own usage from
# inside the conversation.
#
# ns_gate_usage_tick <nightshift-dir> <project-dir> <item-label>
ns_gate_usage_tick() {
  local ns="$1" project="$2" label="$3" total fields seconds host line duration from to
  local paused_sec paused_why receipt
  [ -d "$ns" ] || return 0
  ns_report_enabled "$project" || return 0
  [ "$(ns_report "$project" usage)" != off ] || return 0
  ns_usage_mark "$ns" "$label" tick || return 0
  receipt="$(ns_receipt_path "$project" "$label")"
  ns_gate_session_row "$ns" "$project" "$label" ticked
  total="$(ns_usage_item_total "$ns" "$label")" || return 0
  fields="$(printf '%s' "$total" | cut -f1)"
  seconds="$(printf '%s' "$total" | cut -f2)"
  from="$(printf '%s' "$total" | cut -f3)"
  paused_sec="$(printf '%s' "$total" | cut -f4)"
  paused_why="$(printf '%s' "$total" | cut -f5)"
  host="$(ns_usage_hosts "$ns")" || host="unknown"
  if [ -n "$fields" ]; then
    line="$(ns_usage_line "$fields" "$host" "$(ns_usage_segments "$ns")" "$(printf '%s' "$host" | cut -d' ' -f1)")"
    # Working time first. Wall and any recorded gap stay beside it so the figure can be checked.
    to="$(date +%s)"
    duration="$(ns_usage_duration_line "$seconds" "$paused_sec" "$paused_why" "$from" "$to")"
    ns_gate_usage_append "$receipt" "$label" "$line" "$duration"
  fi
  ns_receipt_track_label "$receipt" "$label"
  rm -f "$ns/.receipt-due" "$ns/.report-due" 2>/dev/null || :
  ns_receipts_write_index "$project"
}

# ns_gate_session_row <nightshift-dir> <project-dir> <item-label> <ended> — the span the last mark
# just closed, recorded as one session in the item's receipt.
ns_gate_session_row() {
  local ns="$1" project="$2" label="$3" ended="$4" span start end fields paused work in out sid
  span="$(ns_usage_last_item "$ns")" || return 0
  fields="$(printf '%s' "$span" | cut -f1)"
  end="$(tail -n1 "$(ns_usage_dir "$ns")/marks.tsv" | cut -f1)"
  case "$end" in '' | *[!0-9]*) return 0 ;; esac
  start=$((end - $(printf '%s' "$span" | cut -f2)))
  paused="$(ns_usage_paused_between "$ns" "$start" "$end")" || paused=0
  work=$((end - start - ${paused%%$'\t'*}))
  [ "$work" -ge 0 ] || work=0
  in="$(ns_usage_field "$fields" input)" || in=-
  out="$(ns_usage_field "$fields" output)" || out=-
  sid="$(ns_policy_shift_id "$project" 2>/dev/null)" || sid=""
  ns_receipt_add_session "$(ns_receipt_path "$project" "$label")" "$label" "${sid:--}" \
    "$start" "$end" "$work" "${in:--}" "${out:--}" "$ended"
}

# ns_gate_item_is_open <punch-list> <item-label> — status 0 when that item is still an open box.
ns_gate_item_is_open() {
  ns_item_rows "$1" open | cut -f1 | grep -qxF -- "$2"
}

# ns_gate_session_end <nightshift-dir> <item-label> — how a session that is not a tick ended: blocked
# when the parking lot records the item as stalled, switched away otherwise.
ns_gate_session_end() {
  local lot="$1/parking-lot.md"
  if [ -f "$lot" ] && grep -F -- "$2" "$lot" 2>/dev/null | grep -qi 'stalled'; then
    printf 'blocked'
  else
    printf 'switched-away'
  fi
}

# ns_gate_usage_accounting <nightshift-dir> <project-dir> — status 0 when an armed shift with the
# receipts and usage on is keeping marks, which is when the item being worked is followed.
ns_gate_usage_accounting() {
  [ -d "$1" ] && [ -f "$1/.shift-armed" ] || return 1
  ns_report_enabled "$2" || return 1
  [ "$(ns_report "$2" usage)" != off ] || return 1
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
  if [ -n "$owner" ] && ns_gate_item_is_open "$ns/punch-list.md" "$owner"; then
    ns_usage_mark "$ns" "$owner" switch || return 0
    ns_gate_session_row "$ns" "$project" "$owner" "$(ns_gate_session_end "$ns" "$owner")"
  fi
  ns_usage_set_active "$ns" "$active"
}

# ns_gate_usage_flush <nightshift-dir> <project-dir> — a shift ending with an item open closes that
# item's session as paused. The next shift continues the same receipt.
ns_gate_usage_flush() {
  local ns="$1" project="$2" owner
  ns_gate_usage_accounting "$ns" "$project" || return 0
  owner="$(ns_usage_active "$ns")"
  [ -n "$owner" ] || return 0
  if ns_gate_item_is_open "$ns/punch-list.md" "$owner"; then
    ns_usage_mark "$ns" "$owner" pause || return 0
    ns_gate_session_row "$ns" "$project" "$owner" paused
  fi
  ns_usage_set_active "$ns"
}

# ns_gate_usage_append <receipt> <item-label> <usage-line> <duration> — write the runtime
# block at the top of the item's receipt, under the heading. If the model has not written
# the file yet, it is created with a `# <NN. title>` heading. The measurement does not wait
# on the narrative.
ns_gate_usage_append() {
  local receipt="$1" label="$2" usage="$3" duration="$4" dir tmp block
  [ -n "$receipt" ] || return 0
  [ ! -L "$receipt" ] || return 0
  dir="${receipt%/*}"
  mkdir -p "$dir" 2>/dev/null || return 0
  block="$(printf '%s\n\n%s\n' "$usage" "$duration")"
  if [ ! -f "$receipt" ]; then
    printf '# %s\n\n%s' "$label" "$block" >"$receipt" 2>/dev/null || return 0
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/ns-receipt-usage.XXXXXX")" || return 0
  printf '%s' "$block" >"$tmp.block" || { rm -f "$tmp"; return 0; }
  awk -v blockfile="$tmp.block" '
    BEGIN {
      while ((getline l < blockfile) > 0) block = block l "\n"
      close(blockfile)
    }
    /^# / && !done {
      print
      print ""
      printf "%s", block
      print ""
      done = 1
      next
    }
    { print }
    END {
      if (!done) {
        print ""
        printf "%s", block
      }
    }
  ' "$receipt" >"$tmp" 2>/dev/null && mv "$tmp" "$receipt"
  rm -f "$tmp" "$tmp.block"
}

# ns_gate_usage_sync <nightshift-dir> <project-dir> <punch-list> <ticked> — catch the marks up to
# the boxes.
#
# The gate does not see a tick happen; it sees which boxes are ticked when a stop is attempted.
# Every mark names the item it charged, so it closes each ticked item no mark names yet, in list
# order. One mark per item, written once: a second stop attempt with nothing newly ticked adds
# nothing, and an item ticked out of list order is charged to itself.
ns_gate_usage_sync() {
  local ns="$1" project="$2" list="$3" ticked="$4" marked labels label owner
  [ -d "$ns" ] || return 0
  [ -f "$list" ] || return 0
  # Accounting belongs to an armed shift with the report on. Before Start there is no shift to bill,
  # and an arm mark written then would stand in the way of the baseline the real arming records.
  [ -f "$ns/.shift-armed" ] || return 0
  ns_report_enabled "$project" || return 0
  case "$ticked" in '' | *[!0-9]*) return 0 ;; esac
  [ "$(ns_report "$project" usage)" != off ] || return 0
  # The arm mark is the shift's own start, and is not an item. When no pulse has written it yet,
  # arm here with whatever transcripts the caller has, so reading begins where they stand now.
  marked="$(ns_usage_mark_count "$ns")"
  case "$marked" in '' | *[!0-9]*) marked=0 ;; esac
  if [ "$marked" -eq 0 ]; then
    shift 4
    ns_usage_mark_arm "$ns" "$@"
  fi
  labels="$(ns_gate_uncharged_labels "$ns" "$list")"
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

# ns_gate_uncharged_labels <nightshift-dir> <punch-list> — the ticked items no mark names yet, list
# order, one per line. A label ticked twice under the same name is charged twice, once per mark.
ns_gate_uncharged_labels() {
  local marks
  marks="$(ns_usage_dir "$1")/marks.tsv"
  [ -f "$marks" ] && [ ! -L "$marks" ] || marks=/dev/null
  ns_gate_ticked_labels "$2" | awk -v marks="$marks" '
    BEGIN {
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
    charged[$0] > 0 { charged[$0]--; next }
    { print }
  '
}

# ns_gate_ticked_labels <punch-list> — every ticked item's id, list order, one per line, as the
# report heads its section. `- [x] **P03 — …**` gives `P03`. A capital `[X]` is a tick here as it
# is in the counts. An item whose id cannot be read is `item <n>`, n its place among the ticked.
ns_gate_ticked_labels() {
  ns_items_section "$1" 2>/dev/null | awk "$NS_AWK_ITEM"'
    /^- \[[xX]\]/ {
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
# stall counter. It writes that down after each block and compares on the next.
#
# Unknown always means the full text. A missing, empty or malformed comparison file, a context
# reset, the first block of a shift, and too many short lines in a row all send the whole thing.
# No branch here may produce an empty reason or no block at all.

# ns_gate_reminder_fingerprint <open> <ticked> <item> <stopped> <deadline> <stall>
ns_gate_reminder_fingerprint() {
  printf 'open=%s ticked=%s item=%s stopped=%s deadline=%s stall=%s' \
    "${1:-?}" "${2:-?}" "${3:-?}" "${4:-?}" "${5:-?}" "${6:-?}"
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
  local ns="$1/.nightshift" mode file previous count limit short
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
  file="$ns/.clock-out-reminder"
  # A context reset means the conversation no longer holds what it was told. Consume the marker
  # and send everything.
  if [ -f "$ns/.context-reset" ] || [ -L "$ns/.context-reset" ]; then
    rm -f "$ns/.context-reset" 2>/dev/null || :
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
  [ -d "$1" ] || return 0
  [ -L "$1/.clock-out-reminder" ] && rm -f "$1/.clock-out-reminder"
  printf '%s\n%s\n' "$2" "$3" >"$1/.clock-out-reminder" 2>/dev/null || :
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

# The contract, held to what it was when the shift armed.
#
# A file's own editor cannot police it, and restoring a punch list from git is the editor deciding
# what the contract said. The gate records digests at arming, so it checks rather than asking the
# model to notice.
#
# Two digests, because two things can move for different reasons. `contractDigest` covers
# everything above `## Items`: the shift contract, which nobody may edit while a shift runs.
# itemsDigest covers the items with the checkbox state flattened, so ticking a box is invisible
# to it and rewording, deleting or inserting an item is not. The `## Gates` block is deliberately
# outside both — the owner may change it mid-shift by design, and gatesDigest tracks it on its
# own terms.
#
# A mismatch blocks with the repair named. It never restores anything itself, never refuses to end
# a shift on a tick alone, and never treats a snapshot that predates these fields as a mismatch.
#
# ns_gate_contract_mismatch <project-dir> <punch-list> — the sentence to block with, or nothing.
ns_gate_contract_mismatch() {
  local project="$1" list="$2" recorded now which=""
  [ -f "$list" ] && [ ! -L "$list" ] || return 1

  recorded="$(ns_policy_shift_field "$project" contractDigest)" || recorded=""
  if [ -n "$recorded" ]; then
    now="$(ns_punch_contract_digest "$list")" || now=""
    [ -n "$now" ] && [ "$now" != "$recorded" ] && which="contract"
  fi
  if [ -z "$which" ]; then
    recorded="$(ns_policy_shift_field "$project" itemsDigest)" || recorded=""
    if [ -n "$recorded" ]; then
      now="$(ns_punch_items_digest "$list")" || now=""
      [ -n "$now" ] && [ "$now" != "$recorded" ] && which="items"
    fi
  fi
  [ -n "$which" ] || return 1

  if [ "$which" = contract ]; then
    printf 'DO NOT STOP — the shift contract above the Items heading in %s has changed since this shift armed. It is the agreement the night is working to, and it is not editable while a shift runs. Restore the punch list from the work-target history or the receipts, or end the shift and let the owner edit the contract with nothing armed. Nothing else about the shift has changed: your ticks stand.' "$list"
  else
    printf 'DO NOT STOP — an item in %s has been reworded, removed or inserted since this shift armed. Ticking a box is invisible to this check, so something other than a tick changed. Restore the punch list from the work-target history or the receipts, or end the shift and let the owner edit the list with nothing armed. Nothing else about the shift has changed: your ticks stand.' "$list"
  fi
}

# Zero open boxes is done only when the list is still the one that armed. Deleting the unfinished
# items, or editing the contract once every box is ticked, reaches zero open boxes too, so the done
# path asks the same question the working path asks. A list that has disappeared entirely, from a
# shift that recorded one at arming, is that case at its limit. A snapshot that predates these
# fields records nothing, and a shift without one ends as it always has.
#
# ns_gate_done_mismatch <project-dir> <punch-list> — the sentence to block a done clock-out with, or
# nothing.
ns_gate_done_mismatch() {
  local project="$1" list="$2" recorded
  if [ -f "$list" ]; then
    ns_gate_contract_mismatch "$project" "$list"
    return
  fi
  recorded="$(ns_policy_shift_field "$project" itemsDigest)" || recorded=""
  if [ -z "$recorded" ]; then
    recorded="$(ns_policy_shift_field "$project" contractDigest)" || recorded=""
  fi
  [ -n "$recorded" ] || return 1
  printf 'DO NOT STOP — %s is gone, but this shift armed with a punch list. Deleting the list does not finish its items. Restore it from the work-target history or the receipts, or issue a stop-work order to end the shift with its work unfinished.' "$list"
}
