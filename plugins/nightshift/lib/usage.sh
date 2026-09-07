#!/usr/bin/env bash
# usage.sh — what a shift cost, read from the records the host already keeps.
#
# Nightshift does the per-item accounting; the model does none of it. On no host can a model see
# its own token usage from inside the conversation, so an instruction to measure it can only
# produce `unavailable`. The hosts do expose the numbers — to the hooks Nightshift already
# registers — and this is where those numbers are read.
#
# Everything here is a cumulative counter and a pair of marks. A snapshot is that counter at one
# moment, in the host's own field names; an item's cost is the difference between the snapshot at
# its start and the snapshot at its tick. No counter is ever reset: the delta is the reset.
#
# A snapshot line is one record, tab-separated:
#
#   <epoch>\t<host>\t<model>\t<source>\t<identity>\t<k=v,k=v,...>
#
# `identity` is the transcript path or payload identity the reading came from. When it changes —
# a revival after an outage, a fresh CLI worker, a model change, or a counter that went backwards —
# a new segment opens rather than a negative delta being taken across the seam.
#
# Nothing here reads a host's storage at large: only the transcript the hook was handed and the
# payload the host delivered. No network, no credentials, no tokenizer, no estimate.

# The awk half sits next to this file, resolved without dirname so a hostile PATH cannot reach it.
_NS_USAGE_CLAUDE_AWK="${BASH_SOURCE[0]%/*}"
[ "$_NS_USAGE_CLAUDE_AWK" != "${BASH_SOURCE[0]}" ] || _NS_USAGE_CLAUDE_AWK=.
_NS_USAGE_AWK_DIR="$_NS_USAGE_CLAUDE_AWK"
_NS_USAGE_CLAUDE_AWK="$_NS_USAGE_AWK_DIR/usage-claude.awk"
_NS_USAGE_CODEX_AWK="$_NS_USAGE_AWK_DIR/usage-codex.awk"
_NS_USAGE_CURSOR_AWK="$_NS_USAGE_AWK_DIR/usage-cursor.awk"

