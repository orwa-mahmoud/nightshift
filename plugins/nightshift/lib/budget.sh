#!/usr/bin/env bash
# budget.sh — item budgets. An item may name a soft and a hard limit in time, tokens or both; the
# shift block's itemBudget is the budget of every item that names none.
#
#   - Budget: soft 30m / 1M tokens, hard 45m / 2M tokens
#
# A soft limit tells the agent once to start finishing the item. A hard limit allows only wrap-up
# from the next tool call — commit the work in progress, write the receipt, close the item as
# stopped (`- [-]`) — and a stopped item is never ticked. Time is the item's working time across
# every session; tokens are input plus output, as the host reports them. Both are the runtime's
# own readings: the agent never measures itself.

# ns_budget_parse <text> — `<soft-seconds> <soft-tokens> <hard-seconds> <hard-tokens>`, `-` for a
# limit the text does not set. Status 1 for empty text, 2 for text that is not a budget.
ns_budget_parse() {
  printf '%s\n' "$1" | awk -f "$NS_STATE_LIB/budget-parse.awk"
}

# ns_budget_words <seconds> <tokens> — a limit or a reading as a person reads it:
# `45m 0s / 2.0M tokens`. A `-` half is left out.
ns_budget_words() {
  local out=""
  [ "$1" = - ] || out="$(ns_usage_duration "$1")"
  if [ "$2" != - ]; then
    [ -z "$out" ] || out="$out / "
    out="$out$(ns_usage_scale "$2") tokens"
  fi
  printf '%s' "$out"
}

# ns_budget_item_text <punch-list> <label> — the text of that item's own `Budget:` line, or nothing.
ns_budget_item_text() {
  ns_items_section "$1" 2>/dev/null | awk -v want="$2" -f "$NS_STATE_ITEM_AWK" -f "$NS_STATE_LIB/budget-item-text.awk"
}

# ns_budget_text <project> <label> — the budget that item works under: its own line, else the shift
# block's itemBudget, else nothing.
ns_budget_text() {
  local own
  own="$(ns_budget_item_text "$(ns_layout_path "$1/.nightshift" punch-list)" "$2")"
  if [ -n "$own" ]; then
    printf '%s' "$own"
    return 0
  fi
  ns_policy_pref "$1" shift itemBudget 2>/dev/null
}

# ns_budget_spent <nightshift-dir> <project> <label> — `<working-seconds> <tokens>` the item has
# spent so far: every session its receipt records, plus the span running now when it is the item
# being worked. `-` for a measurement the owner turned off.
ns_budget_spent() {
  local ns="$1" project="$2" label="$3" receipt line work in out
  local secs=0 toks=0 since fields span last paused
  receipt="$(ns_receipt_path "$project" "$label")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r _ _ _ work in out _ <<<"$line"
    case "$work" in '' | *[!0-9]*) ;; *) secs=$((secs + work)) ;; esac
    case "$in" in '' | *[!0-9]*) ;; *) toks=$((toks + in)) ;; esac
    case "$out" in '' | *[!0-9]*) ;; *) toks=$((toks + out)) ;; esac
  done < <(ns_receipt_session_data "$receipt")
  if [ "$(ns_usage_active "$ns")" = "$label" ]; then
    since="$(ns_usage_since_last_mark "$ns")"
    fields="${since%%$'\t'*}"
    span="${since#*$'\t'}"
    last="$(tail -n1 "$(ns_usage_dir "$ns")/marks.tsv" 2>/dev/null | cut -f1)"
    case "$span" in '' | *[!0-9]*) span=0 ;; esac
    case "$last" in
      '' | *[!0-9]*) ;;
      *)
        if paused="$(ns_usage_paused_between "$ns" "$last" "$((last + span))")"; then
          span=$((span - ${paused%%$'\t'*}))
          [ "$span" -ge 0 ] || span=0
        fi
        ;;
    esac
    secs=$((secs + span))
    toks=$((toks + $(ns_usage_field "$fields" input || printf 0) + $(ns_usage_field "$fields" output || printf 0)))
  fi
  [ "$(ns_receipts "$project" duration)" != off ] || secs=-
  [ "$(ns_receipts "$project" usage)" != off ] || toks=-
  printf '%s %s' "$secs" "$toks"
}

# ns_budget_state_file <nightshift-dir> — the budget record: `<label>\t<soft|hard>\t<epoch>\t<item-id>` lines.
ns_budget_state_file() { ns_layout_path "$1" budget; }

# ns_budget_reached <nightshift-dir> <label> <soft|hard> — the epoch that limit was recorded at.
ns_budget_reached() {
  local file id
  file="$(ns_budget_state_file "$1")"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  id="$(ns_item_id_for "$(ns_layout_path "$1" punch-list)" "$2")"
  awk -F '\t' -v l="$2" -v k="$3" -v id="$id" '(($4 != "" && $4 == id) || ($4 == "" && $1 == l)) && $2 == k { print $3; found = 1; exit } END { exit !found }' "$file"
}

