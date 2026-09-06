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
