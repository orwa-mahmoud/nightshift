load helpers

# A valid tonight's snapshot, standing in for what composition or Start would have written.
write_policy_with_deadline() { # <project> <deadlineEpoch-or-null>
  printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z","source":"composition","deadlineEpoch":%s,"verificationLevel":"final","toolingPolicy":"existing-tools"}\n' \
    "$2" >"$1/.nightshift/shift-policy.json"
}

# ---------------------------------------------------------------------------------------------
# Morning-receipt fixtures. The gate resolves the renderer beside itself, so these tests run a
# copied plugin tree and decide which runtime helpers exist in it.

# plugin_copy <name> — a private copy of the plugin, echoing its nightshift root.
plugin_copy() {
  local d="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$d"
  cp -R "$BATS_TEST_DIRNAME/../plugins" "$d/plugins"
  printf '%s' "$d/plugins/nightshift"
}

# gate_from <plugin-root> <project> [ENV=VAL ...] — the shared Stop payload, against a copy.
gate_from() {
  local root="$1" p="$2"
  shift 2
  jq -nc '{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:""}' |
    env "$@" CLAUDE_PROJECT_DIR="$p" bash "$root/hooks/clock-out-gate.sh"
}

# renderer_ok <plugin-root> — a renderer that writes its own arguments into the file it was
# told to write, so a test can read back both the path and the view the gate asked for.
renderer_ok() {
  cat >"$1/runtime/morning-receipt.sh" <<'SH'
#!/usr/bin/env bash
set -u
args="$*"
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      out="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 1
printf '%s\n' "$args" >"$out"
printf '%s\n' "$out"
SH
}

# renderer_fail <plugin-root> — a renderer that writes nothing and fails.
renderer_fail() {
  cat >"$1/runtime/morning-receipt.sh" <<'SH'
#!/usr/bin/env bash
printf 'morning-receipt: no ledger to read\n' >&2
exit 2
SH
}

@test "blocks while a box is open" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p"
  is_block "$output"
}

@test "clock-out reinjection qualifies punch-list against the workspace" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p"
  is_block "$output"
  printf '%s' "$output" | grep -qF "$p/.nightshift/punch-list.md"
  printf '%s' "$output" | grep -qF "$p/.nightshift/parking-lot.md"
  printf '%s' "$output" | grep -qF "$p/.nightshift/STOP"
  if printf '%s' "$output" | grep -qF '$NIGHTSHIFT_WORKSPACE'; then
    return 1
  fi
}

@test "releases when every box is ticked" {
  p="$(new_project)"
  punch_done "$p"
  run gate "$p"
  is_release
}

@test "releases when there is no punch list" {
  p="$(new_project)"
  run gate "$p"
  is_release
  [ -f "$p/.nightshift/.ended" ]
  [ ! -f "$p/.nightshift/.shift-armed" ]
}

@test "an unreadable punch list does not clock out as 0 open" {
  p="$(new_project)"
  punch_open "$p"
  chmod 000 "$p/.nightshift/punch-list.md"
  run gate "$p"
  chmod 644 "$p/.nightshift/punch-list.md"
  is_block "$output"
  [ ! -f "$p/.nightshift/.ended" ]
  [ -f "$p/.nightshift/.shift-armed" ]
}

@test "clock-out replaces a symlink ended marker with a regular file" {
  p="$(new_project)"
  punch_done "$p"
  printf 'plant\n' >"$p/.nightshift/ended-plant"
  ln -s ended-plant "$p/.nightshift/.ended"
  run gate "$p"
  is_release
  [ -f "$p/.nightshift/.ended" ]
  [ ! -L "$p/.nightshift/.ended" ]
}

@test "morning whistle replaces a symlink notified marker" {
  p="$(new_project)"
  punch_done "$p"
  printf 'plant\n' >"$p/.nightshift/notified-plant"
  ln -s notified-plant "$p/.nightshift/.notified"
  wl="$BATS_TEST_TMPDIR/notified-plant.log"
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="printf '%s\\n' \"\$NIGHTSHIFT_SUMMARY\" >> $wl"
  is_release
  [ -f "$p/.nightshift/.notified" ]
  [ ! -L "$p/.nightshift/.notified" ]
  grep -q 'shift done: 2/2' "$wl"
  grep -qF 'plant' "$p/.nightshift/notified-plant"
}

@test "stop-work order releases even with open boxes" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/STOP"
  run gate "$p"
  is_release
}

@test "stop-shift keeps hardhat until the gate writes ENDED" {
  p="$(new_project)"
  punch_open "$p"
  run "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/stop-shift.sh" --project "$p"
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/STOP" ]
  [ -f "$p/.nightshift/.shift-armed" ]
  [ ! -f "$p/.nightshift/.ended" ]
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
  run gate "$p"
  is_release
  [ -f "$p/.nightshift/.ended" ]
  [ ! -f "$p/.nightshift/.shift-armed" ]
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_allow
}

@test "panic STOP releases a leftover recovery nonce" {
  p="$(new_project)"
  punch_open "$p"
  printf 'the-shift\n\n\n\nclaude\n' >"$p/.nightshift/.shift-session"
  bash -c '. "$1"; ns_lease_takeover "$2/.nightshift" the-shift claude' \
    nightshift "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p" >/dev/null
  printf 'stopped by owner\n' >"$p/.nightshift/STOP"
  run gate "$p"
  is_release
  [ -f "$p/.nightshift/.ended" ]
  [ ! -f "$p/.nightshift/.shift-lease" ]
}

@test "the recorded session can clock out after a restored interactive lease" {
  p="$(new_project)"
  punch_done "$p"
  printf 'test-shift-session\n\n\n\nclaude\n' >"$p/.nightshift/.shift-session"
  bash -c '. "$1"; ns_lease_takeover "$2/.nightshift" test-shift-session claude; ns_lease_restore_interactive "$2/.nightshift"' \
    nightshift "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ -z "$(sed -n 4p "$p/.nightshift/.shift-lease")" ]
  run gate "$p"
  is_release
  [ -f "$p/.nightshift/.ended" ]
  [ ! -f "$p/.nightshift/.shift-lease" ]
}

