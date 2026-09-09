#!/usr/bin/env bats
# The permission preflight and the parking it feeds.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PRE="$ROOT/plugins/nightshift/runtime/preflight-needs.sh"
PARK="$ROOT/plugins/nightshift/runtime/park-needs.sh"
SP="$ROOT/plugins/nightshift/runtime/shift-policy.sh"

pre() {
  local p="$1"
  shift
  bash "$PRE" --project "$p" "$@"
}

park() { bash "$PARK" --project "$1"; }

unarmed() {
  local p
  p="$(new_project "${1:-pre}")"
  rm -f "$p/.nightshift/.shift-armed"
  printf '%s' "$p"
}

# The fixture the guard, the preflight and the PowerShell twin all agree on.
fixture_list() {
  cat >"$1/.nightshift/punch-list.md" <<'MD'
## Items

- [ ] **1. Bring up the database.**
  - Add postgres to docker-compose.yml and run `docker compose up -d`
  - Verify: `psql -c 'select 1'`
- [ ] **2. Install jq system-wide.**
  - `sudo apt-get install -y jq`
- [ ] **3. Run the tests.**
  - `npm test`
- [x] **4. Pin the linter.**
  - `brew install shellcheck`
MD
}

policy() { # <project> [extra JSON without the leading comma]
  {
    printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z",'
    printf '"source":"composition","deadlineEpoch":null,"verificationLevel":"final",'
    printf '"toolingPolicy":"existing-tools"%s}\n' "${2:+,$2}"
  } >"$1/.nightshift/shift-policy.json"
}

@test "the frozen fixture resolves to exactly the agreed JSON document" {
  p="$(unarmed pre-frozen)"
  fixture_list "$p"
  policy "$p" '"allowances":[{"category":"containers","scope":"category","provenance":"one-shift"}]'
  run pre "$p" --json
  [ "$status" -eq 0 ]
  [ "$output" = '{"gaps":[{"category":"sudo","title":"2. Install jq system-wide."},{"category":"global-packages","title":"2. Install jq system-wide."}],"items":[{"needs":[{"allowed":true,"category":"containers","resolved":"allow"}],"source":"punch-list","title":"1. Bring up the database."},{"needs":[{"allowed":false,"category":"sudo","resolved":"deny"},{"allowed":false,"category":"global-packages","resolved":"deny"}],"source":"punch-list","title":"2. Install jq system-wide."},{"needs":[],"source":"punch-list","title":"3. Run the tests."}],"patternErrors":[],"schemaVersion":1}' ]
}

@test "a ticked item is finished work: never scanned, never a gap, never parked" {
  p="$(unarmed pre-ticked)"
  fixture_list "$p"
  run pre "$p" --json
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -qF 'Pin the linter'; then
    return 1
  fi
  printf '%s' "$output" | jq -e '[.items[].title] | index("4. Pin the linter.") == null' >/dev/null
  printf '%s' "$output" | jq -e '[.gaps[].title] | index("4. Pin the linter.") == null' >/dev/null
  park "$p" >/dev/null
  if grep -qF 'Pin the linter' "$p/.nightshift/parking-lot.md"; then
    return 1
  fi
}

@test "every signal in the owner decisions is detected in an item's own text" {
  p="$(unarmed pre-signals)"
  cat >"$p/.nightshift/punch-list.md" <<'MD'
## Items

- [ ] **1. sudo.**
  - `sudo id`
- [ ] **2. containers.**
  - `podman run alpine`
- [ ] **3. global packages.**
  - `npm install -g pnpm`
- [ ] **4. user packages.**
  - `pip3 install --user black`
- [ ] **5. daemons.**
  - `launchctl load com.example.plist`
- [ ] **6. external services.**
  - `gh auth login`
- [ ] **7. ordinary work.**
  - `npm test` against the dev stack on localhost
MD
  run pre "$p" --json
  [ "$status" -eq 0 ]
  need() { printf '%s' "$output" | jq -e --arg t "$1" --arg c "$2" \
    '[.items[] | select(.title == $t) | .needs[].category] | index($c) != null' >/dev/null; }
  need '1. sudo.' sudo
  need '2. containers.' containers
  need '3. global packages.' global-packages
  need '4. user packages.' global-packages
  need '5. daemons.' daemons
  need '6. external services.' external-services
  printf '%s' "$output" | jq -e '[.items[] | select(.title == "7. ordinary work.") | .needs[]] | length == 0' >/dev/null
}