# ns_usage_retire <nightshift-dir> <shift-id> — move a finished shift's accounting aside.
#
# `usage/` holds one shift's readings: the offsets it had reached, the marks it took, the totals it
# accumulated. Left in place, the next shift opens transcripts at the previous shift's offsets and
# adds to the previous shift's totals, and the two nights become one number nobody can separate.
# Renaming rather than deleting keeps the record: Archive files `usage-*` with everything else.
#
# Silent when there is nothing to retire, which is the ordinary case for a first shift.
ns_usage_retire() {
  local ns="$1" id="$2" dir dest
  dir="$(ns_usage_dir "$ns")"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  case "$id" in '' | */* | .*) id="" ;; esac
  [ -n "$id" ] || id="$(date +%Y%m%dT%H%M%SZ)"
  dest="$ns/usage-$id"
  # A second shift ending under the same id would otherwise clobber the first one's record.
  [ ! -e "$dest" ] || dest="$ns/usage-$id-$(date +%s)"
  mv "$dir" "$dest" 2>/dev/null || return 1
  printf '%s' "$dest"
}

# ns_usage_dir <nightshift-dir> — where snapshots live. Created on demand.
ns_usage_dir() { printf '%s/usage' "$1"; }

# ns_usage_kv <key> <value> — one field of a snapshot, or nothing when the host did not report it.
# A dimension the host does not report is absent, never zero: zero is a measurement.
ns_usage_kv() {
  case "${2:-}" in
    '' | null) return 0 ;;
    *[!0-9]*) return 0 ;;
  esac
  printf '%s=%s' "$1" "$2"
}

# _ns_usage_join <kv>... — the fields that were reported, comma-separated.
_ns_usage_join() {
  local out="" one
  for one in "$@"; do
    [ -n "$one" ] || continue
    [ -z "$out" ] || out="$out,"
    out="$out$one"
  done
  printf '%s' "$out"
}

# ns_usage_field <snapshot-fields> <key> — one dimension out of a snapshot, or empty.
ns_usage_field() {
  local rest="$1" pair
  while [ -n "$rest" ]; do
    pair="${rest%%,*}"
    case "$rest" in *,*) rest="${rest#*,}" ;; *) rest="" ;; esac
    case "$pair" in
      "$2="*)
        printf '%s' "${pair#*=}"
        return 0
        ;;
    esac
  done
  return 1
}

# ns_usage_read_claude <transcript> [offset] — the cumulative counter from a Claude Code session
# transcript, and the byte offset read to. Prints:
#
#   <fields>\t<offset>\t<model>\t<responses>
#
# One API response is written as several lines, one per content block, and every one of them
# repeats the same usage. Summing lines instead of responses inflates the total — measured at
# 2,421 usage lines for 1,526 responses on a real session, and the ratio varies with how many
# blocks a response has, so the rule is deduplicate, never divide by a constant. Identity is
# `requestId`, falling back to `message.id`.
#
# Reading is incremental: pass the offset from the previous read and only the appended bytes are
# parsed. The counter returned is still cumulative, because the caller adds this read's totals to
# what it had. Anthropic reports cache creation and cache read separately from input; they are
# additive, and this keeps them that way.
ns_usage_read_claude() {
  local file="$1" offset="${2:-0}" carry="${3:-}" size bin
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  size="$(ns_file_size "$file")" || return 1
  case "$offset" in '' | *[!0-9]*) offset=0 ;; esac
  # A transcript that shrank is a different file under the same name: start over rather than read
  # from an offset into content that is not the content it was measured against. The carried
  # identity goes with it — it describes a file that is no longer there.
  [ "$offset" -le "$size" ] || { offset=0; carry=""; }
  if [ "$offset" -eq "$size" ]; then
    printf '\t%s\t\t0\t%s' "$size" "$carry"
    return 0
  fi
  bin="$(ns_usage_awk_bin)" || return 1
  tail -c "+$((offset + 1))" "$file" 2>/dev/null |
    "$bin" -v size="$size" -v carry="$carry" -f "$_NS_USAGE_CLAUDE_AWK" 2>/dev/null || return 1
}

# ns_usage_subagents <transcript> — the subagent transcripts belonging to one session, if any.
#
# A Task-spawned agent writes its own file beside the session's, and its usage is there rather
# than in the parent. Only this session's own directory is looked at: nothing scans ~/.claude for
# other sessions.
ns_usage_subagents() {
  local dir base sub
  case "$1" in */*) dir="${1%/*}" ;; *) return 1 ;; esac
  base="${1##*/}"
  sub="$dir/${base%.jsonl}/subagents"
  [ -d "$sub" ] && [ ! -L "$sub" ] || return 1
  find "$sub" -maxdepth 1 -type f -name 'agent-*.jsonl' 2>/dev/null | sort
}

# ns_usage_awk_bin — the awk the readers use, resolved once the way the rules reader resolves it.
ns_usage_awk_bin() { ns_rules_awk_bin; }