@test "quitting time releases, writes STOP and a shift-log line" {
  p="$(new_project)"
  punch_open "$p"
  echo $(($(date +%s) - 60)) >"$p/.nightshift/deadline"
  run gate "$p"
  is_release
  [ -f "$p/.nightshift/STOP" ]
  grep -q 'quitting time' "$p/.nightshift/shift-log.md"
}

# The done and stop-work releases assert their receipts and whistle below; quitting time and the
# stall opt-in are shift-ending too, and shipped without the same proof.
@test "quitting time leaves receipts, a whistle and the ended marker" {
  p="$(new_project)"
  punch_open "$p"
  receipts_init "$p"
  jq '.receiptsAutoCommit = true' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.tmp"
  mv "$p/.nightshift/rules.tmp" "$p/.nightshift/rules.json"
  wl="$BATS_TEST_TMPDIR/qt.log"
  echo $(($(date +%s) - 60)) >"$p/.nightshift/deadline"
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="printf '%s\\n' \"\$NIGHTSHIFT_SUMMARY\" >> $wl"
  is_release
  [ -f "$p/.nightshift/.ended" ]
  [ "$(git -C "$p/.nightshift" rev-list --count HEAD)" -eq 2 ]
  grep -q 'quitting time' "$wl"
}

@test "the stall auto-end leaves receipts, a whistle and the ended marker" {
  p="$(new_project)"
  punch_open "$p"
  receipts_init "$p"
  jq '.receiptsAutoCommit = true' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.tmp"
  mv "$p/.nightshift/rules.tmp" "$p/.nightshift/rules.json"
  wl="$BATS_TEST_TMPDIR/st.log"
  nc="printf '%s\\n' \"\$NIGHTSHIFT_SUMMARY\" >> $wl"
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="$nc" NIGHTSHIFT_STALL_MAX=2
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="$nc" NIGHTSHIFT_STALL_MAX=2
  is_release
  [ -f "$p/.nightshift/.ended" ]
  [ "$(git -C "$p/.nightshift" rev-list --count HEAD)" -eq 2 ]
  grep -q 'stalled' "$wl"
}

@test "a held shift is not an ended one" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p"
  is_block "$output"
  [ ! -f "$p/.nightshift/.ended" ]
}

# The deadline accepts an epoch or an ISO timestamp. The ISO branch resolves through GNU `date -d`
# or BSD `date -j -f` — one of the two is always the fallback, so these pin both platforms.

@test "an ISO deadline in the past releases the shift" {
  p="$(new_project)"
  punch_open "$p"
  printf '2020-01-01T00:00:00\n' >"$p/.nightshift/deadline"
  run gate "$p"
  is_release
  [ -f "$p/.nightshift/STOP" ]
  grep -q 'quitting time' "$p/.nightshift/shift-log.md"
}

@test "an ISO deadline in the future keeps the shift open" {
  p="$(new_project)"
  punch_open "$p"
  printf '2999-01-01T00:00:00\n' >"$p/.nightshift/deadline"
  run gate "$p"
  is_block "$output"
  [ ! -f "$p/.nightshift/STOP" ]
}

@test "clock-out archives tonight's shift policy under archive/<date>" {
  p="$(new_project)"
  punch_done "$p"
  write_policy_with_deadline "$p" null
  today="$(date '+%Y-%m-%d')"
  run gate "$p"
  is_release
  [ ! -e "$p/.nightshift/shift-policy.json" ]
  [ -f "$p/.nightshift/archive/$today/shift-policy-9f2c40ab77e51d63.json" ]
}

@test "clock-out archives non-empty findings and truncates the live ledger" {
  p="$(new_project)"
  punch_done "$p"
  write_policy_with_deadline "$p" null
  mkdir -p "$p/.nightshift/evidence"
  printf '{"schemaVersion":1,"id":"f1","domain":"test","severity":"low","confidence":"medium","impact":"local","status":"open","ladder":"declared","locator":"x","source":"fixture","sourceClass":"test","host":"local"}\n' \
    >"$p/.nightshift/evidence/findings.jsonl"
  today="$(date '+%Y-%m-%d')"
  run gate "$p"
  is_release
  [ -f "$p/.nightshift/archive/$today/findings-9f2c40ab77e51d63.jsonl" ]
  [ ! -s "$p/.nightshift/evidence/findings.jsonl" ]
}

@test "clock-out releases normally when there is no shift policy to archive" {
  p="$(new_project)"
  punch_done "$p"
  run gate "$p"
  is_release
  [ ! -e "$p/.nightshift/shift-policy.json" ]
}

@test "clock-out renders the owner receipt into receipts/, named for tonight's shift" {
  root="$(plugin_copy receipt-ok)"
  renderer_ok "$root"
  p="$(new_project gate-receipt)"
  punch_done "$p"
  write_policy_with_deadline "$p" null
  today="$(date '+%Y-%m-%d')"

  run gate_from "$root" "$p"
  is_release
  out="$p/.nightshift/receipts/morning-$today-9f2c40ab77e51d63.md"
  [ -f "$out" ]
  # The gate names no view: the owner's configured reader decides, and the shipped default is
  # owner. Forcing one here would override a setting the owner made.
  if grep -qF -- '--view' "$out"; then
    echo "the gate forced a view over the owner's"
    return 1
  fi
  grep -qF -- "--out " "$out"
  grep -qF "morning-$today-9f2c40ab77e51d63.md" "$out"
  # The shiftId is read before anything moves, so the receipt is named for tonight either way.
  [ -f "$p/.nightshift/archive/$today/shift-policy-9f2c40ab77e51d63.json" ]
  if [ -f "$p/.nightshift/shift-log.md" ]; then
    if grep -qF 'morning receipt' "$p/.nightshift/shift-log.md"; then
      return 1
    fi
  fi
}

