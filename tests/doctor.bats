load helpers

DOCTOR="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"
DOCTOR_PS1="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/doctor.ps1"
SKILL="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/doctor/SKILL.md"
STATUS="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/status/SKILL.md"
LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
CODEX_PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift/.codex-plugin/plugin.json"
PROVISION_FIXTURES="$BATS_TEST_DIRNAME/fixtures/provisioning"

. "$BATS_TEST_DIRNAME/fixtures/provisioning/recover-fixtures.sh"

fingerprint() {
  (cd "$1" && find . \( -type f -o -type l \) -exec cksum {} \; | sort)
}

doctor() {
  bash "$DOCTOR" --project "$1"
}

@test "Doctor is executable and both hosts discover the skill" {
  [ -x "$DOCTOR" ]
  [ -f "$SKILL" ]
  grep -q '^name: doctor$' "$SKILL"
  grep -qE 'ns"? doctor' "$SKILL"
  grep -qF '[safe]' "$SKILL"
  grep -qF '[confirm]' "$SKILL"
  grep -qF '[blocked]' "$SKILL"
  grep -qF 'do not' "$SKILL"
  grep -qF 'write the parking lot or ask' "$SKILL"
  grep -qF 'Offer the classified repairs' "$SKILL"
  grep -qF 'Never perform a repair' "$SKILL" || grep -qF 'change nothing' "$SKILL"
  grep -qF '$NS/.shift-armed' "$SKILL"
  jq -e '.skills == "./skills/"' "$CODEX_PLUGIN" >/dev/null
  [ -d "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/doctor" ]
}

@test "Doctor tells unattended runs to report, never write, confirmation repairs" {
  grep -qF 'report that' "$SKILL"
  grep -qF 'write the parking lot or ask' "$SKILL"
  grep -qF 'the Doctor invocation remains byte-identical' "$SKILL"
}

# The inspectors already say what is wrong in English. Doctor and Status pass those warnings
# through; they do not keep a second copy of the sentence, and they never quietly drop one.
@test "Doctor and Status relay every inspector warning instead of restating it" {
  for f in "$SKILL" "$STATUS"; do
    grep -qF 'is a planted symlink where a marker should be' "$f" \
      || grep -qF 'planted symlink where a marker should be' "$f" \
      || { echo "no symlink-warning meaning: $f"; return 1; }
    grep -qiF 'relay' "$f" || { echo "no relay rule: $f"; return 1; }
    grep -qF 'never re-derive' "$f" || grep -qF 'do not re-derive' "$f" \
      || { echo "no do-not-re-derive rule: $f"; return 1; }
  done
  grep -qE 'ns"? status' "$STATUS"
  grep -qE 'ns"? doctor' "$STATUS"
  grep -qF 'reimplement liveness' "$STATUS"
}

@test "a healthy armed site reports facts and never repairs" {
  p="$(new_project)"
  punch_open "$p"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Nightshift Doctor'
  printf '%s' "$output" | grep -q 'shift is armed'
  printf '%s' "$output" | grep -q 'open=1'
  printf '%s' "$output" | grep -q 'ticked=1'
  printf '%s' "$output" | grep -q 'rules.json is a JSON object'
  printf '%s' "$output" | grep -q 'watchMinutes 10'
  printf '%s' "$output" | grep -q '\[blocked\] Doctor never repairs'
  printf '%s' "$output" | grep -q 'Actions (Doctor does not perform these)'
}

@test "doctor warns when watchman recovery keys are empty" {
  p="$(new_project)"
  python3 -c '
import json,sys
p=sys.argv[1]
with open(p) as f: d=json.load(f)
d["watchRetrySeconds"]=""
d["revivalPrompt"]=""
d["freshRevivalPrompt"]=""
with open(p,"w") as f: json.dump(d,f)
' "$p/.nightshift/rules.json"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'watchRetrySeconds is empty'
  printf '%s' "$output" | grep -q 'revivalPrompt is empty'
  printf '%s' "$output" | grep -q 'freshRevivalPrompt is empty'
  printf '%s' "$output" | grep -q 'watchman will refuse to arm'
  printf '%s' "$output" | grep -q 'restore revivalPrompt from the shipped template'
}