# ns_file_size <file> — bytes, portably.
ns_file_size() {
  local n
  n="$(wc -c <"$1" 2>/dev/null | tr -d ' ')" || return 1
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# ns_usage_read_codex <rollout> — the cumulative counter from a Codex rollout.
#
# Codex keeps a running total for the session, so reading it is one tail for the last
# `token_count` line rather than a walk over every message. The overlap is Codex's own and is
# preserved rather than corrected: `cached_input_tokens` sits inside `input_tokens`, and
# `reasoning_output_tokens` inside `output_tokens` — on a real rollout, input + output equalled
# total_tokens exactly, which only holds if the cache and reasoning figures are already counted.
#
# The rollout format is documented as not stable for hooks, so a line that is not the expected
# shape yields nothing and the caller reports `unavailable` with the reason. A partial sum is
# never presented as a complete one.
ns_usage_read_codex() {
  local file="$1" line bin
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  line="$(grep '"token_count"' "$file" 2>/dev/null | tail -n1)" || return 1
  [ -n "$line" ] || return 1
  bin="$(ns_usage_awk_bin)" || return 1
  printf '%s\n' "$line" | "$bin" -f "$_NS_USAGE_CODEX_AWK" 2>/dev/null || return 1
}

# ns_usage_read_cursor <payload> — the counter from a Cursor stop payload.
#
# Cursor delivers the figures on the hook payload itself; there is no transcript to read, and the
# local agent transcripts carry no usage at all. The fields are optional and undocumented at the
# time of writing, so every one of them is read defensively: a payload without them is not zero
# usage, it is no measurement, and the caller says `unavailable`. Cursor's input overlaps its cache
# figures, and it reports no reasoning or subagent tokens.
ns_usage_read_cursor() {
  local raw="$1" bin
  [ -n "$raw" ] || return 1
  bin="$(ns_usage_awk_bin)" || return 1
  printf '%s\n' "$raw" | "$bin" -f "$_NS_USAGE_CURSOR_AWK" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------------------------
# Segments and marks
#
# A segment is one continuous counter: one transcript, one CLI worker, one session. Its
# contribution is (current − start), so a segment that begins mid-session contributes only what
# was spent after Nightshift started watching it. When the identity changes — a revival after an
# outage, a fresh worker, a model change, a counter that went backwards — a new segment opens and
# nothing is ever subtracted across the seam.
#
# A mark is that running total at one moment, written at every tick. Item N is the difference
# between mark N-1 and mark N: everything spent between two ticks belongs to the item ticked
# second, its gates and its report section included. Spend before the first item and after the
# last tick is shift overhead, which is the same subtraction against the arm mark and the end.
#
# Two append-only files under .nightshift/usage/, and nothing else. No daemon, no timer, no
# polling, no second session.
NS_USAGE_DIMENSIONS='input cache_write cache_read output reasoning'

_ns_usage_state() { printf '%s/segments.tsv' "$(ns_usage_dir "$1")"; }
_ns_usage_marks() { printf '%s/marks.tsv' "$(ns_usage_dir "$1")"; }

# ns_usage_sub <a-fields> <b-fields> — a minus b, dimension by dimension. A dimension neither
# side reports is absent from the answer; a dimension that would go negative is clamped to zero
# and reported as such by the caller opening a new segment instead.
ns_usage_sub() {
  local dim a b out="" one
  for dim in $NS_USAGE_DIMENSIONS; do
    a="$(ns_usage_field "$1" "$dim")" || a=""
    b="$(ns_usage_field "$2" "$dim")" || b=""
    [ -n "$a" ] || continue
    [ -n "$b" ] || b=0
    one=$((a - b))
    [ "$one" -ge 0 ] || one=0
    [ -z "$out" ] || out="$out,"
    out="$out$dim=$one"
  done
  printf '%s' "$out"
}

# ns_usage_add <a-fields> <b-fields> — a plus b, dimension by dimension.
ns_usage_add() {
  local dim a b out=""
  for dim in $NS_USAGE_DIMENSIONS; do
    a="$(ns_usage_field "$1" "$dim")" || a=""
    b="$(ns_usage_field "$2" "$dim")" || b=""
    [ -n "$a$b" ] || continue
    [ -n "$a" ] || a=0
    [ -n "$b" ] || b=0
    [ -z "$out" ] || out="$out,"
    out="$out$dim=$((a + b))"
  done
  printf '%s' "$out"
}

# ns_usage_record <nightshift-dir> <host> <model> <source> <identity> <offset> <fields>
# One reading for one segment. The first reading of an identity is its start; every later reading
# moves its current. A reading lower than the segment's current is a counter that went backwards,
# which is a new counter wearing the same name: it opens a fresh segment rather than producing a
# negative.
ns_usage_record() {
  local ns="$1" host="$2" model="$3" src="$4" id="$5" offset="$6" fields="$7" carry="${8:-}"
  local dir file line found=0 start cur seg tmp dim now new_id="$id"
  [ -n "$id" ] && [ -n "$fields" ] || return 1
  dir="$(ns_usage_dir "$ns")"
  mkdir -p "$dir" 2>/dev/null || return 1
  file="$(_ns_usage_state "$ns")"
  now="$(date +%s)"
  [ -f "$file" ] || : >"$file"
  # Claude's reader hands back only what was appended since the last offset, so its segment total
  # accumulates; the other hosts hand back a counter that is already cumulative for the session.
  if [ "$src" = transcript-incremental ]; then
    seg="$(_ns_usage_seg_field "$file" "$id" 7)" || seg=""
    fields="$(ns_usage_add "${seg:-}" "$fields")"
  fi
  start="$(_ns_usage_seg_field "$file" "$id" 6)" || start=""
  cur="$(_ns_usage_seg_field "$file" "$id" 7)" || cur=""
  if [ -n "$cur" ] && [ "$(ns_usage_sub "$cur" "$fields")" != "$(ns_usage_sub "$cur" "$cur")" ]; then
    # The stored current is higher than the new reading somewhere: a different counter.
    new_id="$id#$now"
    start=""
    cur=""
  fi
  # A segment's contribution is what it spent after Nightshift began watching it. Where the reader
  # already hands back only the newly appended spend, that is the contribution outright and the
  # start is zero; where it hands back a counter that was already running, the first reading is
  # the start and only what advances past it counts.
  if [ -z "$start" ]; then
    if [ "$src" = transcript-incremental ]; then
      start="$(ns_usage_sub "$fields" "$fields")"
    else
      start="$fields"
    fi
  fi
  tmp="$dir/.segments.$$"
  : >"$tmp" || return 1
  while IFS= read -r line; do
    case "$line" in
      "$new_id	"*) found=1; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$new_id" "$host" "$model" "$src" "$offset" "$start" "$fields" "$carry" >>"$tmp" ;;
      '') ;;
      *) printf '%s\n' "$line" >>"$tmp" ;;
    esac
  done <"$file"
  [ "$found" -eq 1 ] || printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$new_id" "$host" "$model" "$src" "$offset" "$start" "$fields" "$carry" >>"$tmp"
  mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# _ns_usage_seg_field <file> <identity> <column> — one column of a segment, or empty.
