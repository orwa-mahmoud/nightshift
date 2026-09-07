load helpers

SCHED="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/schedule.sh"
WIN="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/schedule.ps1"

persist_artifact() {
  printf 'artifact\n' >"$1/.nightshift/work-mode"
}

setup() {
  P="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$P/.nightshift"
  printf '## Items\n- [ ] **1. real work.**\n' >"$P/.nightshift/punch-list.md"
  persist_artifact "$P"
}

@test "refuses a project with no .nightshift" {
  run "$SCHED" --project "$BATS_TEST_TMPDIR" --at 04:05
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF '/nightshift:setup'
  printf '%s' "$output" | grep -qF 'ask Nightshift to set up on Codex'
}

@test "Windows missing-state names Setup like POSIX" {
  grep -qF '/nightshift:setup on Claude Code; ask Nightshift to set up on Codex' "$SCHED"
  grep -qF '/nightshift:setup on Claude Code; ask Nightshift to set up on Codex' "$WIN"
}

@test "an option with no value exits instead of spinning" {
  run "$SCHED" --at
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -q -- '--at needs a value'
}

# A bad time silently accepted becomes a job that never fires, discovered a week later.
@test "a time that is not 24-hour HH:MM is rejected" {
  for t in 25:00 7:30 04:60 "4am" ""; do
    run "$SCHED" --project "$P" --at "$t"
    [ "$status" -eq 1 ] || { echo "accepted bad time: $t"; return 1; }
  done
}

@test "prints config and an install command for a real time" {
  run "$SCHED" --project "$P" --at 04:05
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q '04:05'
  printf '%s' "$output" | grep -qE 'launchctl load|crontab'
  printf '%s' "$output" | grep -q "/nightshift:start"
}

@test "generated entries safely quote spaced paths and escape launchd XML" {
  p="$BATS_TEST_TMPDIR/project with spaces & ampersand"
  mkdir -p "$p/.nightshift"
  persist_artifact "$p"
  printf '## Items\n- [ ] **1. real work.**\n' >"$p/.nightshift/punch-list.md"
  run "$SCHED" --project "$p" --at 04:05 --agent "codex exec -a never"
  [ "$status" -eq 0 ]

  # Every platform prints the shell entry; decode launchd XML before checking the shell source.
  command_line="$(printf '%s\n' "$output" | grep "codex exec -a never" | head -1)"
  if printf '%s' "$command_line" | grep -q '<string>'; then
    printf '%s' "$command_line" | grep -q '&amp;'
    if printf '%s' "$command_line" | grep -q ' & '; then
      return 1
    fi
    command_line="$(printf '%s' "$command_line" | sed 's/^[[:space:]]*<string>//; s#</string>[[:space:]]*$##; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g')"
  else
    command_line="$(printf '%s' "$command_line" | sed 's/^[[:space:]]*[0-9*][0-9*]*[[:space:]][0-9*][0-9*]*[[:space:]]\* \* \*[[:space:]]*//; s/[[:space:]]*# nightshift:.*$//')"
  fi
  printf '%s' "$command_line" | grep -qF "cd '$p'"
  printf '%s' "$command_line" | grep -qF ">> '$p/.nightshift/scheduled.log'"
  bash -n <<<"$command_line"
}

# The generator hands over config; installing is the owner's own command, always.
@test "it registers nothing itself" {
  run "$SCHED" --project "$P" --at 04:05
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/Library/LaunchAgents/com.nightshift.proj"*.plist ] || {
    echo "schedule.sh installed a plist by itself"; return 1; }
}

# A scheduled start works the list it finds and promotes nothing, so an empty list is a run that
# does nothing at all — worth saying before the owner walks away.
@test "warns when the punch list it would work is empty" {
  printf '## Items\n' >"$P/.nightshift/punch-list.md"
  printf '# Work Orders\n\n- [ ] **Coverage hunt.**\n' >"$P/.nightshift/work-orders.md"
  cat >"$P/.nightshift/drafting-table.md" <<'EOF'
```text
- [ ] **1. example only.**
```

---

- [ ] **Real draft.**
EOF
  run "$SCHED" --project "$P" --at 04:05
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qi 'no open items'
  printf '%s' "$output" | grep -q 'Parked Hunt work orders: 1'
  printf '%s' "$output" | grep -q 'Drafting-table items: 1'
}

@test "an open checkbox outside Items is not scheduled work" {
  printf '%s\n' '- [ ] planning example' '## Items' '- [x] **1. done.**' >"$P/.nightshift/punch-list.md"
  run "$SCHED" --project "$P" --at 04:05
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qi 'no open items'
}