@test "one item may need several categories, in the fixed category order" {
  p="$(unarmed pre-multi)"
  cat >"$p/.nightshift/punch-list.md" <<'MD'
## Items

- [ ] **1. Everything at once.**
  - `sudo apt-get install -y docker.io`
  - `systemctl start docker`
  - `gh auth login`
MD
  run pre "$p" --json
  [ "$status" -eq 0 ]
  # The patterns are verb-scoped: `docker.io` is a package name and `systemctl start docker`
  # starts a daemon, so neither reaches the containers category.
  [ "$(printf '%s' "$output" | jq -r '[.items[0].needs[].category] | join(",")')" \
    = 'sudo,global-packages,daemons,external-services' ]

  printf '  - `docker compose up -d`\n' >>"$p/.nightshift/punch-list.md"
  run pre "$p" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.items[0].needs[].category] | join(",")')" \
    = 'sudo,containers,global-packages,daemons,external-services' ]
}

@test "a work order is read the same way as a punch-list item" {
  p="$(unarmed pre-orders)"
  printf '## Items\n' >"$p/.nightshift/punch-list.md"
  cat >"$p/.nightshift/work-orders.md" <<'MD'
# Work Orders

> Ordinary prose above the first order mentions docker and sudo and must not be scanned.

---

## Work order — 2026-09-02 21:00
Hours: 8

- [ ] **Bring the stack up with `docker compose up -d`**
 - **Owner instructions:** none
MD
  run pre "$p" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.items | length == 1' >/dev/null
  printf '%s' "$output" | jq -e '.items[0].source == "work-orders"' >/dev/null
  printf '%s' "$output" | jq -e '[.items[0].needs[].category] == ["containers"]' >/dev/null
}

@test "an allowance closes the gap and the resolver is what decides" {
  p="$(unarmed pre-allow)"
  fixture_list "$p"
  run pre "$p" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.gaps[].category] | join(",")')" \
    = 'containers,sudo,global-packages' ]
  policy "$p" '"allowances":[
    {"category":"containers","scope":"category","provenance":"one-shift"},
    {"category":"sudo","scope":"category","provenance":"rules"},
    {"category":"global-packages","scope":"category","provenance":"one-shift"}]'
  run pre "$p" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.gaps == []' >/dev/null
  printf '%s' "$output" | jq -e '[.items[].needs[] | select(.allowed | not)] | length == 0' >/dev/null
}

@test "a category narrowed to an exact plan is reported as a gap, not as an allowance" {
  p="$(unarmed pre-exact)"
  fixture_list "$p"
  policy "$p" '"allowances":[{"category":"sudo","scope":"exact-plan","provenance":"one-shift",
    "plan":{"commands":["sudo apt-get install -y jq"],"workTarget":"/work/repo",
            "digest":"3b1c9a5e77d0426f8a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071"}}]'
  run pre "$p" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    [.items[] | select(.title == "2. Install jq system-wide.") | .needs[] | select(.category == "sudo")]
    == [{allowed: false, category: "sudo", resolved: "exact-plan"}]' >/dev/null
  printf '%s' "$output" | jq -e '[.gaps[].category] | index("sudo") != null' >/dev/null
}

@test "an unreadable owner pattern fails closed and is named" {
  p="$(unarmed pre-badpattern)"
  jq '.elevation.containers.pattern = "docker("' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  printf '## Items\n\n- [ ] **1. Anything at all.**\n  - `echo hello`\n' \
    >"$p/.nightshift/punch-list.md"
  run pre "$p" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.patternErrors == ["containers"]' >/dev/null
  printf '%s' "$output" | jq -e '[.items[0].needs[].category] == ["containers"]' >/dev/null
  run pre "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'pattern error: elevation.containers.pattern'
}