@test "a shift that never wrote a policy names its receipt for the date alone" {
  root="$(plugin_copy receipt-unknown)"
  renderer_ok "$root"
  p="$(new_project gate-receipt-unknown)"
  punch_done "$p"
  today="$(date '+%Y-%m-%d')"

  run gate_from "$root" "$p"
  is_release
  [ -f "$p/.nightshift/receipts/morning-$today.md" ]
  [ ! -e "$p/.nightshift/receipts/morning-$today-unknown.md" ]
}

@test "an absent morning-receipt renderer never blocks the release" {
  root="$(plugin_copy receipt-absent)"
  rm -f "$root/runtime/morning-receipt.sh"
  p="$(new_project gate-receipt-absent)"
  punch_done "$p"

  run gate_from "$root" "$p"
  is_release
  [ -f "$p/.nightshift/.ended" ]
  [ ! -f "$p/.nightshift/.shift-armed" ]
  grep -qF 'morning receipt skipped: runtime/morning-receipt.sh is not installed' \
    "$p/.nightshift/shift-log.md"
  [ ! -e "$p/.nightshift/receipts" ]
}

@test "a failing morning-receipt renderer never blocks the release" {
  root="$(plugin_copy receipt-fail)"
  renderer_fail "$root"
  p="$(new_project gate-receipt-fail)"
  punch_done "$p"
  today="$(date '+%Y-%m-%d')"

  run gate_from "$root" "$p"
  is_release
  [ -f "$p/.nightshift/.ended" ]
  grep -qF 'morning receipt render failed: morning-receipt: no ledger to read' \
    "$p/.nightshift/shift-log.md"
  [ ! -e "$p/.nightshift/receipts/morning-$today.md" ]
}

@test "a deadline release and a stop-work order both leave the receipt behind" {
  root="$(plugin_copy receipt-deadline)"
  renderer_ok "$root"
  today="$(date '+%Y-%m-%d')"

  p="$(new_project gate-receipt-deadline)"
  punch_open "$p"
  printf '%s\n' "$(( $(date +%s) - 60 ))" >"$p/.nightshift/deadline"
  run gate_from "$root" "$p"
  is_release
  [ -f "$p/.nightshift/receipts/morning-$today.md" ]

  q="$(new_project gate-receipt-stop)"
  punch_open "$q"
  : >"$q/.nightshift/STOP"
  run gate_from "$root" "$q"
  is_release
  [ -f "$q/.nightshift/receipts/morning-$today.md" ]
}

@test "every host gate renders the morning receipt the same way" {
  hooks="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks"
  for h in "$hooks/clock-out-gate.sh" "$hooks/codex/clock-out-gate.sh" \
    "$hooks/cursor/clock-out-gate.sh"; do
    grep -qF 'render_morning_receipt "$shift_id"' "$h" \
      || { echo "no receipt render in end_shift: $h"; return 1; }
    if grep -qF -- '--view owner' "$h"; then
      echo "the gate forces a view over the owner's configured one: $h"
      return 1
    fi
    grep -qF 'ns_handoff_enabled' "$h" || { echo "no handoff switch: $h"; return 1; }
    grep -qF 'morning receipt kept:' "$h" || { echo "a custom handoff is overwritable: $h"; return 1; }
    grep -qF 'morning receipt render failed:' "$h" || { echo "no failure line: $h"; return 1; }
    grep -qF 'morning receipt skipped: runtime/morning-receipt.sh is not installed' "$h" \
      || { echo "no absent-renderer line: $h"; return 1; }
    awk '/render_morning_receipt "\$shift_id"/{r=NR} /receipts_commit "\$1"/{c=NR} END{exit !(r && c && r<c)}' "$h" \
      || { echo "the receipt is written after the snapshot: $h"; return 1; }
  done
}

@test "the gate honours the earlier of the deadline file and the shift-policy deadlineEpoch" {
  p="$(new_project)"
  punch_open "$p"
  future=$(( $(date +%s) + 3600 ))
  past=$(( $(date +%s) - 60 ))
  printf '%s\n' "$future" >"$p/.nightshift/deadline"
  write_policy_with_deadline "$p" "$past"
  run gate "$p"
  is_release
  [ -f "$p/.nightshift/STOP" ]
  grep -qF "deadline mismatch — deadline file $future does not match shift-policy deadlineEpoch $past; honoring the earlier value" \
    "$p/.nightshift/shift-log.md"
  grep -q 'quitting time' "$p/.nightshift/shift-log.md"
}

@test "a shift-policy deadlineEpoch alone ends the shift when the projected file is absent" {
  p="$(new_project)"
  punch_open "$p"
  past=$(( $(date +%s) - 60 ))
  write_policy_with_deadline "$p" "$past"
  run gate "$p"
  is_release
  [ -f "$p/.nightshift/STOP" ]
  grep -q 'quitting time' "$p/.nightshift/shift-log.md"
}

@test "a matching deadline file and shift-policy deadlineEpoch never log a mismatch" {
  p="$(new_project)"
  punch_open "$p"
  future=$(( $(date +%s) + 3600 ))
  printf '%s\n' "$future" >"$p/.nightshift/deadline"
  write_policy_with_deadline "$p" "$future"
  run gate "$p"
  is_block "$output"
  if grep -q 'deadline mismatch' "$p/.nightshift/shift-log.md"; then
    return 1
  fi
}

@test "an unparseable deadline never ends the shift by accident" {
  p="$(new_project)"
  punch_open "$p"
  printf 'not-a-date\n' >"$p/.nightshift/deadline"
  run gate "$p"
  is_block "$output"
  [ ! -f "$p/.nightshift/STOP" ]
}