@test "list and remove are quiet when nothing is registered" {
  run "$SCHED" --project "$P" --list
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qi 'nothing registered'
  run "$SCHED" --project "$P" --remove
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qi 'nothing registered'
}

# Two scheduled starts on one punch list is two agents on one shift — the failure the shift's own
# one-session rule prevents from the inside, arriving from outside it.
@test "a project already registered is refused a second entry" {
  fake="$BATS_TEST_TMPDIR/fakecron"
  cat >"$BATS_TEST_TMPDIR/bin_crontab" <<STUB
#!/usr/bin/env bash
[ "\$1" = "-l" ] && cat "$fake" 2>/dev/null
exit 0
STUB
  mkdir -p "$BATS_TEST_TMPDIR/bin" && mv "$BATS_TEST_TMPDIR/bin_crontab" "$BATS_TEST_TMPDIR/bin/crontab"
  chmod +x "$BATS_TEST_TMPDIR/bin/crontab"
  # capture the marker this project would use, then pretend it is already installed
  run "$SCHED" --project "$P" --at 04:05
  marker="$(printf '%s' "$output" | grep -o '# nightshift:[A-Za-z0-9-]*' | head -1)"
  if [ -n "$marker" ]; then                 # cron platform
    printf '5 4 * * * true  %s\n' "$marker" >"$fake"
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$SCHED" --project "$P" --at 04:05
    [ "$status" -eq 3 ]
    printf '%s' "$output" | grep -qi 'already registered'
  else                                       # macOS platform
    plist="$(printf '%s' "$output" | grep -o "$HOME/Library/LaunchAgents/com.nightshift.[^ ]*\.plist" | head -1)"
    [ -n "$plist" ]
    touch "$plist"
    run "$SCHED" --project "$P" --at 04:05
    rm -f "$plist"
    [ "$status" -eq 3 ]
    printf '%s' "$output" | grep -qi 'already registered'
  fi
}

# Two checkouts named the same must not share an identity, or one silently blocks the other.
@test "two projects with the same folder name get different ids" {
  a="$BATS_TEST_TMPDIR/a/api"; b="$BATS_TEST_TMPDIR/b/api"
  for d in "$a" "$b"; do
    mkdir -p "$d/.nightshift"
    persist_artifact "$d"
    printf '## Items\n- [ ] **1. work.**\n' >"$d/.nightshift/punch-list.md"
  done
  ida="$("$SCHED" --project "$a" --at 04:05 | grep -o 'com.nightshift.[A-Za-z0-9-]*\|# nightshift:[A-Za-z0-9-]*' | head -1)"
  idb="$("$SCHED" --project "$b" --at 04:05 | grep -o 'com.nightshift.[A-Za-z0-9-]*\|# nightshift:[A-Za-z0-9-]*' | head -1)"
  [ -n "$ida" ] && [ -n "$idb" ] && [ "$ida" != "$idb" ]
}

# The skill is the pleasant path; the script is the one that still works at 100% usage. Both must
# exist, and the skill must do the checks an owner would otherwise fail at 4am.
@test "the schedule skill checks the work is queued before printing config" {
  local s arming
  s="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/schedule/SKILL.md"
  [ -f "$s" ]
  grep -qi 'promotes nothing' "$s"           # an empty list is a run that does nothing
  grep -qF 'Hunt' "$s"                       # and how to fix that
  grep -qF 'Status: proposed' "$s"
  grep -qF -- '--promote' "$s"
  grep -qF -- '--promote' "$s"
  grep -qi 'cannot answer a prompt' "$s"     # headless permissions
  grep -qi 'install nothing' "$s"            # generator, never a daemon
  grep -qF 'exists but is not a usable directory' "$s"
  grep -qF 'Setup would propose artifact, refuse to print or install a job' "$s"

  perms="$(awk '/^## 3\./ { capture=1; next } /^## 4\./ { exit } capture' "$s")"
  printf '%s\n' "$perms" | grep -qF -- "--agent 'codex exec -s danger-full-access'"
  printf '%s\n' "$perms" | grep -qF -- "-Agent 'codex exec -s danger-full-access'"

  arming="$(awk '/^## 4\./ { capture=1; next } /^## 5\./ { exit } capture' "$s")"
  printf '%s\n' "$arming" | grep -qF '.shift-armed'
  printf '%s\n' "$arming" | grep -qi 'do not activate'
  printf '%s\n' "$arming" | grep -qi 'must not create'
  printf '%s\n' "$arming" | grep -qF 'Status'
}