@test "Doctor reports lease ownership without printing its capability" {
  p="$(new_project)"
  punch_open "$p"
  printf 'shift-session\n\n\n\nclaude\n' >"$p/.nightshift/.shift-session"
  claim="$(bash -c '. "$1"; ns_lease_takeover "$2/.nightshift" shift-session claude' \
    nightshift "$LIB" "$p")"
  nonce="${claim#* }"

  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Lease:       valid (generation'
  printf '%s' "$output" | grep -q 'watchman recovery (capability not printed)'
  if printf '%s' "$output" | grep -qF "$nonce"; then
    return 1
  fi
}

@test "invoking Doctor alone changes no state" {
  p="$(new_project)"
  punch_open "$p"
  printf '99999\n' >"$p/.nightshift/.watchman"
  : >"$p/.nightshift/STOP"
  before="$(fingerprint "$p")"
  run doctor "$p"
  [ "$status" -eq 0 ]
  after="$(fingerprint "$p")"
  [ "$before" = "$after" ]
  [ -f "$p/.nightshift/.shift-armed" ]
  [ -f "$p/.nightshift/STOP" ]
  [ "$(cat "$p/.nightshift/.watchman")" = "99999" ]
  [ ! -e "$p/.nightshift/.watch-reason" ]
}

@test "missing setup is a confirmation offer, not a repair" {
  empty="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$empty"
  run doctor "$empty"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Nightshift:  missing'
  printf '%s' "$output" | grep -q '\[confirm\]'
  printf '%s' "$output" | grep -q 'run Nightshift setup'
  [ ! -d "$empty/.nightshift" ]
}

@test "an invalid link fails closed and offers confirmation" {
  host="$(new_project host)"
  printf 'relative/path\n' >"$host/.nightshift-link"
  before="$(fingerprint "$host")"
  run doctor "$host"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Link:        invalid'
  printf '%s' "$output" | grep -q 'invalid .nightshift-link'
  printf '%s' "$output" | grep -q '\[confirm\].*link-workspace.sh'
  printf '%s' "$output" | grep -q '/runtime/link-workspace.sh'
  if printf '%s' "$output" | grep -q 'using runtime/link-workspace.sh'; then
    return 1
  fi
  after="$(fingerprint "$host")"
  [ "$before" = "$after" ]
}

@test "a valid link diagnoses the workspace, not the task root" {
  host="$(new_project host)"
  rm -rf "$host/.nightshift"
  workspace="$(new_project workspace)"
  punch_open "$workspace"
  bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/link-workspace.sh" \
    --host-root "$host" --workspace "$workspace" >/dev/null
  run doctor "$host"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Link:        valid'
  printf '%s' "$output" | grep -qF "Workspace:   $(cd -P "$workspace" && pwd)"
  printf '%s' "$output" | grep -q 'open=1'
  if printf '%s' "$output" | grep -q 'no .nightshift/'; then
    return 1
  fi
}

@test "broken rules are a warning, not a rewrite" {
  p="$(new_project)"
  printf '{not json\n' >"$p/.nightshift/rules.json"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'unreadable or not a JSON object'
  printf '%s' "$output" | grep -q '\[confirm\].*rules.json'
  grep -q '{not json' "$p/.nightshift/rules.json"
}

@test "missing native question rules are reported without an invented fallback" {
  p="$(new_project)"
  jq 'del(.toolDeny.request_user_input)' "$p/.nightshift/rules.json" >"$p/rules.tmp"
  mv "$p/rules.tmp" "$p/.nightshift/rules.json"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'toolDeny.request_user_input is missing'
  printf '%s' "$output" | grep -q '\[confirm\].*request_user_input'
  if jq -e '.toolDeny | has("request_user_input")' "$p/.nightshift/rules.json" >/dev/null; then
    return 1
  fi
}

@test "stale unarmed watchman pid is classified safe automatic" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '99999\n' >"$p/.nightshift/.watchman"
  punch_open "$p"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'watchman pid 99999 is stale'
  printf '%s' "$output" | grep -q '\[safe\].*leftover .watchman'
  [ -f "$p/.nightshift/.watchman" ]
}