# ns_budget_hard_open <nightshift-dir> — the open item whose hard budget is spent, or status 1.
# Any one is enough: until it is closed, only wrap-up runs.
ns_budget_hard_open() {
  local file punch label level _epoch id state current current_id found
  file="$(ns_budget_state_file "$1")"
  punch="$(ns_layout_path "$1" punch-list)"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS=$'\t' read -r label level _epoch id; do
    [ "$level" = hard ] || continue
    found=0
    while IFS=$'\t' read -r state current current_id; do
      if { [ -n "$id" ] && [ "$current_id" = "$id" ]; } || { [ -z "$id" ] && [ "$current" = "$label" ]; }; then
        found=1
        if [ "$state" = open ]; then printf '%s' "$current"; return 0; fi
        break
      fi
    done < <(ns_item_states "$punch")
    # Removing or replacing the identity does not release a reached limit.
    if [ "$found" -eq 0 ]; then printf '%s' "$label"; return 0; fi
  done <"$file"
  return 1
}

# ns_budget_check <nightshift-dir> <project> — on each pulse: when the item being worked has just
# spent a limit, record it once, journal it, and print the notice for the agent.
ns_budget_check() {
  local ns="$1" project="$2" label text parsed ss sk hs hk spent st tk file level limit words id
  [ -f "$(ns_layout_path "$ns" armed)" ] || return 1
  label="$(ns_active_item "$project" 2>/dev/null)" || return 1
  [ -n "$label" ] || return 1
  text="$(ns_budget_text "$project" "$label")"
  parsed="$(ns_budget_parse "$text")" || return 1
  read -r ss sk hs hk <<<"$parsed"
  ns_budget_reached "$ns" "$label" hard >/dev/null && return 1
  spent="$(ns_budget_spent "$ns" "$project" "$label")"
  read -r st tk <<<"$spent"
  level=""
  if _ns_budget_over "$st" "$hs" || _ns_budget_over "$tk" "$hk"; then
    level=hard
    limit="$(ns_budget_words "$hs" "$hk")"
  elif ! ns_budget_reached "$ns" "$label" soft >/dev/null &&
    { _ns_budget_over "$st" "$ss" || _ns_budget_over "$tk" "$sk"; }; then
    level=soft
    limit="$(ns_budget_words "$ss" "$sk")"
  fi
  [ -n "$level" ] || return 1
  file="$(ns_budget_state_file "$ns")"
  mkdir -p "${file%/*}" 2>/dev/null || return 1
  [ ! -L "$file" ] || return 1
  id="$(ns_item_id_for "$(ns_layout_path "$ns" punch-list)" "$label")"
  printf '%s\t%s\t%s\t%s\n' "$label" "$level" "$(date +%s)" "$id" >>"$file" || return 1
  words="$(ns_budget_words "$st" "$tk")"
  ns_shift_log "$ns" "budget · $label · $level limit reached ($limit; spent $words)"
  ns_budget_notice "$level" "$label" "$limit" "$words"
}

# _ns_budget_over <spent> <limit> — status 0 when a set limit is spent.
_ns_budget_over() {
  case "$1:$2" in *-* | :* | *:) return 1 ;; esac
  [ "$1" -ge "$2" ]
}

# ns_budget_notice <soft|hard> <label> <limit-words> <spent-words> — what the agent is told.
ns_budget_notice() {
  if [ "$1" = soft ]; then
    printf 'budget: %s has reached its soft budget (%s; spent %s). Start finishing it now: complete the change in hand, run its Verify, write the receipt and tick it.' \
      "$2" "$3" "$4"
  else
    printf 'budget: %s has reached its hard budget (%s; spent %s). %s' "$2" "$3" "$4" "$(ns_budget_wrapup "$2")"
  fi
}

# ns_budget_wrapup <label> — the wrap-up a spent hard budget allows, in the agent's words.
ns_budget_wrapup() {
  printf "From the next tool call only wrap-up is allowed: commit the work in progress (git add, then git commit -m \"wip: ...\"), write the item's receipt, then close %s as stopped: change its box to \`- [-]\` and add a \`Stopped:\` sub-bullet naming the limit, what was spent and the commit. Never tick it. Then move to the next item." "$1"
}

# ns_budget_forget <nightshift-dir> <label> — drop what was recorded for an item once it is closed,
# so an item the owner opens again starts with its budget unspent.
ns_budget_forget() {
  local file tmp id
  file="$(ns_budget_state_file "$1")"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  tmp="$file.$$"
  id="$(ns_item_id_for "$(ns_layout_path "$1" punch-list)" "$2")"
  awk -F '\t' -v l="$2" -v id="$id" '!(($4 == "" && $1 == l) || (id != "" && $4 == id))' "$file" >"$tmp" && mv "$tmp" "$file"
}