# A README is reachable with no credit; a skill is not. The offline path has to be documented
# where an owner can still read it on the day they need it.
@test "the README documents the offline generator for a session that cannot run" {
  r="$BATS_TEST_DIRNAME/../docs/commands.md"
  grep -qi 'no credit left' "$r"
  grep -qi 'spends no tokens and needs no session' "$r"
  grep -q 'runtime/ns" schedule --at' "$r"
}

@test "native Windows Task Scheduler docs name list and remove" {
  w="$BATS_TEST_DIRNAME/../docs/windows.md"
  block="$(awk '/^## Task Scheduler$/{p=1; next} /^## /{p=0} p' "$w")"
  printf '%s\n' "$block" | grep -qF -- '--list'
  printf '%s\n' "$block" | grep -qF -- '--remove'
  printf '%s\n' "$block" | grep -qF 'work mode is unset; Setup would propose artifact - a scheduled start will refuse to arm'
  printf '%s\n' "$block" | grep -qF 'work target could not be resolved - a scheduled start will refuse to arm'
}

@test "native Windows helper docs name import-issues" {
  w="$BATS_TEST_DIRNAME/../docs/windows.md"
  helpers="$(awk '/^## Doctor and other helpers$/{p=1; next} /^## /{p=0} p' "$w")"
  printf '%s\n' "$helpers" | grep -qE 'ns\.ps1"? import-issues'
  printf '%s\n' "$helpers" | grep -qF -- '--list-proposed'
  grep -qF 'import-issues, apply-profile, and export-support helpers' "$w"
}

@test "native Windows helper docs name migrate-state" {
  w="$BATS_TEST_DIRNAME/../docs/windows.md"
  helpers="$(awk '/^## Doctor and other helpers$/{p=1; next} /^## /{p=0} p' "$w")"
  printf '%s\n' "$helpers" | grep -qE 'ns\.ps1"? migrate-state'
  printf '%s\n' "$helpers" | grep -qF -- '--project'
  grep -qF 'Doctor, migrate-state, retain-history' "$w"
}

@test "native Windows setup docs name the workspace linker" {
  w="$BATS_TEST_DIRNAME/../docs/windows.md"
  setup="$(awk '/^## Setup and start$/{p=1; next} /^## /{p=0} p' "$w")"
  printf '%s\n' "$setup" | grep -qE 'ns\.ps1"? link-workspace'
  printf '%s\n' "$setup" | grep -qF -- '--host-root'
  printf '%s\n' "$setup" | grep -qF -- '--workspace'
}

@test "native Windows rule docs name expected-email and protected-dir matching" {
  w="$BATS_TEST_DIRNAME/../docs/windows.md"
  rules="$(awk '/^## Rule and filesystem details$/{p=1; next} /^## /{p=0} p' "$w")"
  printf '%s\n' "$rules" | grep -qF 'git config user.email'
  printf '%s\n' "$rules" | grep -qF 'expectedEmail'
  printf '%s\n' "$rules" | grep -qF 'protectedDirs'
  printf '%s\n' "$rules" | grep -qF 'normalized to `/`'
  printf '%s\n' "$rules" | grep -qF 'invalid command or commit pattern fails closed'
  printf '%s\n' "$rules" | grep -qF 'fix it in'
}

# One generator serves both hosts: the entry's runner is a parameter, defaulting to Claude's.
@test "--agent swaps the headless runner in the generated entry" {
  p="$BATS_TEST_TMPDIR/proj"; mkdir -p "$p/.nightshift"
  persist_artifact "$p"
  run "$SCHED" --project "$p" --at 04:05 --agent "codex exec -s danger-full-access"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "codex exec -s danger-full-access '/nightshift:start'"
  ! printf '%s' "$output" | grep -qF "claude -p" || false
}

@test "the default runner stays claude -p" {
  p="$BATS_TEST_TMPDIR/proj2"; mkdir -p "$p/.nightshift"
  persist_artifact "$p"
  run "$SCHED" --project "$p" --at 04:05
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "claude -p '/nightshift:start'"
}

@test "--preflight does not require --at" {
  cp "$RULES_TEMPLATE" "$P/.nightshift/rules.json"
  run "$SCHED" --project "$P" --preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Nightshift schedule preflight'
  printf '%s' "$output" | grep -q 'Claude Code'
  printf '%s' "$output" | grep -q 'Codex'
  printf '%s' "$output" | grep -q 'punch list has'
}