@test "empty punch list reports leftover contract without rewriting it" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '## Shift contract\n- leftover campaign\n\n## Gates\n- none\n\n## Items\n\n' \
    >"$p/.nightshift/punch-list.md"
  before="$(fingerprint "$p")"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'leftover Shift contract and Gates'
  printf '%s' "$output" | grep -q 'empty punch list will inherit the current contract'
  printf '%s' "$output" | grep -q '\[confirm\].*review punch-list.md contract'
  after="$(fingerprint "$p")"
  [ "$before" = "$after" ]
  grep -q 'leftover campaign' "$p/.nightshift/punch-list.md"
}

@test "Doctor reports a missing deadline as none" {
  p="$(new_project)"
  punch_open "$p"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'deadline=none'
}

@test "Doctor reports remaining seconds for a UNIX epoch deadline" {
  p="$(new_project)"
  punch_open "$p"
  future="$(( $(date +%s) + 3600 ))"
  printf '%s' "$future" >"$p/.nightshift/deadline"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "deadline=$future remaining="
  if printf '%s' "$output" | grep -q 'deadline is not a UNIX epoch'; then
    return 1
  fi
}

@test "Doctor reports elapsed when the UNIX epoch deadline is past" {
  p="$(new_project)"
  punch_open "$p"
  past="$(( $(date +%s) - 60 ))"
  printf '%s' "$past" >"$p/.nightshift/deadline"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "deadline=$past remaining=0s (elapsed)"
}

@test "Doctor warns when the deadline is not a UNIX epoch" {
  p="$(new_project)"
  punch_open "$p"
  printf '2026-08-27T08:45:56+04:00\n' >"$p/.nightshift/deadline"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'deadline is not a UNIX epoch'
  if printf '%s' "$output" | grep -q 'deadline=none'; then
    return 1
  fi
}

@test "Doctor warns when the deadline path is a symlink" {
  p="$(new_project)"
  punch_open "$p"
  echo $(($(date +%s) - 60)) >"$p/.nightshift/deadline-plant"
  ln -s deadline-plant "$p/.nightshift/deadline"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'deadline path is not a usable file'
  if printf '%s' "$output" | grep -q 'deadline=none'; then
    return 1
  fi
  if printf '%s' "$output" | grep -q 'remaining=0s'; then
    return 1
  fi
  grep -qF 'deadline path is not a usable file' "$DOCTOR"
  grep -qF 'deadline path is not a usable file' "$DOCTOR_PS1"
}

@test "Doctor warns when the ended path is a symlink" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/ended-plant"
  ln -s ended-plant "$p/.nightshift/.ended"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'ended path is not a usable file'
  if printf '%s' "$output" | grep -qF 'gate has clocked the shift out'; then
    return 1
  fi
  grep -qF 'ended path is not a usable file' "$DOCTOR"
  grep -qF 'ended path is not a usable file' "$DOCTOR_PS1"
}

@test "Doctor warns when the stall path is a symlink" {
  p="$(new_project)"
  punch_open "$p"
  printf 'fp\n99\n' >"$p/.nightshift/stall-plant"
  ln -s stall-plant "$p/.nightshift/.stall"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'stall path is not a usable file'
  if printf '%s' "$output" | grep -qF 'stall count'; then
    return 1
  fi
  grep -qF 'stall path is not a usable file' "$DOCTOR"
  grep -qF 'stall path is not a usable file' "$DOCTOR_PS1"
}

@test "Doctor warns when the session-end path is a symlink" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/session-end-plant"
  ln -s session-end-plant "$p/.nightshift/.session-end"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'session-end path is not a usable file'
  if printf '%s' "$output" | grep -qF 'clean session-end marker is present'; then
    return 1
  fi
  grep -qF 'session-end path is not a usable file' "$DOCTOR"
  grep -qF 'session-end path is not a usable file' "$DOCTOR_PS1"
}

@test "Doctor warns when the shift-pulse path is a symlink" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/pulse-plant"
  ln -s pulse-plant "$p/.nightshift/.shift-pulse"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'shift-pulse path is not a usable file'
  if printf '%s' "$output" | grep -qF 'shift-pulse marker is present'; then
    return 1
  fi
  grep -qF 'shift-pulse path is not a usable file' "$DOCTOR"
  grep -qF 'shift-pulse path is not a usable file' "$DOCTOR_PS1"
}