@test "a symlink deadline never ends the shift by accident" {
  p="$(new_project)"
  punch_open "$p"
  echo $(($(date +%s) - 60)) >"$p/.nightshift/deadline-plant"
  ln -s deadline-plant "$p/.nightshift/deadline"
  run gate "$p"
  is_block "$output"
  [ ! -f "$p/.nightshift/STOP" ]
}

@test "a stalled shift is held by default: block stands, no STOP, warning logged" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p"
  run gate "$p"
  run gate "$p"
  is_block "$output"
  [ ! -f "$p/.nightshift/STOP" ]
  grep -q 'stall warning' "$p/.nightshift/shift-log.md"
}

@test "the hold-mode warning repeats every third stuck attempt" {
  p="$(new_project)"
  punch_open "$p"
  for _ in 1 2 3 4 5 6; do run gate "$p"; done
  is_block "$output"
  [ ! -f "$p/.nightshift/STOP" ]
  [ "$(grep -c 'stall warning' "$p/.nightshift/shift-log.md")" -eq 2 ]
}

@test "the stall opt-in ends the shift after N no-progress stop attempts" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p" NIGHTSHIFT_STALL_MAX=3
  is_block "$output"
  run gate "$p" NIGHTSHIFT_STALL_MAX=3
  is_block "$output"
  run gate "$p" NIGHTSHIFT_STALL_MAX=3
  is_release
  grep -q 'stalled' "$p/.nightshift/STOP"
  grep -q 'stalled — auto-ended' "$p/.nightshift/shift-log.md"
}

@test "a symlink stall does not auto-end the shift" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p" NIGHTSHIFT_STALL_MAX=2
  is_block "$output"
  fp="$(sed -n 1p "$p/.nightshift/.stall")"
  printf '%s\n99\n' "$fp" >"$p/.nightshift/stall-plant"
  rm -f "$p/.nightshift/.stall"
  ln -s stall-plant "$p/.nightshift/.stall"
  run gate "$p" NIGHTSHIFT_STALL_MAX=2
  is_block "$output"
  [ -f "$p/.nightshift/.stall" ]
  [ ! -L "$p/.nightshift/.stall" ]
  [ "$(sed -n 2p "$p/.nightshift/.stall")" = "1" ]
  [ ! -f "$p/.nightshift/STOP" ]
}

@test "a ticked box resets the stall counter" {
  p="$(new_project)"
  printf '## Items\n- [ ] **1.**\n- [ ] **2.**\n' >"$p/.nightshift/punch-list.md"
  run gate "$p"
  run gate "$p"
  printf '## Items\n- [x] **1.**\n- [ ] **2.**\n' >"$p/.nightshift/punch-list.md"
  run gate "$p"
  is_block "$output"
  [ "$(sed -n '2p' "$p/.nightshift/.stall")" = "1" ]
}

@test "a commit resets the stall counter" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p"
  run gate "$p"
  git -C "$p" commit -q --allow-empty -m progress
  run gate "$p"
  is_block "$output"
  [ "$(sed -n '2p' "$p/.nightshift/.stall")" = "1" ]
}

# A receipt is the shift describing what it did, not the doing. In artifact mode progress is a
# tick or a substantive checkpoint; tests/artifact-receipts.bats holds the full contract.
@test "an artifact receipt is not stall progress on its own" {
  p="$(new_project art-stall)"
  printf 'artifact\n' >"$p/.nightshift/work-mode"
  punch_open "$p"
  run gate "$p" NIGHTSHIFT_STALL_WARN=20
  run gate "$p" NIGHTSHIFT_STALL_WARN=20
  [ "$(sed -n '2p' "$p/.nightshift/.stall")" = "2" ]
  printf 'ok\n' >"$p/note.md"
  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/write-receipt.sh" \
    --project "$p" --item 'x' --verify 'ok' --output "$p/note.md"
  [ "$status" -eq 0 ]
  run gate "$p" NIGHTSHIFT_STALL_WARN=20
  is_block "$output"
  [ "$(sed -n '2p' "$p/.nightshift/.stall")" = "3" ]
}

@test "a symlink work-mode does not treat receipts as stall progress" {
  p="$(new_project mode-link-stall)"
  printf 'artifact\n' >"$p/.nightshift/mode-plant"
  ln -s mode-plant "$p/.nightshift/work-mode"
  punch_open "$p"
  run gate "$p" NIGHTSHIFT_STALL_MAX=10 NIGHTSHIFT_STALL_WARN=1
  run gate "$p" NIGHTSHIFT_STALL_MAX=10 NIGHTSHIFT_STALL_WARN=1
  [ "$(sed -n '2p' "$p/.nightshift/.stall")" = "2" ]
  mkdir -p "$p/.nightshift/receipts"
  printf 'planted\n' >"$p/.nightshift/receipts/20260101T000000Z-plant.md"
  run gate "$p" NIGHTSHIFT_STALL_MAX=10 NIGHTSHIFT_STALL_WARN=1
  is_block "$output"
  [ "$(sed -n '2p' "$p/.nightshift/.stall")" = "3" ]
}

@test "workspace layout: a commit in the repo below still counts as progress" {
  w="$(new_workspace)"
  punch_open "$w"
  run gate "$w"
  run gate "$w"
  git -C "$w/repo" commit -q --allow-empty -m progress
  run gate "$w"
  is_block "$output"
  [ "$(sed -n '2p' "$w/.nightshift/.stall")" = "1" ]
}

@test "morning whistle fires once with a summary on a shift-ending release" {
  p="$(new_project)"
  punch_done "$p"
  wl="$BATS_TEST_TMPDIR/whistle.log"
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="printf '%s\\n' \"\$NIGHTSHIFT_SUMMARY\" >> $wl"
  [ "$(wc -l <"$wl" | tr -d ' ')" -eq 1 ]
  grep -q 'shift done: 2/2' "$wl"
}

@test "morning whistle is a silent no-op when unset" {
  p="$(new_project)"
  punch_done "$p"
  run gate "$p"
  is_release
  [ ! -f "$p/.nightshift/.notified" ]
}