@test "--preflight fails when watchman recovery keys are empty" {
  cp "$RULES_TEMPLATE" "$P/.nightshift/rules.json"
  python3 -c '
import json,sys
p=sys.argv[1]
with open(p) as f: d=json.load(f)
d["watchRetrySeconds"]=""
d["revivalPrompt"]=""
d["freshRevivalPrompt"]=""
with open(p,"w") as f: json.dump(d,f)
' "$P/.nightshift/rules.json"
  run "$SCHED" --project "$P" --preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -q 'watchRetrySeconds is empty'
  printf '%s' "$output" | grep -q 'revivalPrompt is empty'
  printf '%s' "$output" | grep -q 'freshRevivalPrompt is empty'
  printf '%s' "$output" | grep -q 'watchman will refuse to arm'
}

@test "Windows schedule preflight names empty watchman recovery keys" {
  grep -qF 'watchRetrySeconds is empty' "$SCHED"
  grep -qF 'revivalPrompt is empty' "$SCHED"
  grep -qF 'freshRevivalPrompt is empty' "$SCHED"
  grep -qF 'watchRetrySeconds is empty' "$WIN"
  grep -qF 'revivalPrompt is empty' "$WIN"
  grep -qF 'freshRevivalPrompt is empty' "$WIN"
}

@test "--preflight fails when artifact receipts path is unusable" {
  cp "$RULES_TEMPLATE" "$P/.nightshift/rules.json"
  printf 'artifact\n' >"$P/.nightshift/work-mode"
  printf '%s\n' "$(cd -P "$P" && pwd)" >"$P/.nightshift/work-target"
  printf 'not-a-dir\n' >"$P/.nightshift/receipts"
  run "$SCHED" --project "$P" --preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'artifact receipts path is not a usable directory'
  printf '%s' "$output" | grep -qF 'a scheduled start will refuse to arm'
}

@test "generate refuses when artifact receipts path is unusable" {
  printf 'artifact\n' >"$P/.nightshift/work-mode"
  printf '%s\n' "$(cd -P "$P" && pwd)" >"$P/.nightshift/work-target"
  printf 'not-a-dir\n' >"$P/.nightshift/receipts"
  run "$SCHED" --project "$P" --at 04:05
  [ "$status" -eq 1 ]
  printf '%s' "$output$stderr" | grep -qF 'artifact receipts path is not a usable directory'
}

@test "Windows schedule names an unusable artifact receipts path" {
  grep -qF 'a scheduled start will refuse to arm' "$SCHED"
  grep -qF 'a scheduled start will refuse to arm' "$WIN"
  grep -qF 'Test-NSUsableReceiptsDir' "$WIN"
  grep -qF 'ns_receipts_usable_dir' "$SCHED"
}

@test "--preflight fails when work mode is unset and Setup would propose artifact" {
  w="$BATS_TEST_TMPDIR/notes-unset-sched"
  mkdir -p "$w/.nightshift" "$w/research"
  cp "$RULES_TEMPLATE" "$w/.nightshift/rules.json"
  printf '## Items\n- [ ] **1. real work.**\n' >"$w/.nightshift/punch-list.md"
  printf 'notes\n' >"$w/research/topic.md"
  run "$SCHED" --project "$w" --preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'work mode is unset; Setup would propose artifact'
  printf '%s' "$output" | grep -qF 'a scheduled start will refuse to arm'
}

@test "generate refuses when work mode is unset and Setup would propose artifact" {
  w="$BATS_TEST_TMPDIR/notes-unset-gen"
  mkdir -p "$w/.nightshift" "$w/research"
  printf '## Items\n- [ ] **1. real work.**\n' >"$w/.nightshift/punch-list.md"
  printf 'notes\n' >"$w/research/topic.md"
  run "$SCHED" --project "$w" --at 04:05
  [ "$status" -eq 1 ]
  printf '%s' "$output$stderr" | grep -qF 'work mode is unset; Setup would propose artifact'
}

@test "Windows schedule names an unset artifact proposal" {
  grep -qF 'work mode is unset; Setup would propose artifact - a scheduled start will refuse to arm' "$SCHED"
  grep -qF 'work mode is unset; Setup would propose artifact - a scheduled start will refuse to arm' "$WIN"
  grep -qF '3 unset artifact proposal' "$SCHED"
  grep -qF '3 unset artifact proposal' "$WIN"
}