@test "Doctor warns when the shift-session path is a symlink" {
  p="$(new_project)"
  punch_open "$p"
  printf 'planted-sid\n/tmp/planted.jsonl\n99999\nstart\nplanted-host\n' >"$p/.nightshift/session-plant"
  ln -s session-plant "$p/.nightshift/.shift-session"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'shift-session path is not a usable file'
  if printf '%s' "$output" | grep -qF 'recorded host planted-host'; then
    return 1
  fi
  if printf '%s' "$output" | grep -qF 'session id is present'; then
    return 1
  fi
  if printf '%s' "$output" | grep -qF 'no .shift-session yet'; then
    return 1
  fi
  grep -qF 'shift-session path is not a usable file' "$DOCTOR"
  grep -qF 'shift-session path is not a usable file' "$DOCTOR_PS1"
}

@test "Doctor warns when the watchman pidfile path is a symlink" {
  p="$(new_project)"
  punch_open "$p"
  printf '%s\n' "$$" >"$p/.nightshift/watchman-plant"
  ln -s watchman-plant "$p/.nightshift/.watchman"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'watchman pidfile path is not a usable file'
  if printf '%s' "$output" | grep -qF 'no live watchman pid file'; then
    return 1
  fi
  grep -qF 'watchman pidfile path is not a usable file' "$DOCTOR"
  grep -qF 'watchman pidfile path is not a usable file' "$DOCTOR_PS1"
}

@test "Doctor names a failed terminal clock-out and the restored interactive lease" {
  p="$(new_project)"
  punch_open "$p"
  printf 'clock-out-failed\n\n' >"$p/.nightshift/.watch-reason"
  printf 'shift-session\nclaude\n2\n\n\n\n' >"$p/.nightshift/.shift-lease"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'terminal clock-out failed without releasing the shift'
  printf '%s' "$output" | grep -qF 'process lease restored to the interactive shift; the recorded conversation can operate'
  grep -qF 'terminal clock-out failed without releasing the shift' "$DOCTOR"
  grep -qF 'terminal clock-out failed without releasing the shift' "$DOCTOR_PS1"
}

@test "Doctor does not tell the owner to reopen while a recovery worker is alive" {
  p="$(new_project)"
  punch_open "$p"
  printf 'clock-out-failed\n\n' >"$p/.nightshift/.watch-reason"
  printf 'shift-session\n\n%s\n\nclaude\n' "$$" >"$p/.nightshift/.shift-session"
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'shift-session\nclaude\n2\nnonce1\n%s\n%s\n' "$$" "$start" >"$p/.nightshift/.shift-lease"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'terminal clock-out failed without releasing the shift'
  printf '%s' "$output" | grep -qF 'recovery worker is alive; the recorded conversation cannot reclaim yet'
  printf '%s' "$output" | grep -qF 'reopening the recorded conversation stays blocked'
  if printf '%s' "$output" | grep -qF 'the recorded conversation can operate'; then
    return 1
  fi
}

@test "Doctor names a dead recovery attempt as reclaimable by the recorded conversation" {
  p="$(new_project)"
  punch_open "$p"
  printf 'shift-session\n\n%s\n\nclaude\n' "$$" >"$p/.nightshift/.shift-session"
  printf 'shift-session\nclaude\n2\nnonce1\n%s\n2000-01-01\n' "$$" >"$p/.nightshift/.shift-lease"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "lease held by a dead recovery attempt (generation 2, pid $$); the recorded conversation reclaims it on its next tool call"
  if printf '%s' "$output" | grep -qF 'recovery worker is alive'; then
    return 1
  fi
}

@test "the drafting-table item-shape example is not a staged draft" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  cp "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/templates/drafting-table.md" \
    "$p/.nightshift/drafting-table.md"
  printf '## Items\n\n' >"$p/.nightshift/punch-list.md"
  run doctor "$p"
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -q 'staged drafting-table items='; then
    return 1
  fi
}

@test "drafting-table items after the rule are counted" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '## Items\n\n' >"$p/.nightshift/punch-list.md"
  cat >"$p/.nightshift/drafting-table.md" <<'EOF'
# Drafting Table

```text
- [ ] **1. example only.**
```

---

- [ ] **Real draft.**
  - Verify: true
  - Commit: `fix: x`