_ns_usage_seg_field() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "$2	"*)
        printf '%s' "$line" | cut -f "$3"
        return 0
        ;;
    esac
  done <"$1"
  return 1
}

# ns_usage_total <nightshift-dir> — the running total across every segment: the sum of what each
# one spent after Nightshift started watching it.
ns_usage_total() {
  local file line start cur total=""
  file="$(_ns_usage_state "$1")"
  [ -f "$file" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    start="$(printf '%s' "$line" | cut -f6)"
    cur="$(printf '%s' "$line" | cut -f7)"
    [ -n "$cur" ] || continue
    total="$(ns_usage_add "$total" "$(ns_usage_sub "$cur" "$start")")"
  done <"$file"
  [ -n "$total" ] || return 1
  printf '%s' "$total"
}

# ns_usage_segments <nightshift-dir> — how many segments this shift has, for the source line.
ns_usage_segments() {
  local file
  file="$(_ns_usage_state "$1")"
  [ -f "$file" ] || { printf '0'; return 0; }
  grep -c . "$file" 2>/dev/null || printf '0'
}

# ns_usage_hosts <nightshift-dir> — the host and model behind the readings, for the source line.
# More than one host in a shift is reported as such rather than silently summed.
ns_usage_hosts() {
  local file
  file="$(_ns_usage_state "$1")"
  [ -f "$file" ] || return 1
  cut -f2,3 "$file" 2>/dev/null | sort -u | tr '\t' ' ' | paste -sd'; ' - 2>/dev/null
}

# ns_usage_mark <nightshift-dir> <label> — the running total and the clock at one moment.
#
# Written when the shift arms and at every tick. Time is measured exactly like tokens: one
# cumulative counter, marks on it at the boundaries, deltas for everything else. Item N runs from
# mark N-1 to mark N, so an item's start is the previous tick and never the model announcing one.
ns_usage_mark() {
  local ns="$1" label="$2" dir file total
  dir="$(ns_usage_dir "$ns")"
  mkdir -p "$dir" 2>/dev/null || return 1
  file="$(_ns_usage_marks "$ns")"
  total="$(ns_usage_total "$ns")" || total=""
  printf '%s\t%s\t%s\n' "$(date +%s)" "$label" "$total" >>"$file" 2>/dev/null || return 1
}

# ns_usage_mark_arm <nightshift-dir> [transcript...] — the shift's own start.
#
# Written before the first reading is ever taken, so it stands at zero and the first item is
# credited with everything measured after it. A mark written later would carry whatever had
# already accrued and silently swallow the first item's spend into the baseline.
#
# The transcripts are the shift's other baseline. A conversation that set the night up has already
# written to the file the incremental reader is about to open, and that reader starts from byte 0
# for a transcript it has not seen. Every response spent deciding what to do tonight would then be
# billed to item one. Stamping a segment here at the file's current size means the first real
# reading begins at the end of what was already there. A transcript that appears later — a subagent
# spawned mid-shift — is not stamped, because all of its content is work.
# _ns_usage_seg_baseline <nightshift-dir> <transcript> <offset> — start this transcript here.
#
# One segment line with the offset set to what the file already holds and no spend recorded against
# it. The incremental reader takes its start from column 5, so the first real reading opens the file
# past everything that was written before the shift armed. Never overwrites: a transcript already
# carrying a segment has been read at least once, and its offset is the truth about where reading
# got to.
_ns_usage_seg_baseline() {
  local ns="$1" id="$2" offset="$3" dir file
  [ -n "$id" ] || return 1
  case "$offset" in '' | *[!0-9]*) return 1 ;; esac
  dir="$(ns_usage_dir "$ns")"
  mkdir -p "$dir" 2>/dev/null || return 1
  file="$(_ns_usage_state "$ns")"
  [ -f "$file" ] || : >"$file"
  ! grep -q "^$id	" "$file" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" claude '' transcript-incremental "$offset" '' '' '' >>"$file" 2>/dev/null || return 1
}