@test "--preflight fails when the work target cannot be resolved" {
  p="$(new_project sched-target-link)"
  planted="$BATS_TEST_TMPDIR/planted-sched-target"
  mkdir -p "$planted"
  git -C "$planted" init -q
  git -C "$planted" config user.email dev@example.com
  git -C "$planted" config user.name tester
  git -C "$planted" commit -q --allow-empty -m init
  printf '%s\n' "$(cd -P "$planted" && pwd)" >"$p/.nightshift/target-plant"
  ln -s target-plant "$p/.nightshift/work-target"
  printf '## Items\n- [ ] **1. real work.**\n' >"$p/.nightshift/punch-list.md"
  run "$SCHED" --project "$p" --preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'FAIL work target could not be resolved - a scheduled start will refuse to arm'
}

@test "generate refuses when the work target cannot be resolved" {
  p="$(new_project sched-target-link-gen)"
  planted="$BATS_TEST_TMPDIR/planted-sched-target-gen"
  mkdir -p "$planted"
  git -C "$planted" init -q
  git -C "$planted" config user.email dev@example.com
  git -C "$planted" config user.name tester
  git -C "$planted" commit -q --allow-empty -m init
  printf '%s\n' "$(cd -P "$planted" && pwd)" >"$p/.nightshift/target-plant"
  ln -s target-plant "$p/.nightshift/work-target"
  printf '## Items\n- [ ] **1. real work.**\n' >"$p/.nightshift/punch-list.md"
  run "$SCHED" --project "$p" --at 04:05
  [ "$status" -eq 1 ]
  printf '%s' "$output$stderr" | grep -qF 'work target could not be resolved - a scheduled start will refuse to arm'
}

@test "Windows schedule names an unresolved work target" {
  s="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/schedule/SKILL.md"
  grep -qF 'work target could not be resolved - a scheduled start will refuse to arm' "$SCHED"
  grep -qF 'work target could not be resolved - a scheduled start will refuse to arm' "$WIN"
  grep -qF 'If the work target cannot be resolved, refuse to print or install a job; a scheduled start will refuse to arm.' "$s"
}

@test "--preflight fails closed on an empty punch list" {
  cp "$RULES_TEMPLATE" "$P/.nightshift/rules.json"
  printf '## Items\n' >"$P/.nightshift/punch-list.md"
  run "$SCHED" --project "$P" --preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -q 'no open items'
}

@test "--preflight names parked orders and real drafts when the punch list is empty" {
  cp "$RULES_TEMPLATE" "$P/.nightshift/rules.json"
  printf '## Items\n' >"$P/.nightshift/punch-list.md"
  printf '# Work Orders\n\n- [ ] **Coverage hunt.**\n' >"$P/.nightshift/work-orders.md"
  cat >"$P/.nightshift/drafting-table.md" <<'EOF'
```text
- [ ] **1. example only.**
```

---

- [ ] **Real draft.**
EOF
  run "$SCHED" --project "$P" --preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -q 'NOTE 1 parked Hunt work order'
  printf '%s' "$output" | grep -q 'NOTE 1 drafting-table item'
}

@test "--preflight fails on missing rules" {
  run "$SCHED" --project "$P" --preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -q 'rules.json is missing'
}

@test "--preflight writes no scheduler entries" {
  cp "$RULES_TEMPLATE" "$P/.nightshift/rules.json"
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home/Library/LaunchAgents"
  before="$(find "$home" "$P" -type f | sort)"
  run env HOME="$home" "$SCHED" --project "$P" --preflight
  [ "$status" -eq 0 ]
  after="$(find "$home" "$P" -type f | sort)"
  [ "$before" = "$after" ]
  [ -z "$(find "$home/Library/LaunchAgents" -type f)" ]
}

@test "--preflight covers spaced paths and a linked workspace" {
  ws="$BATS_TEST_TMPDIR/workspace with spaces"
  mkdir -p "$ws/.nightshift"
  persist_artifact "$ws"
  cp "$RULES_TEMPLATE" "$ws/.nightshift/rules.json"
  printf '## Items\n- [ ] **1. real work.**\n' >"$ws/.nightshift/punch-list.md"
  host="$BATS_TEST_TMPDIR/host with spaces"
  mkdir -p "$host"
  bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/link-workspace.sh" \
    --host-root "$host" --workspace "$ws" >/dev/null
  run "$SCHED" --project "$host" --preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Link:      valid'
  printf '%s' "$output" | grep -qF "$ws"
}

