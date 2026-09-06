load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
SETUP="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/setup/SKILL.md"
START="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/start/SKILL.md"
STATUS="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/status/SKILL.md"
DOCTOR_SKILL="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/doctor/SKILL.md"
ARCHIVE="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/archive/SKILL.md"
SCHEDULE="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/schedule/SKILL.md"
DOCTOR="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"
WIN_DOCTOR="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/doctor.ps1"
DOC="$BATS_TEST_DIRNAME/../docs/how-it-works.md"
VOCAB="$BATS_TEST_DIRNAME/../docs/vocabulary.md"
HARDHAT="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/hardhat-core.sh"
WIN_HARDHAT="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/hardhat.ps1"
PSM1="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"

call_lib() {
  bash -c '. "$1"; '"$2"'' _ "$LIB" "$@"
}

@test "scratch paths are detected by prefix" {
  run bash -c '. "$1"; ns_is_scratch_path /workspace/scratch' _ "$LIB"
  [ "$status" -eq 0 ]
  run bash -c '. "$1"; ns_is_scratch_path /workspace/scratch/tmp/proj' _ "$LIB"
  [ "$status" -eq 0 ]
  run bash -c '. "$1"; ns_is_scratch_path /Users/me/notes' _ "$LIB"
  [ "$status" -eq 1 ]
}

@test "missing work-mode defaults to repository" {
  p="$(new_project mode-default)"
  run bash -c '. "$1"; ns_work_mode "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ "$output" = repository ]
}