@test "morning whistle fires on an opted-in stall release" {
  p="$(new_project)"
  punch_open "$p"
  wl="$BATS_TEST_TMPDIR/w.log"
  nc="printf '%s\\n' \"\$NIGHTSHIFT_SUMMARY\" >> $wl"
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="$nc" NIGHTSHIFT_STALL_MAX=3
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="$nc" NIGHTSHIFT_STALL_MAX=3
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="$nc" NIGHTSHIFT_STALL_MAX=3
  is_release
  grep -q 'stalled' "$wl"
  [ "$(wc -l <"$wl" | tr -d ' ')" -eq 1 ]
}

@test "hold mode never fires the whistle" {
  p="$(new_project)"
  punch_open "$p"
  wl="$BATS_TEST_TMPDIR/held.log"
  nc="printf '%s\\n' \"\$NIGHTSHIFT_SUMMARY\" >> $wl"
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="$nc"
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="$nc"
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="$nc"
  is_block "$output"
  [ ! -f "$wl" ]
}

@test "morning whistle fires on a stop-work release" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/STOP"
  wl="$BATS_TEST_TMPDIR/w.log"
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="printf '%s\\n' \"\$NIGHTSHIFT_SUMMARY\" >> $wl"
  is_release
  grep -q 'shift ended' "$wl"
}

@test "a done release commits the receipts repo only when receiptsAutoCommit is true" {
  p="$(new_project)"
  punch_open "$p"
  receipts_init "$p"
  punch_done "$p"
  run gate "$p"
  is_release
  # Default / missing key: receipts git stays at the Setup init commit only.
  [ "$(git -C "$p/.nightshift" rev-list --count HEAD)" -eq 1 ]
  jq '.receiptsAutoCommit = true' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.tmp"
  mv "$p/.nightshift/rules.tmp" "$p/.nightshift/rules.json"
  rm -f "$p/.nightshift/.ended" "$p/.nightshift/.notified"
  : >"$p/.nightshift/.shift-armed"
  run gate "$p"
  is_release
  [ "$(git -C "$p/.nightshift" rev-list --count HEAD)" -eq 2 ]
  git -C "$p/.nightshift" log -1 --format=%s | grep -q 'shift done: 2/2'
  if git -C "$p/.nightshift" ls-tree -r --name-only HEAD | grep -qxF '.shift-lease'; then
    return 1
  fi
}

@test "a stop-work release snapshots the receipts repo when receiptsAutoCommit is true" {
  p="$(new_project)"
  punch_open "$p"
  receipts_init "$p"
  jq '.receiptsAutoCommit = true' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.tmp"
  mv "$p/.nightshift/rules.tmp" "$p/.nightshift/rules.json"
  printf 'stopped by owner\n' >"$p/.nightshift/STOP"
  printf 'parked: pick the DB\n' >"$p/.nightshift/parking-lot.md"
  run gate "$p"
  is_release
  [ "$(git -C "$p/.nightshift" rev-list --count HEAD)" -eq 2 ]
}

@test "the stop reason keeps its spacing in the whistle summary" {
  p="$(new_project)"
  punch_open "$p"
  printf 'stopped by owner · 2026-07-19T02:40:00\n' >"$p/.nightshift/STOP"
  wl="$BATS_TEST_TMPDIR/w.log"
  run gate "$p" NIGHTSHIFT_NOTIFY_CMD="printf '%s\\n' \"\$NIGHTSHIFT_SUMMARY\" >> $wl"
  is_release
  grep -q 'stopped by owner' "$wl"
}

@test "the gate records the shift session while blocking" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p"
  is_block "$output"
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "test-shift-session" ]
  [ "$(wc -l <"$p/.nightshift/.shift-session")" -eq 5 ] # id, transcript, pid, start time, host
  # The host is what stops another agent's watchman acting on a shift that is not its own.
  [ "$(sed -n 5p "$p/.nightshift/.shift-session")" = "claude" ]
}

# ---- the shift binds one session: everyone else stops freely ----

@test "another conversation's stop is not the shift's business — released" {
  p="$(new_project)"
  punch_open "$p"
  printf 'the-shift\n\n\n\n' >"$p/.nightshift/.shift-session"
  run gate "$p" # this stop arrives as test-shift-session, not the-shift
  is_release
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "the-shift" ] # record untouched
  [ ! -f "$p/.nightshift/.ended" ] # and nothing was ended on the stranger's way out
}

@test "the recorded shift session itself is still held" {
  p="$(new_project)"
  punch_open "$p"
  printf 'test-shift-session\n\n\n\n' >"$p/.nightshift/.shift-session"
  run gate "$p"
  is_block "$output"
}

# The fresh-session fallback gives a revival a NEW id. The watchman's generation capability,
# not a forgeable boolean mark, authorizes the rebind.
@test "a leased revival inherits the binding under a new id and re-claims the record" {
  p="$(new_project)"
  punch_open "$p"
  printf 'dead-old-id\n\n\n\n' >"$p/.nightshift/.shift-session"
  lib="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
  claim="$(bash -c '. "$1"; ns_lease_takeover "$2/.nightshift" dead-old-id claude' \
    nightshift "$lib" "$p")"
  run gate "$p" NIGHTSHIFT_REVIVAL=1 \
    NIGHTSHIFT_LEASE_GENERATION="${claim%% *}" NIGHTSHIFT_LEASE_NONCE="${claim#* }"
  is_block "$output"
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "test-shift-session" ]
}

# ---- the site lock: two sessions may stop at once; the bookkeeping must not tear ----

@test "a stale lock from a dead process never blocks the gate" {
  p="$(new_project)"
  punch_open "$p"
  bash -c ':' &
  deadpid=$!
  wait "$deadpid" 2>/dev/null || true
  mkdir "$p/.nightshift/.lock.d"
  printf '%s' "$deadpid" >"$p/.nightshift/.lock.d/pid"
  run gate "$p"
  is_block "$output"
  [ ! -d "$p/.nightshift/.lock.d" ] # broken, taken, released
}