EOF
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'staged drafting-table items=1'
  printf '%s' "$output" | grep -q '\[confirm\].*drafting-table items'
}

@test "pending Hunt work orders are counted when the punch list is empty" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '## Items\n\n' >"$p/.nightshift/punch-list.md"
  printf '# Work Orders\n\n## Work order — test\nHours: 2\n\n- [ ] **Coverage hunt.**\n' \
    >"$p/.nightshift/work-orders.md"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'pending Hunt work orders=1'
  printf '%s' "$output" | grep -q '\[confirm\].*promote a parked Hunt order'
}

@test "leftover STOP while unarmed requires owner confirmation" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  : >"$p/.nightshift/STOP"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'STOP leftover'
  printf '%s' "$output" | grep -q '\[confirm\].*stale STOP'
}

@test "a non-resumable Codex identity is blocked, never printed" {
  p="$(new_project)"
  punch_open "$p"
  printf 'thread_abc\n/tmp/rollout.jsonl\n\n\ncodex\n' >"$p/.nightshift/.shift-session"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'recorded host codex'
  printf '%s' "$output" | grep -q 'Codex identity kind unsupported'
  printf '%s' "$output" | grep -q '\[blocked\].*resumable Codex session id'
  if printf '%s' "$output" | grep -q 'thread_abc'; then
    return 1
  fi
}

@test "a resumable Codex identity is reported without printing the id" {
  p="$(new_project)"
  sid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
  printf '%s\n\n\n\ncodex\n' "$sid" >"$p/.nightshift/.shift-session"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Codex identity kind resumable'
  if printf '%s' "$output" | grep -q "$sid"; then
    return 1
  fi
}

@test "Doctor renders a recorded watchman reason without transcript content" {
  p="$(new_project)"
  printf 'owner-stop\nnever paste a prompt here\n' >"$p/.nightshift/.watch-reason"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'watchman reason owner-stop (owner stop-work order)'
  if printf '%s' "$output" | grep -q 'never paste a prompt'; then
    return 1
  fi
}

@test "paths with spaces are diagnosed read-only" {
  p="$BATS_TEST_TMPDIR/site with spaces"
  mkdir -p "$p/.nightshift"
  cp "$RULES_TEMPLATE" "$p/.nightshift/rules.json"
  : >"$p/.nightshift/.shift-armed"
  punch_open "$p"
  git -C "$p" init -q
  git -C "$p" config user.email dev@example.com
  git -C "$p" config user.name tester
  git -C "$p" commit -q --allow-empty -m init
  before="$(fingerprint "$p")"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'site with spaces'
  after="$(fingerprint "$p")"
  [ "$before" = "$after" ]
}

@test "docs expose Doctor as a read-only command" {
  grep -qF '/nightshift:doctor' "$BATS_TEST_DIRNAME/../docs/commands.md"
  grep -qF 'never repairs' "$BATS_TEST_DIRNAME/../docs/commands.md"
  grep -qF '/nightshift:doctor' "$BATS_TEST_DIRNAME/../docs/troubleshooting.md"
  grep -qF '/nightshift:doctor' "$BATS_TEST_DIRNAME/../docs/how-it-works.md"
  grep -qF 'never repairs' "$BATS_TEST_DIRNAME/../docs/how-it-works.md"
  grep -qE 'ns"? export-support' "$BATS_TEST_DIRNAME/../docs/commands.md"
}

@test "doctor and export-support call the policy resolver, never the legacy helper" {
  EXPORT="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/export-support.sh"
  if grep -qE 'capability-policy\.(py|sh)' "$DOCTOR" "$EXPORT"; then
    return 1
  fi
  grep -qF 'ns_policy_resolve_table' "$DOCTOR"
}

@test "Doctor reports evidence counts and lifecycle facts" {
  p="$(new_project doc-evidence)"
  mkdir -p "$p/.nightshift/evidence"
  printf '{"schemaVersion":1,"id":"f1","domain":"test","severity":"low","confidence":"medium","impact":"local","status":"open","ladder":"declared","locator":"x","source":"fixture","sourceClass":"test","host":"local"}\n' \
    >"$p/.nightshift/evidence/findings.jsonl"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'evidence findings=1'
  printf '%s' "$output" | grep -qF 'last checkpoint none'
  printf '%s' "$output" | grep -qF 'stall attempts'
}