@test "a non-git folder is proposed as artifact and persists without Git" {
  w="$BATS_TEST_TMPDIR/notes-only"
  mkdir -p "$w/research"
  printf 'notes\n' >"$w/research/topic.md"
  run bash -c '. "$1"; ns_propose_work_mode "$2"' _ "$LIB" "$w"
  [ "$status" -eq 0 ]
  [ "$output" = artifact ]

  run bash -c '. "$1"; ns_record_work_target "$2" "$3" artifact' _ "$LIB" "$w" "$w"
  [ "$status" -eq 0 ]
  [ "$(cat "$w/.nightshift/work-mode")" = artifact ]
  expected="$(cd -P "$w" && pwd)"
  [ "$(cat "$w/.nightshift/work-target")" = "$expected" ]

  run bash -c '. "$1"; ns_work_mode "$2"' _ "$LIB" "$w"
  [ "$output" = artifact ]
  run bash -c '. "$1"; ns_work_target "$2"' _ "$LIB" "$w"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "repository persistence still requires Git and writes the mode" {
  p="$(new_project mode-repo)"
  run bash -c '. "$1"; ns_propose_work_mode "$2"' _ "$LIB" "$p"
  [ "$output" = repository ]
  run bash -c '. "$1"; ns_record_work_target "$2" "$3"' _ "$LIB" "$p" "$p"
  [ "$status" -eq 0 ]
  [ "$(cat "$p/.nightshift/work-mode")" = repository ]
  run bash -c '. "$1"; ns_work_target "$2"' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  [ "$output" = "$(git -C "$p" rev-parse --show-toplevel)" ]
}

@test "artifact record refuses a scratch path" {
  run bash -c '. "$1"; ns_record_work_target /workspace/scratch /workspace/scratch artifact' _ "$LIB"
  [ "$status" -eq 3 ]
}

@test "malformed work-mode fails closed" {
  p="$(new_project mode-bad)"
  printf 'cloud\n' >"$p/.nightshift/work-mode"
  run bash -c '. "$1"; ns_work_mode "$2"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  run bash -c '. "$1"; ns_work_target "$2"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
}

@test "a symlink work-mode fails closed" {
  p="$(new_project mode-link)"
  printf 'artifact\n' >"$p/.nightshift/mode-plant"
  ln -s mode-plant "$p/.nightshift/work-mode"
  run bash -c '. "$1"; ns_work_mode "$2"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  run bash -c '. "$1"; ns_work_target "$2"' _ "$LIB" "$p"
  [ "$status" -eq 1 ]
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'work mode is malformed; treating the site as unusable until Setup rewrites it'
}

@test "Doctor reports work mode" {
  p="$(new_project mode-doctor)"
  bash -c '. "$1"; ns_record_work_target "$2" "$3"' _ "$LIB" "$p" "$p"
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'work mode repository'
  if printf '%s' "$output" | grep -qF 'work mode is unset; Setup would propose artifact'; then
    return 1
  fi
  if printf '%s' "$output" | grep -qF 'persist the proposed artifact mode with Setup; Doctor does not write work-mode'; then
    return 1
  fi
}

@test "Doctor warns when an unset mode would be proposed as artifact" {
  w="$BATS_TEST_TMPDIR/notes-unset-mode"
  mkdir -p "$w/.nightshift" "$w/research"
  cp "$RULES_TEMPLATE" "$w/.nightshift/rules.json"
  printf 'notes\n' >"$w/research/topic.md"
  run bash "$DOCTOR" --project "$w"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'work mode repository'
  printf '%s' "$output" | grep -qF 'work mode is unset; Setup would propose artifact'
  printf '%s' "$output" | grep -qF 'persist the proposed artifact mode with Setup; Doctor does not write work-mode'
}

@test "Setup Start Status Doctor Archive and Schedule name both modes" {
  grep -qF 'work-mode' "$SETUP"
  grep -qF 'ask before persisting' "$SETUP" || grep -qF 'asks before persisting' "$SETUP"
  grep -qF 'artifact' "$SETUP"
  grep -qF 'work-mode' "$START"
  grep -qF 'artifact' "$START"
  grep -qF 'exists but is not a usable directory' "$START"
  grep -qF 'Setup would propose artifact, refuse to arm and send the owner to Setup' "$START"
  grep -qF 'do not `git init` a notes folder.' "$START"
  grep -qF 'Skip a symlink or reparse child; it is not a nested checkout.' "$SETUP"
  grep -qF 'Never `git init` a notes folder to change an artifact proposal into repository mode.' "$SETUP"
  grep -qF 'Skip a symlink or reparse child; it is not a nested checkout.' "$START"
  grep -qF 'Skip a symlink or reparse child; it is not a nested checkout.' "$DOC"
  grep -qF 'work mode' "$STATUS" || grep -qF 'work-mode' "$STATUS"
  grep -qF 'work mode is unset; Setup would propose artifact' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"
  # Status relays whatever the inspector warns; the wording is the inspector's.
  grep -qF 'Relay every Warning' "$STATUS"
  grep -qF 'work mode is malformed; treating the site as unusable until Setup rewrites it' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"
  grep -qF 'work mode' "$DOCTOR_SKILL" || grep -qF 'work-mode' "$DOCTOR_SKILL"
  grep -qF 'work mode is unset; Setup would propose artifact' "$DOCTOR"
  grep -qF 'work mode is unset; Setup would propose artifact' "$WIN_DOCTOR"
  grep -qF 'work mode is unset; Setup would propose artifact' "$DOCTOR_SKILL"
  grep -qF 'work mode is malformed; treating the site as unusable until Setup rewrites it' "$DOCTOR_SKILL"
  grep -qF 'persist the proposed artifact mode with Setup; Doctor does not write work-mode' "$DOCTOR"
  grep -qF 'persist the proposed artifact mode with Setup; Doctor does not write work-mode' "$WIN_DOCTOR"
  grep -qF 'persist the proposed artifact mode with Setup; Doctor does not write work-mode' "$DOCTOR_SKILL"
  grep -qF 'artifact' "$ARCHIVE"
  grep -qF 'work-mode' "$SCHEDULE" || grep -qF 'artifact' "$SCHEDULE"
  grep -qF 'exists but is not a usable directory' "$SCHEDULE"
  grep -qF 'Setup would propose artifact, refuse to print or install a job' "$SCHEDULE"
}

@test "workspace docs describe artifact mode" {
  grep -qF '### Persistent folder (artifact mode)' "$DOC"
  grep -qF '.nightshift/work-mode' "$DOC"
  grep -qF 'artifact' "$VOCAB"
}

@test "hardhat treats work-mode as a control file" {
  grep -qF 'work-mode' "$HARDHAT"
  grep -qF 'work-mode' "$WIN_HARDHAT"
}

@test "Windows helpers persist and resolve the same two modes" {
  grep -qF 'function Get-NSWorkMode' "$PSM1"
  grep -qF 'function Get-NSProposedWorkMode' "$PSM1"
  grep -qF "ValidateSet('repository', 'artifact')" "$PSM1"
  grep -qF 'Mode "$WORK_MODE"' "$SETUP"
}

PATHS="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/paths.sh"
GITLIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/git.sh"
LOGIC="$BATS_TEST_DIRNAME/windows/work-mode-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"

planted_repo() {
  local r="$1"
  mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email dev@example.com
  git -C "$r" config user.name tester
  git -C "$r" commit -q --allow-empty -m init
  (cd -P "$r" && pwd)
}

@test "proposed mode skips a symlink child git repository" {
  notes="$BATS_TEST_TMPDIR/notes-symlink-child"
  mkdir -p "$notes/research"
  printf 'notes\n' >"$notes/research/topic.md"
  planted="$(planted_repo "$BATS_TEST_TMPDIR/planted-propose")"
  ln -s "$planted" "$notes/decoy"
  run bash -c '. "$1"; ns_propose_work_mode "$2"' _ "$LIB" "$notes"
  [ "$status" -eq 0 ]
  [ "$output" = artifact ]
}

@test "a real child git repository is still proposed as repository" {
  w="$(new_workspace mode-real-child)"
  run bash -c '. "$1"; ns_propose_work_mode "$2"' _ "$LIB" "$w"
  [ "$status" -eq 0 ]
  [ "$output" = repository ]
}

@test "proposed mode still finds a real child beside a planted symlink" {
  w="$(new_workspace mode-decoy-beside)"
  planted="$(planted_repo "$BATS_TEST_TMPDIR/planted-beside-propose")"
  ln -s "$planted" "$w/decoy"
  run bash -c '. "$1"; ns_propose_work_mode "$2"' _ "$LIB" "$w"
  [ "$status" -eq 0 ]
  [ "$output" = repository ]
}

@test "Windows CI runs the portable work-mode discovery suite" {
  [ -f "$LOGIC" ]
  grep -qF 'work-mode-logic.ps1' "$RUN"
  grep -qF '[ -L "${child%/}" ]' "$PATHS"
  awk '/^ns_work_target\(\)/,/^ns_record_work_target\(\)/' "$GITLIB" | grep -qF '[ -L "${child%/}" ]'
  awk '/^ns_work_target\(\)/,/^ns_record_work_target\(\)/' "$GITLIB" | grep -qF '[ -L "$record" ]'
  if awk '/^repo_root\(\)/,/^ns_work_target\(\)/' "$GITLIB" | grep -qF '[ -L "${child%/}" ]'; then
    return 1
  fi
  awk '/function Get-NSProposedWorkMode/,/^function Resolve-NSWorkspaceRoot/' "$PSM1" | grep -qF 'ReparsePoint'
  awk '/function Resolve-NSWorkTarget/,/^function Write-NSWorkTarget/' "$PSM1" | grep -qF 'ReparsePoint'
  awk '/function Resolve-NSWorkTarget/,/^function Write-NSWorkTarget/' "$PSM1" | grep -qF 'Test-NSReparsePoint $record'
  awk '/^ns_work_mode\(\)/,/^ns_record_work_mode\(\)/' "$PATHS" | grep -qF '[ -L "$record" ]'
  awk '/function Get-NSWorkMode/,/^function Write-NSWorkMode/' "$PSM1" | grep -qF 'Test-NSReparsePoint'
  grep -qF 'symlink work-mode is malformed' "$LOGIC"
  grep -qF 'symlink work-target is unreadable' "$LOGIC"
  grep -qF 'pass -Mode artifact for a notes folder that is not a Git repository' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/setup.ps1"
  grep -qF 'pass -Mode artifact for a notes folder that is not a Git repository' "$SETUP"
  grep -qF 'failed default setup creates no Nightshift directory' "$LOGIC"
  awk '
    /pass -Mode artifact for a notes folder that is not a Git repository/ {
      if (!scaffold) refuse_first = 1
    }
    /New-Item -ItemType Directory -Path \$ns/ { scaffold = 1 }
    END { exit (refuse_first && scaffold ? 0 : 1) }
  ' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/setup.ps1"
}

@test "Windows work-mode discovery logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
