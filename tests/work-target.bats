load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
DOCTOR="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"

resolve_target() {
  bash -c '. "$1"; ns_work_target "$2"' _ "$LIB" "$1"
}

@test "workspace repository resolves to itself" {
  p="$(new_project target-self)"
  expected="$(git -C "$p" rev-parse --show-toplevel)"
  run resolve_target "$p"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "parent workspace resolves and persists its single child repository" {
  w="$(new_workspace target-parent)"
  expected="$(git -C "$w/repo" rev-parse --show-toplevel)"
  run resolve_target "$w"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]

  bash -c '. "$1"; ns_record_work_target "$2" "$3"' _ "$LIB" "$w" "$w/repo"
  [ "$(cat "$w/.nightshift/work-target")" = "$expected" ]
}

@test "several child repositories require an explicit persisted target" {
  w="$(new_workspace target-many)"
  add_repo "$w" second
  run resolve_target "$w"
  [ "$status" -eq 2 ]

  bash -c '. "$1"; ns_record_work_target "$2" "$3"' _ "$LIB" "$w" "$w/second"
  expected="$(git -C "$w/second" rev-parse --show-toplevel)"
  run resolve_target "$w"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "gate progress follows the persisted target after resume" {
  w="$(new_workspace target-resume)"
  add_repo "$w" second
  punch_open "$w"
  bash -c '. "$1"; ns_record_work_target "$2" "$3"' _ "$LIB" "$w" "$w/second"

  run gate "$w" NIGHTSHIFT_STALL_MAX=2 NIGHTSHIFT_STALL_WARN=1
  is_block "$output"
  git -C "$w/second" commit -q --allow-empty -m progress
  run gate "$w" NIGHTSHIFT_STALL_MAX=2 NIGHTSHIFT_STALL_WARN=1
  is_block "$output"
  [ ! -e "$w/STOP" ]
}

@test "setup and start pin the same persisted work target contract" {
  setup_skill="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/setup/SKILL.md"
  start_skill="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/start/SKILL.md"
  status_skill="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/status/SKILL.md"
  doctor_skill="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/doctor/SKILL.md"
  pre="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/start-preflight.sh"
  explain="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  doctor="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"
  # Setup writes the record; the preflight reads it and refuses on what it finds. One contract,
  # stated once on each side of it.
  grep -qF '$NS/work-target' "$setup_skill"
  grep -qF 'work-target cannot be resolved from' "$pre"
  grep -qF 'Several child repositories make the choice ambiguous' "$explain"
  # Doctor is the one that says the workspace is standing in, and Status relays what it says.
  grep -qF 'work target could not be resolved; treating workspace as the code root' "$doctor"
  grep -qF 'work target could not be resolved; treating workspace as the code root' "$doctor_skill"
  grep -qF 'Relay every Warning' "$status_skill"
}

planted_repo() {
  local r="$1"
  mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email dev@example.com
  git -C "$r" config user.name tester
  git -C "$r" commit -q --allow-empty -m init
  (cd -P "$r" && pwd)
}

@test "a symlink work-target fails closed" {
  p="$(new_project target-link)"
  planted="$(planted_repo "$BATS_TEST_TMPDIR/planted-work-target")"
  printf '%s\n' "$planted" >"$p/.nightshift/target-plant"
  ln -s target-plant "$p/.nightshift/work-target"
  run resolve_target "$p"
  [ "$status" -eq 1 ]
  [ "$output" != "$planted" ]
}

@test "Doctor does not follow a symlink work-target" {
  p="$(new_project target-link-doctor)"
  planted="$(planted_repo "$BATS_TEST_TMPDIR/planted-work-target-doctor")"
  printf '%s\n' "$planted" >"$p/.nightshift/target-plant"
  ln -s target-plant "$p/.nightshift/work-target"
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'work target could not be resolved; treating workspace as the code root'
  if printf '%s' "$output" | grep -qF "work target $planted"; then
    return 1
  fi
}

@test "unstored resolve skips a symlink child git repository" {
  notes="$BATS_TEST_TMPDIR/notes-skip-link"
  mkdir -p "$notes/.nightshift"
  planted="$(planted_repo "$BATS_TEST_TMPDIR/planted-target")"
  ln -s "$planted" "$notes/decoy"
  run resolve_target "$notes"
  [ "$status" -eq 1 ]
}

@test "unstored resolve still finds a real child beside a planted symlink" {
  w="$(new_workspace target-decoy-beside)"
  planted="$(planted_repo "$BATS_TEST_TMPDIR/planted-target-beside")"
  ln -s "$planted" "$w/decoy"
  expected="$(git -C "$w/repo" rev-parse --show-toplevel)"
  run resolve_target "$w"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "commit inspect still follows a symlink child git repository" {
  w="$BATS_TEST_TMPDIR/inspect-link"
  mkdir -p "$w"
  planted="$(planted_repo "$BATS_TEST_TMPDIR/inspect-repo")"
  ln -s "$planted" "$w/app"
  run bash -c '. "$1"; repo_root "$2"' _ "$LIB" "$w"
  [ "$status" -eq 0 ]
  [ "$output" = "$planted" ]
}

@test "a persisted work-target still resolves after a Windows CRLF write" {
  p="$(new_project target-crlf)"
  expected="$(git -C "$p" rev-parse --show-toplevel)"
  printf '%s\r\n' "$expected" >"$p/.nightshift/work-target"
  printf 'repository\r\n' >"$p/.nightshift/work-mode"
  run resolve_target "$p"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}