ns_usage_mark_arm() {
  local ns="$1" dir file t size
  dir="$(ns_usage_dir "$ns")"
  mkdir -p "$dir" 2>/dev/null || return 1
  file="$(_ns_usage_marks "$ns")"
  [ ! -s "$file" ] || return 0
  shift
  for t in "$@"; do
    [ -n "$t" ] && [ -f "$t" ] || continue
    size="$(ns_file_size "$t")" || continue
    _ns_usage_seg_baseline "$ns" "$t" "$size" || true
  done
  printf '%s\t%s\t\n' "$(date +%s)" arm >>"$file" 2>/dev/null || return 1
}

# ns_usage_mark_count <nightshift-dir> — how many marks stand.
ns_usage_mark_count() {
  local file
  file="$(_ns_usage_marks "$1")"
  [ -f "$file" ] || { printf '0'; return 0; }
  grep -c . "$file" 2>/dev/null || printf '0'
}

# ns_usage_since_last_mark <nightshift-dir> — what has been spent since the most recent mark, and
# how long ago that mark was: `<fields>\t<seconds>`. Empty fields where nothing is measurable.
ns_usage_since_last_mark() {
  local file last epoch total now
  file="$(_ns_usage_marks "$1")"
  now="$(date +%s)"
  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
    printf '\t0'
    return 0
  fi
  last="$(tail -n1 "$file")"
  epoch="$(printf '%s' "$last" | cut -f1)"
  total="$(ns_usage_total "$1")" || total=""
  case "$epoch" in '' | *[!0-9]*) epoch="$now" ;; esac
  printf '%s\t%s' "$(ns_usage_sub "$total" "$(printf '%s' "$last" | cut -f3)")" "$((now - epoch))"
}