@test "shared fixture: mixed needs, one missing allowance, and no gaps" {
  p="$(unarmed pre-shared)"
  fixture_list "$p"
  run pre "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'preflight: 3 open items, 2 with gaps'
  printf '%s\n' "$output" | grep -qxF 'gaps: containers (item 1), sudo (item 2), global-packages (item 2)'
  policy "$p" '"allowances":[{"category":"containers","scope":"category","provenance":"one-shift"}]'
  run pre "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'preflight: 3 open items, 1 with gaps'
  printf '%s\n' "$output" | grep -qxF 'gaps: sudo (item 2), global-packages (item 2)'
  policy "$p" '"allowances":[
    {"category":"containers","scope":"category","provenance":"one-shift"},
    {"category":"sudo","scope":"category","provenance":"one-shift"},
    {"category":"global-packages","scope":"category","provenance":"one-shift"}]'
  run pre "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'preflight: 3 open items, 0 with gaps'
  printf '%s\n' "$output" | grep -qxF 'gaps: none'
}

@test "the text report names the item, its needs, and the gap summary" {
  p="$(unarmed pre-text)"
  fixture_list "$p"
  policy "$p" '"allowances":[{"category":"containers","scope":"category","provenance":"one-shift"}]'
  run pre "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'preflight: 3 open items, 1 with gaps'
  printf '%s\n' "$output" | grep -qxF 'item 1 [punch-list] 1. Bring up the database.'
  printf '%s\n' "$output" | grep -qxF '  needs containers (allowed)'
  printf '%s\n' "$output" | grep -qxF '  needs sudo (denied)'
  printf '%s\n' "$output" | grep -qxF '  needs nothing'
  printf '%s\n' "$output" | grep -qxF 'gaps: sudo (item 2), global-packages (item 2)'
}

@test "no items and no gaps still report, and never refuse" {
  p="$(unarmed pre-empty)"
  run pre "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'preflight: 0 open items, 0 with gaps'
  printf '%s\n' "$output" | grep -qxF 'gaps: none'
  run pre "$p" --json
  [ "$status" -eq 0 ]
  [ "$output" = '{"gaps":[],"items":[],"patternErrors":[],"schemaVersion":1}' ]
}

@test "the report is identical with python3 and no jq" {
  bin="$(build_toolset_bin pre-nojq bash sh sed tr sort grep cut awk cat python3 mktemp uname \
    date rm mv cp ln printf head tail wc find test dirname)"
  p="$(unarmed pre-nojq)"
  fixture_list "$p"
  policy "$p" '"allowances":[{"category":"containers","scope":"category","provenance":"one-shift"}]'
  jq_out="$(pre "$p" --json)"
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash "$PRE" --project "$p" --json
  [ "$status" -eq 0 ]
  [ "$output" = "$jq_out" ]
}

@test "park-needs writes one entry per item and category, and says what it parked" {
  p="$(unarmed park-one)"
  fixture_list "$p"
  policy "$p" '"allowances":[{"category":"containers","scope":"category","provenance":"one-shift"}]'
  run park "$p"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'parked sudo: 2. Install jq system-wide.' ]
  [ "${lines[1]}" = 'parked global-packages: 2. Install jq system-wide.' ]
  [ "${lines[2]}" = 'park-needs: added 2' ]
  lot="$p/.nightshift/parking-lot.md"
  grep -qxF '**needs allowance: sudo** — item "2. Install jq system-wide." needs the sudo elevation category, which is denied for this shift. Default: parked, worked last if the owner allows it before then.' "$lot"
  grep -qxF '**needs allowance: global-packages** — item "2. Install jq system-wide." needs the global-packages elevation category, which is denied for this shift. Default: parked, worked last if the owner allows it before then.' "$lot"
  [ "$(grep -c 'needs allowance:' "$lot")" -eq 2 ]
}