@test "a live foreign lock delays but never hangs the gate — and is never stolen" {
  p="$(new_project)"
  punch_open "$p"
  mkdir "$p/.nightshift/.lock.d"
  printf '%s' "$$" >"$p/.nightshift/.lock.d/pid"
  run gate "$p"
  is_block "$output"
  [ "$(cat "$p/.nightshift/.lock.d/pid")" = "$$" ] # still the foreign holder's
}

# The torn read this lock exists for: both racers read the same counter, both warn, both write
# zero. Serialized, exactly one warns and the counter lands where a sequence of two valid stop
# attempts leaves it.
@test "two racing stop attempts warn the stall exactly once" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p" # let the gate write the real fingerprint
  fp="$(sed -n 1p "$p/.nightshift/.stall")"
  printf '%s\n2\n' "$fp" >"$p/.nightshift/.stall"
  jq -nc '{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:""}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/clock-out-gate.sh" >/dev/null &
  g1=$!
  jq -nc '{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:""}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/clock-out-gate.sh" >/dev/null &
  g2=$!
  wait "$g1" "$g2" 2>/dev/null || true
  [ "$(grep -c 'stall warning' "$p/.nightshift/shift-log.md")" -eq 1 ]
  [ "$(sed -n 2p "$p/.nightshift/.stall")" = "1" ]
}

# The reinjected contract is the owner's to word — jq builds the JSON so their text cannot
# break the decision.
@test "the clock-out reinjection is the owner's to word" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p" NIGHTSHIFT_GATE_MESSAGE="back to the bench — boxes are open"
  is_block "$output"
  printf '%s' "$output" | grep -q "back to the bench"
}

@test "the stall warning cadence is the owner's (rules file: stallWarnEvery)" {
  p="$(new_project)"
  punch_open "$p"
  run gate "$p" NIGHTSHIFT_STALL_WARN=2
  run gate "$p" NIGHTSHIFT_STALL_WARN=2
  is_block "$output"
  grep -q 'stall warning — session active, no durable checkpoint since the last 2 stop attempts' "$p/.nightshift/shift-log.md"
}

@test "the gate reads the stall cadence from the rules file" {
  p="$(new_project)"
  punch_open "$p"
  jq '.stallWarnEvery = 2' "$RULES_TEMPLATE" >"$p/.nightshift/rules.json"
  run gate "$p"
  run gate "$p"
  is_block "$output"
  grep -q 'stall warning — session active, no durable checkpoint since the last 2 stop attempts' "$p/.nightshift/shift-log.md"
}

# The block never depends on config: unreadable knobs still gate, fail closed, repair named.
@test "a missing rules file still blocks and names the repair" {
  p="$(new_project)"
  punch_open "$p"
  rm "$p/.nightshift/rules.json"
  run gate "$p"
  is_block "$output"
  printf '%s' "$output" | grep -qF '/nightshift:setup'
  printf '%s' "$output" | grep -qF 'ask Nightshift to set up on Codex'
  grep -q 'stall guard down' "$p/.nightshift/shift-log.md"
}

# ---- a dead recovery attempt never decides the clock-out ----

FOREIGN_NONCE=claude.2.4711.8.9

@test "the recorded conversation takes its shift back at clock-out and is held to the list" {
  p="$(new_project)"
  punch_open "$p"
  dead="$(reaped_pid)"
  session_record "$p" test-shift-session "" "$$" "$(process_start "$$")" claude
  lease_record "$p" test-shift-session claude 2 "$FOREIGN_NONCE" "$dead" ""

  run gate "$p"
  is_block "$output"
  [ "$(lease_generation "$p")" = "3" ]
  [ -z "$(lease_nonce "$p")" ]
  [ "$(reclaim_log_count "$p" 2 3)" -eq 1 ]
  [ ! -f "$p/.nightshift/.ended" ]
}