# ns_usage_last_item <nightshift-dir> — the span between the last two marks: what the item ticked
# second cost, and how long it ran. `<fields>\t<seconds>\t<label>`.
ns_usage_last_item() {
  local file two prev last
  file="$(_ns_usage_marks "$1")"
  [ -f "$file" ] || return 1
  two="$(tail -n2 "$file")"
  [ "$(printf '%s\n' "$two" | grep -c .)" -eq 2 ] || return 1
  prev="$(printf '%s\n' "$two" | head -n1)"
  last="$(printf '%s\n' "$two" | tail -n1)"
  printf '%s\t%s\t%s' \
    "$(ns_usage_sub "$(printf '%s' "$last" | cut -f3)" "$(printf '%s' "$prev" | cut -f3)")" \
    "$(( $(printf '%s' "$last" | cut -f1) - $(printf '%s' "$prev" | cut -f1) ))" \
    "$(printf '%s' "$last" | cut -f2)"
}

# ns_usage_pause <nightshift-dir> <reason> — a gap the runtime knows was not work.
#
# A session that ended and was revived, or a shift held at STOP, is wall-clock time nobody spent.
# It is recorded so the duration line can list it, and never subtracted silently: a figure that
# quietly excludes time is a figure nobody can check.
ns_usage_pause() {
  local dir file
  dir="$(ns_usage_dir "$1")"
  mkdir -p "$dir" 2>/dev/null || return 1
  file="$dir/pauses.tsv"
  printf '%s\t%s\n' "$(date +%s)" "${2:-paused}" >>"$file" 2>/dev/null || return 1
}

# ns_usage_paused_since <nightshift-dir> <epoch> — how long was recorded as not-work since that
# moment, and why. `<seconds>\t<reason>`, empty when the runtime knows of no gap.
#
# A pause is closed by the next thing that happens: the gap runs from the pause to the reading
# that follows it. Where nothing followed, the gap is open and is reported as such rather than
# guessed at.
ns_usage_paused_since() {
  local ns="$1" from="$2" file line at reason total=0 last_reason="" next
  file="$(ns_usage_dir "$ns")/pauses.tsv"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line; do
    at="$(printf '%s' "$line" | cut -f1)"
    reason="$(printf '%s' "$line" | cut -f2)"
    case "$at" in '' | *[!0-9]*) continue ;; esac
    [ "$at" -ge "$from" ] || continue
    next="$(_ns_usage_resumed_at "$ns" "$at")" || next=""
    [ -n "$next" ] || continue
    total=$((total + next - at))
    last_reason="$reason"
  done <"$file"
  [ "$total" -gt 0 ] || return 1
  printf '%s\t%s' "$total" "$last_reason"
}

# _ns_usage_resumed_at <nightshift-dir> <epoch> — when work was next seen after a pause, from the
# marks the runtime was already keeping.
_ns_usage_resumed_at() {
  local file line at
  file="$(_ns_usage_marks "$1")"
  [ -f "$file" ] || return 1
  while IFS= read -r line; do
    at="$(printf '%s' "$line" | cut -f1)"
    case "$at" in '' | *[!0-9]*) continue ;; esac
    if [ "$at" -gt "$2" ]; then
      printf '%s' "$at"
      return 0
    fi
  done <"$file"
  return 1
}

