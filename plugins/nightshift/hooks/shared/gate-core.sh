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
# The tick is the boundary. Everything spent between two ticks belongs to the item ticked second —
# its gates and its own report section included — so the gate snapshots the counter as it releases
# and the next item starts from the same reading. The model writes none of this and is told not
# to: on no host can it see its own usage from inside the conversation.
#
# ns_gate_usage_tick <nightshift-dir> <project-dir> <item-label>
ns_gate_usage_tick() {
  local ns="$1" project="$2" label="$3" span fields seconds host line report
  [ -d "$ns" ] || return 0
  [ "$(ns_report "$project" usage)" != off ] || return 0
  ns_usage_mark "$ns" "$label" || return 0
  span="$(ns_usage_last_item "$ns")" || return 0
  fields="$(printf '%s' "$span" | cut -f1)"
  seconds="$(printf '%s' "$span" | cut -f2)"
  host="$(ns_usage_hosts "$ns")" || host="unknown"
  report="$(ns_report_path "$project")"
  [ -n "$fields" ] || return 0
  line="$(ns_usage_line "$fields" "$host" "$(ns_usage_segments "$ns")" "$(printf '%s' "$host" | cut -d' ' -f1)")"
  ns_gate_usage_append "$report" "$label" "$line" "$(ns_usage_duration "$seconds")"
}

# ns_gate_usage_append <report> <item-label> <usage-line> <duration> — put the two runtime-written
# lines under the item's heading. If the model has not written that section yet, the lines still
# land under a heading of their own: the measurement does not wait on the narrative.
ns_gate_usage_append() {
  local report="$1" label="$2" usage="$3" duration="$4" tmp existing
  [ -n "$report" ] || return 0
  [ ! -L "$report" ] || return 0
  if [ ! -f "$report" ]; then
    printf '# Shift report\n' >"$report" 2>/dev/null || return 0
  fi
  tmp="$report.usage.$$"
  if grep -qF "### $label" "$report" 2>/dev/null; then
    # Spliced in the shell rather than handed to awk: the usage block is three lines, and awk's
    # -v cannot carry a newline.
    : >"$tmp" || return 0
    while IFS= read -r existing || [ -n "$existing" ]; do
      printf '%s\n' "$existing" >>"$tmp"
      if [ "$existing" = "### $label" ]; then
        printf '\n%s\nDuration: %s\n' "$usage" "$duration" >>"$tmp"
      fi
    done <"$report"
    mv "$tmp" "$report" 2>/dev/null || rm -f "$tmp"
    return 0
  fi
  {
    printf '\n### %s\n\n%s\nDuration: %s\n' "$label" "$usage" "$duration"
  } >>"$report" 2>/dev/null || :
}

# ns_gate_usage_sync <nightshift-dir> <project-dir> <punch-list> <ticked> — catch the marks up to
# the boxes.
#
# The gate does not see a tick happen; it sees how many boxes are ticked when a stop is attempted.
# So it compares that count against the marks it has already written and closes whatever is newly
# done, in order, taking each item's own label from the list. One mark per item, written once: a
# second stop attempt with nothing newly ticked adds nothing.
ns_gate_usage_sync() {
  local ns="$1" project="$2" list="$3" ticked="$4" marked label i=0
  [ -d "$ns" ] || return 0
  [ -f "$list" ] || return 0
  case "$ticked" in '' | *[!0-9]*) return 0 ;; esac
  [ "$(ns_report "$project" usage)" != off ] || return 0
  # The arm mark is the shift's own start, and is not an item.
  marked="$(ns_usage_mark_count "$ns")"
  case "$marked" in '' | *[!0-9]*) marked=0 ;; esac
  [ "$marked" -gt 0 ] || { ns_usage_mark_arm "$ns"; marked=1; }
  while [ "$((marked - 1))" -lt "$ticked" ]; do
    i=$((marked))
    label="$(ns_gate_item_label "$list" "$i")"
    [ -n "$label" ] || label="item $i"
    ns_gate_usage_tick "$ns" "$project" "$label" || return 0
    marked=$((marked + 1))
  done
}

# ns_gate_item_label <punch-list> <n> — the id of the nth ticked item, as the report heads its
# section. `- [x] **P03 — …**` gives `P03`.
ns_gate_item_label() {
  ns_items_section "$1" 2>/dev/null | awk -v want="$2" '
    /^- \[x\]/ {
      n++
      if (n != want) next
      line = $0
      sub(/^- \[x\][[:space:]]*\*\*/, "", line)
      sub(/[[:space:]]*[—-].*$/, "", line)
      sub(/\*\*.*$/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      print line
      exit
    }
  '
}
