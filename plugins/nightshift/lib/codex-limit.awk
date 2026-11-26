# Read the structured fields projected by ns_codex_limit_reset in rollout order.
# The latest exhausted observation for each quota and window survives sparse updates.

function epoch(value) { return value ~ /^[0-9]+$/ && value > 0 && value <= 253402300799 }

function remember(bucket, slot, used, reset) {
  if (used ~ /^-?[0-9]/ && used + 0 >= 100) resets[bucket, slot] = reset
}

function inferred(failed,    window, reset, latest) {
  if (!epoch(failed)) return ""
  for (window in resets) {
    reset = resets[window]
    if (!epoch(reset)) return ""
    if (reset + 0 >= failed + 0 && reset + 0 > latest) latest = reset + 0
  }
  return latest
}

$1 != "\"event_msg\"" { next }

{
  turn_id = ($3 ~ /^"/ && $3 != "\"\"") ? $3 : ""
  same_turn = started && (turn == "" || turn_id == "" || turn_id == turn)
}

$2 == "\"task_started\"" {
  for (window in resets) delete resets[window]
  started = 1
  turn = turn_id
  result = ""
}

$2 == "\"token_count\"" && same_turn {
  bucket = ($7 ~ /^"/ && $7 != "\"\"") ? $7 : "\"codex\""
  remember(bucket, "primary", $8, $9)
  remember(bucket, "secondary", $10, $11)
}

$2 == "\"task_complete\"" {
  result = ""
  if ($5 == "\"usage_limit_exceeded\"") {
    if (epoch($6)) result = $6 + 0
    else if (same_turn) result = inferred($4)
  }
  started = 0
}

END { if (result > 0) printf "%.0f", result }