@test "--preflight reports a missing agent binary without installing" {
  cp "$RULES_TEMPLATE" "$P/.nightshift/rules.json"
  bindir="$BATS_TEST_TMPDIR/nobin"
  mkdir -p "$bindir"
  for t in bash sh grep sed awk mktemp plutil jq cat uname basename cksum cut git python3 rm; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$bindir/$t"
  done
  run env PATH="$bindir" "$SCHED" --project "$P" --preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'WARN claude is not on PATH'
  printf '%s' "$output" | grep -q 'WARN codex is not on PATH'
}

@test "systemd target prints units and never runs systemctl" {
  p="$BATS_TEST_TMPDIR/unit proj %percent"
  mkdir -p "$p/.nightshift"
  persist_artifact "$p"
  printf '## Items\n- [ ] **1. real work.**\n' >"$p/.nightshift/punch-list.md"
  home="$BATS_TEST_TMPDIR/sdhome"
  mkdir -p "$home"
  run env HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    "$SCHED" --project "$p" --at 04:05 --target systemd --agent "codex exec -s danger-full-access"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q '\[Timer\]'
  printf '%s' "$output" | grep -q 'OnCalendar=\*-\*-\* 04:05:00'
  printf '%s' "$output" | grep -q 'Persistent=true'
  printf '%s' "$output" | grep -q 'Type=oneshot'
  printf '%s' "$output" | grep -q 'codex exec -s danger-full-access'
  printf '%s' "$output" | grep -q '%%percent'
  printf '%s' "$output" | grep -q 'Nightshift runs none'
  printf '%s' "$output" | grep -q 'systemctl --user enable --now'
  if printf '%s' "$output" | grep -q 'After=network'; then
    return 1
  fi
  [ ! -e "$home/.config/systemd/user" ]
}

@test "systemd unit names are deterministic and differ by path" {
  a="$BATS_TEST_TMPDIR/a/api"; b="$BATS_TEST_TMPDIR/b/api"
  for d in "$a" "$b"; do
    mkdir -p "$d/.nightshift"
    persist_artifact "$d"
    printf '## Items\n- [ ] **1. work.**\n' >"$d/.nightshift/punch-list.md"
  done
  ida="$("$SCHED" --project "$a" --at 04:05 --target systemd | sed -n 's/.*nightshift-\([^ ]*\)\.timer.*/\1/p' | head -1)"
  idb="$("$SCHED" --project "$b" --at 04:05 --target systemd | sed -n 's/.*nightshift-\([^ ]*\)\.timer.*/\1/p' | head -1)"
  [ -n "$ida" ] && [ -n "$idb" ] && [ "$ida" != "$idb" ]
  run "$SCHED" --project "$a" --at 04:05 --target systemd
  ida2="$(printf '%s' "$output" | sed -n 's/.*nightshift-\([^ ]*\)\.timer.*/\1/p' | head -1)"
  [ "$ida" = "$ida2" ]
}

@test "systemd generate refuses a second installed unit and invalid targets" {
  p="$BATS_TEST_TMPDIR/sdproj"
  mkdir -p "$p/.nightshift"
  persist_artifact "$p"
  printf '## Items\n- [ ] **1. work.**\n' >"$p/.nightshift/punch-list.md"
  home="$BATS_TEST_TMPDIR/sdhome2"
  run env HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    "$SCHED" --project "$p" --at 04:05 --target systemd
  [ "$status" -eq 0 ]
  unit="$(printf '%s' "$output" | sed -n 's#.*/\(nightshift-[^/]*\)\.timer#\1#p' | head -1)"
  [ -n "$unit" ]
  mkdir -p "$home/.config/systemd/user"
  : >"$home/.config/systemd/user/${unit}.timer"
  run env HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    "$SCHED" --project "$p" --at 04:05 --target systemd
  [ "$status" -eq 3 ]
  run "$SCHED" --project "$p" --at 04:05 --target launchd-please
  [ "$status" -eq 1 ]
}

@test "the schedule skill documents the no-install preflight" {
  s="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/schedule/SKILL.md"
  grep -qF -- '--preflight' "$s"
  grep -qi 'installs nothing' "$s"
  grep -qF -- '--preflight' "$BATS_TEST_DIRNAME/../docs/commands.md"
  grep -qF 'work mode is unset; Setup would propose artifact - a scheduled start will refuse to arm' \
    "$BATS_TEST_DIRNAME/../docs/commands.md"
  grep -qF 'work target could not be resolved - a scheduled start will refuse to arm' \
    "$BATS_TEST_DIRNAME/../docs/commands.md"
}
