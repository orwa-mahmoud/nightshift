#!/usr/bin/env bats
# Receipt duty injected by the pulse, session-start, and clock-out reminder.

load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
PULSE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/pulse.sh"
CORE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/gate-core.sh"
ADAPT="$BATS_TEST_DIRNAME/fixtures/receipts/adapttable/punch-list.md"

pulse() {
  bash -c '. "$1"; . "$2"; ns_pulse_receipts_notice "$3/.nightshift" "$3"' _ "$LIB" "$PULSE" "$1"
}

due() {
  bash -c '. "$1"; . "$2"; ns_pulse_report_due "$3/.nightshift" "$3"' _ "$LIB" "$PULSE" "$1"
}

armed() {
  : >"$1/.nightshift/.shift-armed"
}

@test "item start fires once when the open item changes" {
  p="$(new_project pulse-start-once)"
  printf '## Items\n- [ ] **36. First of the replay.**\n' >"$p/.nightshift/punch-list.md"
  armed "$p"
  run pulse "$p"
  [ "$status" -eq 0 ]
  [[ "$output" == *'receipts: item 36. First of the replay. started — open .nightshift/receipts/36-first-of-the-replay.md with one paragraph on the approach; sections: What was delivered · Why · Tried and rejected · Verification · Outputs · Parked decisions and snags.'* ]]
  run pulse "$p"
  [[ "$output" != *'started —'* ]]
}

@test "an owner template replaces the sections clause" {
  p="$(new_project pulse-template)"
  printf '## Items\n- [ ] **36. First of the replay.**\n' >"$p/.nightshift/punch-list.md"
  armed "$p"
  jq '.receipts.templatePath = "notes/item.md"' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.next"
  mv "$p/.nightshift/rules.next" "$p/.nightshift/rules.json"
  run pulse "$p"
  [[ "$output" == *"follow the owner's template at notes/item.md"* ]]
  [[ "$output" != *'sections: What was delivered'* ]]
}

@test "cadence text names the item and file, and a stale marker is rewritten" {
  p="$(new_project pulse-cadence)"
  printf '## Items\n- [x] **37. Second of the replay.**\n- [ ] **38. Third of the replay.**\n' \
    >"$p/.nightshift/punch-list.md"
  armed "$p"
  mkdir -p "$p/.nightshift/usage"
  now="$(date +%s)"
  printf '%s\tarm\t\n' "$((now - 25 * 60))" >"$p/.nightshift/usage/marks.tsv"
  printf 'receipts: progress update due for 37. Second of the replay. — refresh the progress paragraph in .nightshift/receipts/37-second-of-the-replay.md: where it stands, what is left.\n' \
    >"$p/.nightshift/.receipt-due"
  run due "$p"
  [ "$status" -eq 0 ]
  [[ "$output" == *'progress update due for 38. Third of the replay.'* ]]
  [[ "$output" == *'.nightshift/receipts/38-third-of-the-replay.md'* ]]
  [[ "$output" != *'37. Second of the replay.'* ]]
}

@test "tick injection names each newly ticked item once" {
  p="$(new_project pulse-tick)"
  printf '## Items\n- [ ] **36. First of the replay.**\n- [ ] **37. Second of the replay.**\n' \
    >"$p/.nightshift/punch-list.md"
  armed "$p"
  run pulse "$p"
  printf '## Items\n- [x] **36. First of the replay.**\n- [ ] **37. Second of the replay.**\n' \
    >"$p/.nightshift/punch-list.md"
  run pulse "$p"
  [ "$status" -eq 0 ]
  [[ "$output" == *'receipts: item 36. First of the replay. is ticked — write its closing paragraph in .nightshift/receipts/36-first-of-the-replay.md now, before starting the next item.'* ]]
  run pulse "$p"
  [[ "$output" != *'36. First of the replay. is ticked'* ]]
}

@test "no injection when receipts are disabled" {
  p="$(new_project pulse-off)"
  printf '## Items\n- [ ] **36. First of the replay.**\n' >"$p/.nightshift/punch-list.md"
  armed "$p"
  jq '.receipts.enabled = false' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.next"
  mv "$p/.nightshift/rules.next" "$p/.nightshift/rules.json"
  run pulse "$p"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "clock-out lists ticked receipts that have no model text" {
  p="$(new_project pulse-clock-out)"
  printf '## Items\n- [x] **36. First of the replay.**\n- [x] **37. Second of the replay.**\n- [ ] **38. Third of the replay.**\n' \
    >"$p/.nightshift/punch-list.md"
  mkdir -p "$p/.nightshift/receipts"
  printf '# 36. First of the replay.\n\n**Usage:** input 1\n**Duration:** 1m\n' \
    >"$p/.nightshift/receipts/36-first-of-the-replay.md"
  printf '# 37. Second of the replay.\n\nWrote the closing paragraph.\n' \
    >"$p/.nightshift/receipts/37-second-of-the-replay.md"
  run bash -c '. "$1"; . "$2"; ns_gate_receipts_missing_note "$3"' _ "$LIB" "$CORE" "$p"
  [ "$output" = 'Receipts missing model text: 36' ]
}

@test "AdaptTable replay: seven ticks, seven files, no repeated cadence line" {
  p="$(new_project pulse-adapttable)"
  cp "$ADAPT" "$p/.nightshift/punch-list.md"
  armed "$p"
  ticks=""
  cadence_seen=""
  i=36
  while [ "$i" -le 42 ]; do
    awk -v n="$i" '
      BEGIN { done=0 }
      /^- \[ \] \*\*/ && !done {
        line=$0
        if (index(line, n ".") > 0) { sub(/^- \[ \]/, "- [x]"); done=1 }
      }
      { print }
    ' "$p/.nightshift/punch-list.md" >"$p/.nightshift/punch-list.next"
    mv "$p/.nightshift/punch-list.next" "$p/.nightshift/punch-list.md"
    run pulse "$p"
    tick_lines="$(printf '%s\n' "$output" | grep -c 'is ticked' || true)"
    [ "$tick_lines" -eq 1 ]
    file="$(printf '%s\n' "$output" | sed -n 's/.*receipts\/\([^ ]*\.md\).*/\1/p' | head -n1)"
    case "$ticks" in
      *"$file"*) echo "repeated tick file $file"; return 1 ;;
    esac
    ticks="$ticks $file"
    printf '%s\n' "$output" | grep 'progress update due' | while IFS= read -r cad; do
      case "$cadence_seen" in
        *"|$cad|"*) echo "repeated cadence: $cad"; return 1 ;;
      esac
      cadence_seen="$cadence_seen|$cad|"
    done
    i=$((i + 1))
  done
  [ "$(printf '%s' "$ticks" | wc -w | tr -d ' ')" -eq 7 ]
}