@test "Doctor prints the resolved policy block between Facts and Warnings" {
  p="$(new_project)"
  punch_open "$p"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'resolved policy'
  printf '%s' "$output" | grep -qF 'verificationLevel=none (built-in, -)'
  printf '%s' "$output" | grep -qF 'toolingPolicy=existing-tools (built-in, -)'
  printf '%s' "$output" | grep -qF 'deadlineEpoch=null (built-in, -)'
  printf '%s' "$output" | grep -qF 'elevation.sudo=deny (rules, permanent)'
  printf '%s' "$output" | grep -qF 'elevation.containers=deny (rules, permanent)'
  printf '%s' "$output" | grep -qF 'watchMinutes=10 (rules, permanent)'
  printf '%s' "$output" | grep -qF 'stallMax=0 (rules, permanent)'
  # order: Facts, then resolved policy, then Warnings.
  facts_line="$(printf '%s\n' "$output" | grep -n '^Facts$' | cut -d: -f1)"
  policy_line="$(printf '%s\n' "$output" | grep -n '^resolved policy$' | cut -d: -f1)"
  warn_line="$(printf '%s\n' "$output" | grep -n '^Warnings$' | cut -d: -f1)"
  [ "$facts_line" -lt "$policy_line" ]
  [ "$policy_line" -lt "$warn_line" ]
}

@test "the missing-setup report still carries an empty resolved policy section" {
  empty="$BATS_TEST_TMPDIR/policy-empty"
  mkdir -p "$empty"
  run doctor "$empty"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'resolved policy'
}

@test "Doctor warns when shift-policy.json is malformed, names the field, and still resolves built-in plus rules" {
  p="$(new_project)"
  punch_open "$p"
  printf '{"schemaVersion":1}\n' >"$p/.nightshift/shift-policy.json"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'shift-policy.json is malformed (shiftId is missing); the shift resolves to built-in defaults and rules only'
  printf '%s' "$output" | grep -q '\[confirm\].*repair the named field in shift-policy.json'
  printf '%s' "$output" | grep -qF 'verificationLevel=none (built-in, -)'
}

@test "Doctor warns when the deadline file disagrees with the shift-policy deadlineEpoch" {
  p="$(new_project)"
  punch_open "$p"
  file_deadline=$(( $(date +%s) + 3600 ))
  policy_deadline=$(( $(date +%s) + 7200 ))
  printf '%s' "$file_deadline" >"$p/.nightshift/deadline"
  printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z","source":"composition","deadlineEpoch":%s,"verificationLevel":"final","toolingPolicy":"existing-tools"}\n' \
    "$policy_deadline" >"$p/.nightshift/shift-policy.json"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "deadline file $file_deadline does not match shift-policy deadlineEpoch $policy_deadline; the gate honours the earlier value"
  printf '%s' "$output" | grep -q '\[confirm\].*synchronize the deadline projection'
}

@test "Doctor reports preflight gaps without refusing" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '## Items\n- [ ] **1. run docker compose up for local services.**\n' >"$p/.nightshift/punch-list.md"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'preflight: 1 open items, 1 with gaps'
  printf '%s' "$output" | grep -qF 'gaps: containers (item 1)'
}

@test "identity helpers classify Codex session shapes" {
  run bash -c '. "$1"
    ns_codex_identity_kind ""
    echo
    ns_codex_identity_kind "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    echo
    ns_codex_identity_kind "deadbeefdeadbeefdeadbeefdeadbeef"
    echo
    ns_codex_identity_kind "thread_abc"
    echo
    ns_codex_identity_kind "id with space"
    echo
    ns_codex_identity_kind "/tmp/rollout.jsonl"
  ' _ "$LIB"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | awk 'NR==1{exit $0=="missing"?0:1}'
  printf '%s\n' "$output" | awk 'NR==2{exit $0=="resumable"?0:1}'
  printf '%s\n' "$output" | awk 'NR==3{exit $0=="resumable"?0:1}'
  printf '%s\n' "$output" | awk 'NR==4{exit $0=="unsupported"?0:1}'
  printf '%s\n' "$output" | awk 'NR==5{exit $0=="malformed"?0:1}'
  printf '%s\n' "$output" | awk 'NR==6{exit $0=="malformed"?0:1}'
}