# ns_usage_overlap <host> — the one sentence that says what is already counted inside what, so a
# reader never adds the same tokens twice. Each host's own arrangement, not a normalised one.
ns_usage_overlap() {
  case "$1" in
    claude) printf 'Cache reads and cache writes are separate from the input figure; reasoning is inside output.' ;;
    codex) printf 'Cached input is already inside the input figure, and reasoning is already inside output.' ;;
    cursor) printf 'The input figure overlaps the cache figures; Cursor reports no reasoning or subagent tokens.' ;;
    *) printf 'Overlap between the dimensions is unknown for this host.' ;;
  esac
}

# ns_usage_line <fields> <host-and-model> <segments> — the usage line as the report carries it.
# Every dimension by name, `unavailable` for one the host does not report, never a total across
# hosts, and never a price.
ns_usage_line() {
  local fields="$1" dim v out=""
  for dim in $NS_USAGE_DIMENSIONS; do
    v="$(ns_usage_field "$fields" "$dim")" || v=unavailable
    [ -n "$v" ] || v=unavailable
    [ -z "$out" ] || out="$out · "
    out="$out$dim $v"
  done
  printf 'Usage: %s\n  Source: %s, cumulative counters, segments %s\n  %s' \
    "$out" "$2" "$3" "$(ns_usage_overlap "${4:-}")"
}

# ns_usage_duration <seconds> — a wall-clock span in the words a person reads.
ns_usage_duration() {
  local s="${1:-0}"
  case "$s" in '' | *[!0-9]*) printf 'unavailable'; return 0 ;; esac
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"; return 0; fi
  if [ "$s" -lt 3600 ]; then printf '%sm %ss' "$((s / 60))" "$((s % 60))"; return 0; fi
  printf '%sh %sm' "$((s / 3600))" "$(((s % 3600) / 60))"
}

# ---------------------------------------------------------------------------------------------
# The progress cadence, evaluated by the runtime
#
# `report.progressMode` decides when the model should refresh the active item's progress
# paragraph. The model does not evaluate it: `time` needs a clock it would have to keep itself,
# and `tokens` needs a counter it cannot see. The pulse already fires on every tool call, so it
# does the arithmetic against the same marks and the same counter everything else here uses.
#
# The last update is detected mechanically. The pulse hashes the active item's section in the
# report; a changed hash means the model refreshed it, and the window restarts. Nothing asks the
# model to remember when it last wrote, and nothing believes it if it says.

# ns_usage_section_hash <report> <item-label> — a hash of that item's section, or empty.
ns_usage_section_hash() {
  local report="$1" label="$2" body
  [ -f "$report" ] && [ ! -L "$report" ] || return 1
  body="$(awk -v want="### $label" '
    $0 == want { on = 1; next }
    on && /^### / { exit }
    on { print }
  ' "$report" 2>/dev/null)" || return 1
  printf '%s' "$body" | ns_usage_sum
}

# ns_usage_sum — a short stable digest of stdin, from whatever the machine has.
ns_usage_sum() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | cut -c1-16
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | cut -c1-16
  else
    cksum 2>/dev/null | tr -d ' ' | cut -c1-16
  fi
}

