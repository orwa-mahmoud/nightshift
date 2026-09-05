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