@test "a live recovery worker still keeps the recorded conversation out of the clock-out" {
  p="$(new_project)"
  punch_open "$p"
  sleep 300 &
  holder=$!
  session_record "$p" test-shift-session "" "$$" "$(process_start "$$")" claude
  lease_record "$p" test-shift-session claude 2 "$FOREIGN_NONCE" "$holder" "$(process_start "$holder")"

  run gate "$p"
  is_release
  [ "$(lease_generation "$p")" = "2" ]
  [ "$(lease_nonce "$p")" = "$FOREIGN_NONCE" ]
  [ ! -f "$p/.nightshift/.ended" ]
  [ "$(reclaim_log_count "$p")" -eq 0 ]

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

# Disarm is total on this side too: the gate holds nobody once the marker is gone, and a
# leftover lease — live holder or dead — is not a reason to hold a session or to end a shift.
@test "an unarmed site holds nobody at clock-out, whatever the lease still says" {
  p="$(new_project)"
  punch_open "$p"
  sleep 300 &
  holder=$!
  session_record "$p" test-shift-session "" "" "" claude
  lease_record "$p" test-shift-session claude 2 "$FOREIGN_NONCE" "$holder" "$(process_start "$holder")"
  rm "$p/.nightshift/.shift-armed"

  run gate "$p"
  is_release
  [ ! -f "$p/.nightshift/.ended" ]
  [ "$(lease_nonce "$p")" = "$FOREIGN_NONCE" ]

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  q="$(new_project unarmed-dead-holder)"
  punch_open "$q"
  dead="$(reaped_pid)"
  session_record "$q" test-shift-session "" "" "" claude
  lease_record "$q" test-shift-session claude 2 "$FOREIGN_NONCE" "$dead" ""
  rm "$q/.nightshift/.shift-armed"

  run gate "$q"
  is_release
  [ ! -f "$q/.nightshift/.ended" ]
  [ "$(reclaim_log_count "$q")" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------
# The receipt is rendered from the live ledger, so it runs before the archive truncates it.
# These use the real renderer and the real archiver: a stub would prove nothing about ordering.

# seeded_ledger <project> — a baseline that saw two ids, one of them since fixed, and a second
# source that could not run. Enough that every evidence section of the receipt has content.
seeded_ledger() {
  local p="$1" ev="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/evidence.sh"
  bash "$ev" --project "$p" init >/dev/null
  bash "$ev" --project "$p" append --record "$(jq -nc '{
    schemaVersion: 1, id: "b1", domain: "baseline", sourceClass: "eslint", source: "eslint .",
    scope: "src/", severity: "info", confidence: "high", impact: "developer", status: "open",
    ladder: "measured", locator: "src/", digest: "digest-b1",
    firstSeen: "2026-09-02T00:00:00Z", lastChecked: "2026-09-02T00:00:00Z", action: "",
    host: "claude", workTarget: "/repo",
    details: { sourceCommand: "eslint .", environmentDigest: "env-1", rawDigest: "raw-b1",
               seen: [ { id: "i1", digest: "di1" }, { id: "i2", digest: "di2" } ] }
  }')" >/dev/null
  bash "$ev" --project "$p" append --record "$(jq -nc '{
    schemaVersion: 1, id: "i1", domain: "lint", sourceClass: "eslint", source: "eslint .",
    scope: "src/", severity: "medium", confidence: "high", impact: "developer", status: "fixed",
    ladder: "observed", locator: "src/app.js:1", digest: "di1",
    firstSeen: "2026-09-02T00:00:00Z", lastChecked: "2026-09-02T00:00:00Z", action: "",
    host: "claude", workTarget: "/repo"
  }')" >/dev/null
  bash "$ev" --project "$p" append --record "$(jq -nc '{
    schemaVersion: 1, id: "t1", domain: "types", sourceClass: "tsc", source: "tsc --noEmit",
    scope: "src/", severity: "high", confidence: "high", impact: "developer",
    status: "unavailable", ladder: "observed", locator: "src/", digest: "dt1",
    firstSeen: "2026-09-02T00:00:00Z", lastChecked: "2026-09-02T00:00:00Z", action: "",
    host: "claude", workTarget: "/repo"
  }')" >/dev/null
}

# the_receipt <project> — tonight's morning file, whatever it ended up named.
the_receipt() {
  printf '%s' "$1/.nightshift/receipts/morning-$(date '+%Y-%m-%d')-9f2c40ab77e51d63.md"
}

@test "the morning receipt keeps its evidence when the ledger is archived on the way out" {
  root="$(plugin_copy receipt-evidence)"
  p="$(new_project gate-receipt-evidence)"
  punch_done "$p"
  write_policy_with_deadline "$p" null
  seeded_ledger "$p"
  lines_before="$(wc -l <"$p/.nightshift/evidence/findings.jsonl")"

  run gate_from "$root" "$p"
  is_release

  out="$(the_receipt "$p")"
  [ -f "$out" ]
  # The three sections that read from the ledger, which an emptied ledger renders as nothing.
  grep -q '^## Baseline' "$out"
  grep -qF 'b1: eslint' "$out"
  grep -q '^## What changed' "$out"
  grep -qF '| i1 |' "$out"
  grep -qF 'Summary:' "$out"
  # The archive copy is complete, and the live ledger starts the next shift lean.
  arch="$p/.nightshift/archive/$(date '+%Y-%m-%d')/findings-9f2c40ab77e51d63.jsonl"
  [ -f "$arch" ]
  [ "$(wc -l <"$arch")" -eq "$lines_before" ]
  [ ! -s "$p/.nightshift/evidence/findings.jsonl" ]
}

@test "a stop-work order keeps the same evidence on its way out" {
  root="$(plugin_copy receipt-evidence-stop)"
  p="$(new_project gate-receipt-evidence-stop)"
  punch_open "$p"
  write_policy_with_deadline "$p" null
  seeded_ledger "$p"
  printf 'owner said so\n' >"$p/.nightshift/STOP"

  run gate_from "$root" "$p"
  is_release

  out="$(the_receipt "$p")"
  [ -f "$out" ]
  grep -q '^## Baseline' "$out"
  grep -qF '| i1 |' "$out"
  [ -f "$p/.nightshift/archive/$(date '+%Y-%m-%d')/findings-9f2c40ab77e51d63.jsonl" ]
}

@test "quitting time keeps the same evidence on its way out" {
  root="$(plugin_copy receipt-evidence-deadline)"
  p="$(new_project gate-receipt-evidence-deadline)"
  punch_open "$p"
  write_policy_with_deadline "$p" 1
  seeded_ledger "$p"

  run gate_from "$root" "$p"
  is_release

  out="$(the_receipt "$p")"
  [ -f "$out" ]
  grep -q '^## Baseline' "$out"
  grep -qF '| i1 |' "$out"
  [ -f "$p/.nightshift/archive/$(date '+%Y-%m-%d')/findings-9f2c40ab77e51d63.jsonl" ]
}

