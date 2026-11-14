#!/usr/bin/env bats
# Plans: each one a complete punch list in its own file, waiting its turn. The plan room creates and
# lists them, Start counts them, and Status and Doctor report them, the same on both runtimes.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
RUNTIME="$PLUGIN/runtime"

# site <name> — a current-layout workspace, unarmed, with a punch list that has a contract, gates
# and no open item.
site() {
  local p
  p="$(new_project "$1")"
  rm -f "$p/.nightshift/.shift-armed"
  printf '2\n' >"$p/.nightshift/state-version"
  mkdir -p "$p/.nightshift/staging" "$p/.nightshift/run"
  printf '# Punch List\n\n## Contract\n\nWork each item to done.\n\n## Gates\n\n- `make test`\n\n## Items\n\n' \
    >"$p/.nightshift/punch-list.md"
  printf '%s' "$p"
}

plans_dir() { printf '%s/.nightshift/staging/plans' "$1"; }

@test "a new plan copies the punch list's contract and gates under its own title, with no items" {
  p="$(site plans-new)"
  run bash "$RUNTIME/plan-new.sh" --project "$p" --name "Session export"
  [ "$status" -eq 0 ]
  [ "$output" = 'wrote .nightshift/staging/plans/session-export.md' ]
  f="$(plans_dir "$p")/session-export.md"
  [ "$(sed -n 1p "$f")" = '# Punch List — Session export' ]
  grep -qxF 'Work each item to done.' "$f"
  grep -qxF -- '- `make test`' "$f"
  [ "$(tail -n 2 "$f" | head -n 1)" = '## Items' ]
  ! grep -q '^- \[' "$f" || false
}

@test "a plan that already has the name is kept exactly as it is" {
  p="$(site plans-keep)"
  bash "$RUNTIME/plan-new.sh" --project "$p" --name "Dark mode" >/dev/null
  f="$(plans_dir "$p")/dark-mode.md"
  printf -- '- [ ] **1. Theme tokens.**\n' >>"$f"
  before="$(cksum <"$f")"
  run bash "$RUNTIME/plan-new.sh" --project "$p" --name "dark mode"
  [ "$status" -eq 0 ]
  [ "$output" = 'kept .nightshift/staging/plans/dark-mode.md' ]
  [ "$(cksum <"$f")" = "$before" ]
}

@test "a punch list cut from a plan does not pass its plan notes to the next plan" {
  p="$(site plans-notes)"
  printf '# Punch List — Old\n\n## Contract\n\nRules.\n\n## Plan\n\nWhy: the old reason.\n\n## Items\n\n- [x] **1. done.**\n' \
    >"$p/.nightshift/punch-list.md"
  bash "$RUNTIME/plan-new.sh" --project "$p" --name "Next" >/dev/null
  f="$(plans_dir "$p")/next.md"
  grep -qxF 'Rules.' "$f"
  ! grep -qF 'the old reason' "$f" || false
  ! grep -qxF '## Plan' "$f" || false
}

@test "a workspace on the older layout keeps plans in its drafting table and is told how to move" {
  p="$(new_project plans-legacy)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '## Items\n' >"$p/.nightshift/punch-list.md"
  run bash "$RUNTIME/plan-new.sh" --project "$p" --name "Anything"
  [ "$status" -eq 2 ]
  [[ "$output" == *'ns migrate-state moves it to the layout with plan files'* ]] || false
  [ ! -e "$p/.nightshift/staging/plans" ]
}

@test "a name with no letters or digits is refused, and nothing is written" {
  p="$(site plans-empty-name)"
  run bash "$RUNTIME/plan-new.sh" --project "$p" --name "---"
  [ "$status" -eq 1 ]
  [ ! -e "$(plans_dir "$p")" ]
}

@test "entering the plan room lists every plan with its open items, or says there are none" {
  p="$(site plans-enter)"
  run bash "$RUNTIME/plan-enter.sh" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'plan file: none'
  bash "$RUNTIME/plan-new.sh" --project "$p" --name "Session export" >/dev/null
  bash "$RUNTIME/plan-new.sh" --project "$p" --name "Dark mode" >/dev/null
  printf -- '- [ ] **1. Stream it.**\n- [ ] **2. CLI flag.**\n' >>"$(plans_dir "$p")/session-export.md"
  bash "$RUNTIME/plan-exit.sh" --project "$p" >/dev/null 2>&1 || :
  run bash "$RUNTIME/plan-enter.sh" --project "$p"
  printf '%s\n' "$output" | grep -qxF 'plan file: dark-mode · Dark mode · 0 open'
  printf '%s\n' "$output" | grep -qxF 'plan file: session-export · Session export · 2 open'
}

@test "Start counts the waiting plans and offers them when the punch list is empty" {
  p="$(site plans-start)"
  bash "$RUNTIME/plan-new.sh" --project "$p" --name "Session export" >/dev/null
  run bash "$RUNTIME/start-preflight.sh" --project "$p"
  printf '%s\n' "$output" | grep -qF 'ok staged orders=0 drafts=0 plans=1'
  printf '%s\n' "$output" | grep -qF 'warn punch-list empty - offer the staged orders, drafts and plans'
}

@test "Status and Doctor report the waiting plans" {
  p="$(site plans-report)"
  bash "$RUNTIME/plan-new.sh" --project "$p" --name "Session export" >/dev/null
  run bash "$RUNTIME/status.sh" --project "$p"
  printf '%s\n' "$output" | grep -qF 'drafts=0 orders=0 plans=1'
  run bash "$RUNTIME/doctor.sh" --project "$p"
  printf '%s\n' "$output" | grep -qF 'plans waiting=1'
  printf '%s\n' "$output" | grep -qF 'start to choose one of the waiting plans'
}

@test "native Windows writes the same plan file and lists plans the same way" {
  command -v pwsh >/dev/null || skip 'pwsh is not installed'
  p="$(site plans-parity)"
  bash "$RUNTIME/plan-new.sh" --project "$p" --name "Session export" >/dev/null
  run pwsh -NoProfile -File "$RUNTIME/windows/plan-new.ps1" -Project "$p" -Name "Retry budget"
  [ "$status" -eq 0 ]
  [ "$output" = 'wrote .nightshift/staging/plans/retry-budget.md' ]
  diff <(sed 1d "$(plans_dir "$p")/session-export.md") <(sed 1d "$(plans_dir "$p")/retry-budget.md")
  [ "$(sed -n 1p "$(plans_dir "$p")/retry-budget.md")" = '# Punch List — Retry budget' ]
  bash_list="$(bash "$RUNTIME/plan-enter.sh" --project "$p" | grep '^plan file:')"
  bash "$RUNTIME/plan-exit.sh" --project "$p" >/dev/null 2>&1 || :
  ps_list="$(pwsh -NoProfile -File "$RUNTIME/windows/plan-enter.ps1" -Project "$p" | grep '^plan file:')"
  [ "$bash_list" = "$ps_list" ]
}
