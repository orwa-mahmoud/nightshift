#!/usr/bin/env bash
# evidence-lifecycle.sh — read-only evidence ledger and shift-progress helpers.

# ns_evidence_jsonl <workspace> — absolute path to the live findings ledger.
ns_evidence_jsonl() {
  local dir
  ns_layout_set dir "${1%/}/.nightshift" evidence
  printf '%s/findings.jsonl' "$dir"
}

# ns_gate_checkpoint_token <workspace> — latest checkpoint id for stall fingerprints.
ns_gate_checkpoint_token() {
  local ws="${1:?}" jsonl line id=""
  jsonl="$(ns_evidence_jsonl "$ws")"
  if [ ! -f "$jsonl" ] || [ -L "$jsonl" ]; then
    printf 'none'
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    id="$(jq -r 'select(.domain == "checkpoint") | .id' "$jsonl" 2>/dev/null | tail -n1)"
  elif command -v python3 >/dev/null 2>&1; then
    id="$(python3 - "$jsonl" <<'PY'
import json, sys
last = ""
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("domain") == "checkpoint" and rec.get("id"):
            last = rec["id"]
print(last)
PY
)"
  fi
  [ -n "$id" ] || id=none
  printf '%s' "$id"
}

# ns_evidence_counts <workspace> — one line: findings=N open=O baseline=B checkpoint=C
ns_evidence_counts() {
  local ws="${1:?}" jsonl f=0 o=0 b=0 c=0
  jsonl="$(ns_evidence_jsonl "$ws")"
  if [ ! -f "$jsonl" ] || [ -L "$jsonl" ]; then
    printf 'findings=0 open=0 baseline=0 checkpoint=0'
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      f=$((f + 1))
      case "$line" in
        *'"domain":"baseline"'* | *'"domain": "baseline"'*) b=$((b + 1)) ;;
        *'"domain":"checkpoint"'* | *'"domain": "checkpoint"'*) c=$((c + 1)) ;;
      esac
      case "$line" in
        *'"status":"open"'* | *'"status": "open"'*) o=$((o + 1)) ;;
      esac
    done <"$jsonl"
  elif command -v python3 >/dev/null 2>&1; then
    eval "$(python3 - "$jsonl" <<'PY'
import json, sys
f = o = b = c = 0
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        f += 1
        if rec.get("domain") == "baseline":
            b += 1
        elif rec.get("domain") == "checkpoint":
            c += 1
        if rec.get("status") == "open":
            o += 1
print(f"f={f} o={o} b={b} c={c}")
PY
)"
  fi
  printf 'findings=%s open=%s baseline=%s checkpoint=%s' "$f" "$o" "$b" "$c"
}

# ns_status_liveness <ns> <watch_minutes> — fresh|stale|absent
ns_status_liveness() {
  local ns="${1:?}" watch="${2:-0}"
  if ns_pulse_fresh "$ns" "$watch"; then
    printf 'fresh'
  elif [ -n "$(ns_pulse_epoch "$ns")" ]; then
    printf 'stale'
  else
    printf 'absent'
  fi
}

# ns_status_last_activity <ns> — epoch seconds or empty
ns_status_last_activity() {
  ns_pulse_epoch "${1:?}"
}

# ns_status_last_checkpoint <workspace> — checkpoint id or none
ns_status_last_checkpoint() {
  local id
  id="$(ns_gate_checkpoint_token "$1")"
  [ "$id" = none ] && id=""
  printf '%s' "${id:-none}"
}

# ns_status_stall_attempts <ns> — integer from .stall line 2
ns_status_stall_attempts() {
  local ns="${1:?}" n="" stall
  ns_layout_set stall "$ns" stall
  if [ ! -f "$stall" ] || [ -L "$stall" ]; then
    printf '0'
    return 0
  fi
  n="$(sed -n '2p' "$stall" 2>/dev/null | tr -d '[:space:]')"
  case "$n" in '' | *[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# ns_long_unit_warn_due <workspace> <minutes> — 0 ok · 1 warn
ns_long_unit_warn_due() {
  local ws="${1:?}" mins="${2:-0}" ns armed start now
  case "$mins" in '' | 0 | *[!0-9]*) return 1 ;; esac
  ns="$ws/.nightshift"
  ns_layout_set armed "$ns" armed
  [ -f "$armed" ] && [ ! -L "$armed" ] || return 1
  start="$(ns_mtime "$armed")"
  [ -n "$start" ] || return 1
  now="$(date +%s)"
  [ $((now - start)) -lt $((mins * 60)) ] && return 1
  [ "$(ns_gate_checkpoint_token "$ws")" = none ] || return 1
  return 0
}