@test "park-needs is idempotent: a second run adds nothing and changes no byte" {
  p="$(unarmed park-again)"
  fixture_list "$p"
  park "$p" >/dev/null
  lot="$p/.nightshift/parking-lot.md"
  before="$(cksum "$lot")"
  run park "$p"
  [ "$status" -eq 0 ]
  [ "$output" = 'park-needs: added 0' ]
  [ "$(cksum "$lot")" = "$before" ]
  [ "$(grep -c 'needs allowance:' "$lot")" -eq 3 ]
}

@test "park-needs adds only the entry a new item brings, and keeps the owner's own notes" {
  p="$(unarmed park-grow)"
  fixture_list "$p"
  park "$p" >/dev/null
  printf '\nThe owner wrote this by hand.\n' >>"$p/.nightshift/parking-lot.md"
  cat >>"$p/.nightshift/punch-list.md" <<'MD'
- [ ] **5. Log in to the registry.**
  - `docker login ghcr.io`
MD
  run park "$p"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'parked external-services: 5. Log in to the registry.' ]
  [ "${lines[1]}" = 'park-needs: added 1' ]
  grep -qxF 'The owner wrote this by hand.' "$p/.nightshift/parking-lot.md"
  [ "$(grep -c 'needs allowance:' "$p/.nightshift/parking-lot.md")" -eq 4 ]
}

@test "park-needs parks nothing when every category the work needs is allowed" {
  p="$(unarmed park-none)"
  fixture_list "$p"
  policy "$p" '"allowances":[
    {"category":"containers","scope":"category","provenance":"one-shift"},
    {"category":"sudo","scope":"category","provenance":"one-shift"},
    {"category":"global-packages","scope":"category","provenance":"one-shift"}]'
  run park "$p"
  [ "$status" -eq 0 ]
  [ "$output" = 'park-needs: added 0' ]
  [ ! -e "$p/.nightshift/parking-lot.md" ]
}

@test "park-needs works while the shift is armed: Start parks and keeps working" {
  p="$(new_project park-armed)"
  fixture_list "$p"
  [ -f "$p/.nightshift/.shift-armed" ]
  run park "$p"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = 'park-needs: added 3' ]
  # It never touches the guarded policy files while doing it.
  [ ! -e "$p/.nightshift/shift-policy.json" ]
  [ ! -e "$p/.nightshift/shift-defaults.json" ]
}

@test "the preflight and the parking never write outside .nightshift/" {
  w="$(new_workspace pre-scope)"
  rm -f "$w/.nightshift/.shift-armed"
  fixture_list "$w"
  printf 'sentinel\n' >"$w/repo/keep-me.txt"
  before="$(find "$w" \( -path "$w/.nightshift" -o -path "$w/.nightshift/*" \) -prune -o -print | LC_ALL=C sort)"
  bash "$PRE" --project "$w" >/dev/null
  bash "$PRE" --project "$w" --json >/dev/null
  park "$w" >/dev/null
  after="$(find "$w" \( -path "$w/.nightshift" -o -path "$w/.nightshift/*" \) -prune -o -print | LC_ALL=C sort)"
  [ "$before" = "$after" ]
  [ "$(cat "$w/repo/keep-me.txt")" = sentinel ]
}

@test "the preflight agrees with the guard's own answer for the same command" {
  p="$(unarmed pre-agree)"
  fixture_list "$p"
  policy "$p" '"allowances":[{"category":"containers","scope":"category","provenance":"one-shift"}]'
  lib="$ROOT/plugins/nightshift/lib/lib.sh"
  # Every category the preflight calls allowed, ns_policy_allowed also allows, and every gap it
  # names, ns_policy_allowed denies.
  while IFS="$(printf '\t')" read -r category allowed_flag; do
    [ -n "$category" ] || continue
    run bash -c '. "$1"; ns_policy_allowed "$2" "$3" "any command"' _ "$lib" "$p" "$category"
    if [ "$allowed_flag" = true ]; then
      [ "$status" -eq 0 ] || { echo "$category: preflight allowed, guard said $status"; return 1; }
    else
      [ "$status" -ne 0 ] || { echo "$category: preflight gapped, guard allowed"; return 1; }
    fi
  done < <(pre "$p" --json | jq -r '.items[].needs[] | .category + "\t" + (.allowed | tostring)')
}