@test "a second stop event never overwrites a complete receipt with an empty one" {
  root="$(plugin_copy receipt-evidence-twice)"
  p="$(new_project gate-receipt-evidence-twice)"
  punch_done "$p"
  write_policy_with_deadline "$p" null
  seeded_ledger "$p"

  run gate_from "$root" "$p"
  is_release
  out="$(the_receipt "$p")"
  first="$(cat "$out")"

  # The shift is no longer armed, so the second event releases without ending anything again.
  run gate_from "$root" "$p"
  is_release
  [ "$(cat "$out")" = "$first" ]
  grep -q '^## Baseline' "$out"
  [ "$(find "$p/.nightshift/archive" -name 'findings-*.jsonl' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a renderer that fails still leaves the evidence archived" {
  root="$(plugin_copy receipt-evidence-fail)"
  renderer_fail "$root"
  p="$(new_project gate-receipt-evidence-fail)"
  punch_done "$p"
  write_policy_with_deadline "$p" null
  seeded_ledger "$p"

  run gate_from "$root" "$p"
  is_release
  [ ! -f "$(the_receipt "$p")" ]
  grep -qF 'morning receipt render failed' "$p/.nightshift/shift-log.md"
  [ -f "$p/.nightshift/archive/$(date '+%Y-%m-%d')/findings-9f2c40ab77e51d63.jsonl" ]
  [ -f "$p/.nightshift/.ended" ]
}

# ---------------------------------------------------------------------------------------------
# The morning page is the owner's: which reader it is written for, which sections it carries,
# whether it is written at all, and whether the model wrote its own instead.

# handoff <project> <jq-expression> — set the handoff block the owner's way.
handoff() {
  jq "$2" "$1/.nightshift/rules.json" >"$1/r.json"
  mv "$1/r.json" "$1/.nightshift/rules.json"
}

@test "the configured reader decides the page, not the gate" {
  root="$(plugin_copy handoff-view)"
  p="$(new_project gate-handoff-view)"
  punch_done "$p"
  write_policy_with_deadline "$p" null
  seeded_ledger "$p"
  handoff "$p" '.handoff.view = "reviewer"'

  run gate_from "$root" "$p"
  is_release
  out="$(the_receipt "$p")"
  [ -f "$out" ]
  # The reviewer page is the baseline and the comparison, and carries no Shift section.
  grep -q '^## Baseline' "$out"
  grep -q '^## What changed' "$out"
  if grep -q '^## Shift' "$out"; then
    echo "the reviewer view rendered the owner page"
    return 1
  fi
}

@test "an owner section list picks and orders what the page carries" {
  root="$(plugin_copy handoff-sections)"
  p="$(new_project gate-handoff-sections)"
  punch_done "$p"
  write_policy_with_deadline "$p" null
  seeded_ledger "$p"
  handoff "$p" '.handoff.sections = ["changed", "shift"]'

  run gate_from "$root" "$p"
  is_release
  out="$(the_receipt "$p")"
  [ -f "$out" ]
  # Both asked-for sections, in the order asked, and nothing else.
  [ "$(grep -c '^## ' "$out")" -eq 2 ]
  [ "$(grep -n '^## What changed' "$out" | cut -d: -f1)" -lt "$(grep -n '^## Shift' "$out" | cut -d: -f1)" ]
  if grep -q '^## Baseline' "$out"; then
    echo "a section the owner did not ask for was rendered"
    return 1
  fi
  # Dropping a section changes the page, never the evidence.
  [ -f "$p/.nightshift/archive/$(date '+%Y-%m-%d')/findings-9f2c40ab77e51d63.jsonl" ]
}

@test "a page the owner turned off is not written, and nothing else is lost" {
  root="$(plugin_copy handoff-off)"
  p="$(new_project gate-handoff-off)"
  punch_done "$p"
  write_policy_with_deadline "$p" null
  seeded_ledger "$p"
  handoff "$p" '.handoff.enabled = false'

  run gate_from "$root" "$p"
  is_release
  [ ! -f "$(the_receipt "$p")" ]
  grep -qF 'morning receipt disabled by the owner' "$p/.nightshift/shift-log.md"
  # Every factual record still stands.
  [ -f "$p/.nightshift/archive/$(date '+%Y-%m-%d')/findings-9f2c40ab77e51d63.jsonl" ]
  [ -f "$p/.nightshift/archive/$(date '+%Y-%m-%d')/shift-policy-9f2c40ab77e51d63.json" ]
  [ -f "$p/.nightshift/.ended" ]
}

@test "a handoff the model already wrote is never overwritten" {
  root="$(plugin_copy handoff-custom)"
  p="$(new_project gate-handoff-custom)"
  punch_done "$p"
  write_policy_with_deadline "$p" null
  seeded_ledger "$p"
  out="$(the_receipt "$p")"
  mkdir -p "$(dirname "$out")"
  printf '# تقرير الليلة\n\nكل شيء تم.\n' >"$out"
  before="$(cat "$out")"

  run gate_from "$root" "$p"
  is_release
  [ "$(cat "$out")" = "$before" ]
  grep -qF 'morning receipt kept:' "$p/.nightshift/shift-log.md"
  # The evidence is still archived around it.
  [ -f "$p/.nightshift/archive/$(date '+%Y-%m-%d')/findings-9f2c40ab77e51d63.jsonl" ]
}

@test "two shifts on one day get their own page, and a repeat event writes neither twice" {
  root="$(plugin_copy handoff-two)"
  p="$(new_project gate-handoff-two)"
  punch_done "$p"
  write_policy_with_deadline "$p" null
  seeded_ledger "$p"
  run gate_from "$root" "$p"
  is_release
  first="$(the_receipt "$p")"
  [ -f "$first" ]
  stamp="$(cksum <"$first")"

  # A second stop event for the same shift changes nothing.
  run gate_from "$root" "$p"
  is_release
  [ "$(cksum <"$first")" = "$stamp" ]

  # A second shift the same day, with its own id, gets its own page beside the first.
  : >"$p/.nightshift/.shift-armed"
  rm -f "$p/.nightshift/.ended"
  printf '{"schemaVersion":1,"shiftId":"1122334455667788","createdAt":"2026-09-02T02:30:00Z","source":"composition","deadlineEpoch":null,"verificationLevel":"final","toolingPolicy":"existing-tools"}\n' \
    >"$p/.nightshift/shift-policy.json"
  run gate_from "$root" "$p"
  is_release
  second="$p/.nightshift/receipts/morning-$(date '+%Y-%m-%d')-1122334455667788.md"
  [ -f "$second" ]
  [ -f "$first" ]
  [ "$first" != "$second" ]
}