LOGIC="$BATS_TEST_DIRNAME/windows/codex-identity-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"

@test "Windows CI runs the portable Codex identity shape suite" {
  [ -f "$LOGIC" ]
  grep -qF 'codex-identity-logic.ps1' "$RUN"
  grep -qF 'Get-NSCodexIdentityKind' "$LOGIC"
  grep -qF 'thread_abc' "$LOGIC"
  grep -qF 'function Get-NSCodexIdentityKind' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"
}

@test "Windows Codex identity kinds match POSIX when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}

# A provisioning transaction on disk is a diagnosis, not a repair: Doctor prints the recovery
# helper's one line and never settles the transaction.

stalled_provision() { # <project> <stage> — a transaction whose baseline is restorable
  recover_reset
  printf 'owner baseline\n' >"$1/recover-tool.json"
  recover_keep "$1" "$1" recover-tool.json both
  recover_touch recover-tool.json
  printf 'engine rewrote this\n' >"$1/recover-tool.json"
  recover_write_tx "$1" "$1" "$2" false
}

@test "Doctor names a stalled provisioning transaction, its stage, and a provable baseline" {
  p="$(new_project)"
  punch_open "$p"
  stalled_provision "$p" apply
  before="$(fingerprint "$p")"

  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" |
    grep -qF 'provision transaction stage=apply capability=fixture-recover baseline=provable'
  if printf '%s' "$output" | grep -qF 'Start will refuse to arm'; then
    return 1
  fi
  [ "$(fingerprint "$p")" = "$before" ]
}

@test "Doctor warns when a provisioning baseline cannot be proven and offers the repair" {
  p="$(new_project)"
  punch_open "$p"
  stalled_provision "$p" smoke
  printf 'corrupted store\n' >"$(recover_store "$p")/$(recover_blob_id recover-tool.json)"

  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" |
    grep -qF 'provision transaction stage=smoke capability=fixture-recover baseline=unprovable; Start will refuse to arm'
  printf '%s' "$output" |
    grep -qF '[confirm] inspect .nightshift/provision-transaction.json and provision-baseline/, restore by hand or run provision.sh rollback after fixing the target, then Start again'
}

@test "Doctor names the malformed field in a provisioning transaction" {
  p="$(new_project)"
  punch_open "$p"
  cp "$PROVISION_FIXTURES/recover-malformed-stage.json" \
    "$p/.nightshift/provision-transaction.json"

  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" |
    grep -qF 'provision-transaction.json is malformed (stage); Start will refuse to arm'
  printf '%s' "$output" | grep -qF '[confirm] inspect .nightshift/provision-transaction.json'
}

# ---------------------------------------------------------------------------------------------
# Staged work is only an offer when there is nothing already approved to do. An open checkbox
# under ## Items is the shift — Start says so, and Doctor and Status must not say otherwise.

# staged_site <name> <open-items> <orders> <drafts> — an unarmed site with that much of each.
staged_site() {
  local p open="$2" orders="$3" drafts="$4" j
  p="$(new_project "$1")"
  rm -f "$p/.nightshift/.shift-armed"
  {
    printf '## Items\n\n'
    j=0
    while [ "$j" -lt "$open" ]; do
      j=$((j + 1))
      printf -- '- [ ] **%d. open work the owner approved.**\n' "$j"
    done
    printf -- '- [x] **done already.**\n'
  } >"$p/.nightshift/punch-list.md"
  {
    printf '# Work Orders\n\n'
    j=0
    while [ "$j" -lt "$orders" ]; do
      j=$((j + 1))
      printf '## Work order — parked %d\nHours: 2\n\n- [ ] **Coverage hunt %d.**\n\n' "$j" "$j"
    done
  } >"$p/.nightshift/work-orders.md"
  {
    printf '# Drafting Table\n\n---\n\n'
    j=0
    while [ "$j" -lt "$drafts" ]; do
      j=$((j + 1))
      printf -- '- [ ] **Draft %d.**\n' "$j"
    done
  } >"$p/.nightshift/drafting-table.md"
  printf '%s' "$p"
}

offers_promotion() { # <output>
  printf '%s' "$1" | grep -qE '\[confirm\].*(promote a parked Hunt order|promote agreed drafting-table)'
}