# ns_usage_window <nightshift-dir> <item-label> <report> — where the current cadence window
# started, as `<epoch>\t<total-fields>`. The later of the item's own start mark and the last time
# its section changed, so a progress update restarts the window and nothing else does.
ns_usage_window() {
  local ns="$1" label="$2" report="$3" file line epoch total hash stamp
  file="$(_ns_usage_marks "$ns")"
  [ -f "$file" ] || return 1
  line="$(tail -n1 "$file")"
  epoch="$(printf '%s' "$line" | cut -f1)"
  total="$(printf '%s' "$line" | cut -f3)"
  hash="$(ns_usage_section_hash "$report" "$label")" || hash=""
  stamp="$(ns_usage_dir "$ns")/window"
  if [ -n "$hash" ]; then
    if [ ! -f "$stamp" ] || [ -L "$stamp" ]; then
      # First sight of this section. Recording what it looks like is not the same as the model
      # having just refreshed it, so the window stays where the item started — otherwise nothing
      # would ever fall due, because every first look would restart the clock.
      mkdir -p "$(ns_usage_dir "$ns")" 2>/dev/null || return 1
      printf '%s\t%s\t%s\n' "${epoch:-0}" "$hash" "$total" >"$stamp" 2>/dev/null || :
    elif [ "$(cut -f2 "$stamp" 2>/dev/null)" != "$hash" ]; then
      # It changed, so the model refreshed it: the window starts again from here.
      printf '%s\t%s\t%s\n' "$(date +%s)" "$hash" "$(ns_usage_total "$ns")" >"$stamp" 2>/dev/null || :
      rm -f "$ns/.report-due" 2>/dev/null || :
    fi
  fi
  if [ -f "$stamp" ] && [ ! -L "$stamp" ]; then
    if [ "$(cut -f1 "$stamp" 2>/dev/null)" -gt "${epoch:-0}" ] 2>/dev/null; then
      epoch="$(cut -f1 "$stamp")"
      total="$(cut -f3 "$stamp")"
    fi
  fi
  printf '%s\t%s' "${epoch:-0}" "$total"
}

# ns_usage_progress_due <project-dir> <item-label> — status 0 when the owner's cadence says an
# update is now due. `completion-only` never is; `time` and `tokens` measure against the window;
# `either` is whichever comes first. A mode that needs a counter no host reported falls back to
# the time cadence rather than quietly never firing.
ns_usage_progress_due() {
  local project="$1" label="$2" ns="$1/.nightshift" mode minutes tokens window epoch base now spent moved
  mode="$(ns_report "$project" progressMode)"
  [ -n "$mode" ] || mode="time"
  [ "$mode" != completion-only ] || return 1
  [ "$(ns_report "$project" usage)" != off ] || return 1
  window="$(ns_usage_window "$ns" "$label" "$(ns_report_path "$project")")" || return 1
  epoch="$(printf '%s' "$window" | cut -f1)"
  base="$(printf '%s' "$window" | cut -f2)"
  now="$(date +%s)"
  minutes="$(ns_report "$project" progressMinutes)"
  case "$minutes" in '' | *[!0-9]*) minutes=20 ;; esac
  tokens="$(ns_report "$project" progressTokens)"
  case "$tokens" in '' | *[!0-9]*) tokens=100000 ;; esac
  case "$mode" in
    time) [ "$((now - epoch))" -ge "$((minutes * 60))" ] && return 0 ;;
    tokens | either)
      spent="$(ns_usage_total "$ns")" || spent=""
      if [ -n "$spent" ]; then
        moved="$(ns_usage_countable "$(ns_usage_sub "$spent" "$base")")"
        [ "$moved" -ge "$tokens" ] && return 0
      elif [ "$mode" = tokens ]; then
        # A token cadence with no counter to read is a time cadence, not a silence.
        [ "$((now - epoch))" -ge "$((minutes * 60))" ] && return 0
      fi
      [ "$mode" = either ] && [ "$((now - epoch))" -ge "$((minutes * 60))" ] && return 0
      ;;
  esac
  return 1
}

# ns_usage_countable <fields> — input plus output, counted once. A token cadence is about how much
# was spent, and the cache and reasoning figures either sit inside those two already or are
# separate readings of the same work; adding them would make the threshold mean something
# different on every host.
ns_usage_countable() {
  local a b
  a="$(ns_usage_field "$1" input)" || a=0
  b="$(ns_usage_field "$1" output)" || b=0
  [ -n "$a" ] || a=0
  [ -n "$b" ] || b=0
  printf '%s' "$((a + b))"
}