@test "open punch-list work is never interrupted by a draft" {
  p="$(staged_site doc-open-drafts 3 0 2)"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'staged drafting-table items=2'
  printf '%s' "$output" | grep -qF 'staged work is informational while 3 punch-list items are open'
  if offers_promotion "$output"; then
    echo "Doctor offered promotion with open work"
    return 1
  fi
}

@test "open punch-list work is never interrupted by a parked Hunt order" {
  p="$(staged_site doc-open-orders 2 1 0)"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'pending Hunt work orders=1'
  printf '%s' "$output" | grep -qF 'staged work is informational while 2 punch-list items are open'
  if offers_promotion "$output"; then
    echo "Doctor offered promotion with open work"
    return 1
  fi
}

@test "both staged sources together still lose to one open item" {
  p="$(staged_site doc-open-both 1 2 3)"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'pending Hunt work orders=2'
  printf '%s' "$output" | grep -q 'staged drafting-table items=3'
  printf '%s' "$output" | grep -qF 'staged work is informational while 1 punch-list items are open'
  if offers_promotion "$output"; then
    echo "Doctor offered promotion with open work"
    return 1
  fi
}

@test "an all-ticked punch list is free, so staged work is offered again" {
  p="$(staged_site doc-all-ticked 0 1 1)"
  run doctor "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q '\[confirm\].*promote a parked Hunt order'
  printf '%s' "$output" | grep -q '\[confirm\].*promote agreed drafting-table'
  if printf '%s' "$output" | grep -qF 'staged work is informational'; then
    echo "Doctor withheld an offer it should have made"
    return 1
  fi
}

@test "an empty punch list with nothing staged offers no promotion at all" {
  p="$(staged_site doc-empty-nothing 0 0 0)"
  run doctor "$p"
  [ "$status" -eq 0 ]
  if offers_promotion "$output"; then
    echo "Doctor offered promotion with nothing staged"
    return 1
  fi
}

@test "an armed shift is never offered staged work, open or not" {
  p="$(staged_site doc-armed 2 1 1)"
  : >"$p/.nightshift/.shift-armed"
  run doctor "$p"
  [ "$status" -eq 0 ]
  if offers_promotion "$output"; then
    echo "Doctor offered promotion during an armed shift"
    return 1
  fi
  q="$(staged_site doc-armed-done 0 1 1)"
  : >"$q/.nightshift/.shift-armed"
  run doctor "$q"
  [ "$status" -eq 0 ]
  if offers_promotion "$output"; then
    echo "Doctor offered promotion during an armed shift"
    return 1
  fi
}

@test "Start leaves the staged files exactly as they were when work is open" {
  p="$(staged_site doc-start-untouched 2 1 1)"
  before_orders="$(cksum <"$p/.nightshift/work-orders.md")"
  before_drafts="$(cksum <"$p/.nightshift/drafting-table.md")"
  before_punch="$(cksum <"$p/.nightshift/punch-list.md")"
  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/start-preflight.sh" \
    --project "$p" --host claude
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'ok punch-list open=2'
  printf '%s' "$output" | grep -q 'ok staged orders=1 drafts=1'
  [ "$(cksum <"$p/.nightshift/work-orders.md")" = "$before_orders" ]
  [ "$(cksum <"$p/.nightshift/drafting-table.md")" = "$before_drafts" ]
  [ "$(cksum <"$p/.nightshift/punch-list.md")" = "$before_punch" ]
}

@test "Doctor and Status say the same thing about staged work" {
  # Both skills must state the precedence explicitly, so a summary cannot invert it.
  grep -qF 'Staged work is reported, never offered, while the punch list has open items' "$SKILL"
  grep -qF 'informational while items are open' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
  grep -qF 'staged work is informational and nothing else' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
}

@test "the Windows Doctor applies the same condition" {
  grep -qF '$orders -gt 0 -and $armed -eq 0 -and $open -eq 0' "$DOCTOR_PS1"
  grep -qF '$drafts -gt 0 -and $armed -eq 0 -and $open -eq 0' "$DOCTOR_PS1"
  grep -qF 'staged work is informational while $open punch-list items are open' "$DOCTOR_PS1"
}
