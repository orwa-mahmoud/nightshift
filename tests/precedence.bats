#!/usr/bin/env bats
# The precedence table, row by row. One resolver answers for hardhat, Start, Doctor, Status and
# the support bundle, so every row is settled here once rather than in each caller.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
SP="$ROOT/plugins/nightshift/runtime/shift-policy.sh"
LIB="$ROOT/plugins/nightshift/lib/lib.sh"
GATES_BLOCK='## Gates'

unarmed() {
  local p
  p="$(new_project "${1:-prec}")"
  rm -f "$p/.nightshift/.shift-armed"
  printf '%s' "$p"
}

policy() { # <project> [extra JSON without the leading comma]
  {
    printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z",'
    printf '"source":"composition","deadlineEpoch":null,"verificationLevel":"final",'
    printf '"toolingPolicy":"existing-tools"%s}\n' "${2:+,$2}"
  } >"$1/.nightshift/shift-policy.json"
}

rules_set() { # <project> <jq filter>
  jq "$2" "$1/.nightshift/rules.json" >"$1/rules.next"
  mv "$1/rules.next" "$1/.nightshift/rules.json"
}

setting() { # <project> <name> — "value|source|expiry"
  bash "$SP" --project "$1" resolve --json |
    jq -r --arg k "$2" '.settings[$k] | "\(.value)|\(.source)|\(.expiry)"'
}

allowed() { # <project> <category> [command] — echoes the status ns_policy_allowed returns
  bash -c '. "$1"; ns_policy_allowed "$2" "$3" "${4:-}"; printf %s "$?"' \
    _ "$LIB" "$1" "$2" "${3:-}"
}

SHIFT_ID=9f2c40ab77e51d63

work_target() { # <project> — the canonical path a plan is approved against
  local t
  t="$(bash -c '. "$1"; ns_work_target "$2"' _ "$LIB" "$1")" || return 1
  (cd -P "$t" && pwd)
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# The digest the owner signs, spelled out here rather than borrowed from the resolver: sha256 over
# the compact canonical JSON of the approved commands, the shift, and the work target.
plan_digest() { # <workTarget> <shiftId> <command>...
  local target="$1" id="$2" cmds
  shift 2
  cmds="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  jq -nc --argjson commands "$cmds" --arg shiftId "$id" --arg workTarget "$target" \
    '{commands: $commands, shiftId: $shiftId, workTarget: $workTarget}' |
    jq -caS . | tr -d '\n' | sha256_text
}

exact_plan() { # <project> <deadline JSON> <workTarget> <digest> <command>...
  local p="$1" deadline="$2" target="$3" digest="$4" cmds
  shift 4
  cmds="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  jq -n --argjson deadline "$deadline" --argjson commands "$cmds" --arg target "$target" \
    --arg digest "$digest" --arg id "$SHIFT_ID" '{
      schemaVersion: 1, shiftId: $id, createdAt: "2026-09-02T02:30:00Z",
      source: "composition", deadlineEpoch: $deadline, verificationLevel: "final",
      toolingPolicy: "existing-tools",
      allowances: [{
        category: "sudo", scope: "exact-plan", provenance: "one-shift",
        plan: { commands: $commands, workTarget: $target, digest: $digest }
      }]
    }' >"$p/.nightshift/shift-policy.json"
}

# Narrow a plan already on disk, without touching what the digest covers.
with_plan_expiry() { # <project> <expiry JSON>
  jq --argjson expiry "$2" '.allowances[0].plan.expiry = $expiry' \
    "$1/.nightshift/shift-policy.json" >"$1/next.json"
  mv "$1/next.json" "$1/.nightshift/shift-policy.json"
}

# A plan bound to this project, this shift, and these commands.
bound_plan() { # <project> <deadline JSON> <command>...
  local p="$1" deadline="$2" target
  shift 2
  target="$(work_target "$p")"
  exact_plan "$p" "$deadline" "$target" "$(plan_digest "$target" "$SHIFT_ID" "$@")" "$@"
}

# Row 1 -------------------------------------------------------------------------------------
@test "row 1: protected paths, never-commit, expected email and forbiddenCommands are rules only" {
  p="$(unarmed prec-row1)"
  rules_set "$p" '
    .protectedDirs = "secrets ops"
    | .neverCommitPatterns = "BEGIN PRIVATE KEY"
    | .expectedEmail = "night@example.com"
    | .forbiddenCommands = "curl [|] sh"
  '
  # An allowance for every category, of both provenances, plus an exact plan.
  policy "$p" '"allowances":[
    {"category":"sudo","scope":"category","provenance":"one-shift"},
    {"category":"containers","scope":"category","provenance":"rules"},
    {"category":"global-packages","scope":"category","provenance":"one-shift"},
    {"category":"daemons","scope":"category","provenance":"rules"},
    {"category":"external-services","scope":"category","provenance":"one-shift"}]'
  [ "$(setting "$p" protectedDirs)" = 'secrets ops|rules|permanent' ]
  [ "$(setting "$p" neverCommitPatterns)" = 'BEGIN PRIVATE KEY|rules|permanent' ]
  [ "$(setting "$p" expectedEmail)" = 'night@example.com|rules|permanent' ]
  [ "$(setting "$p" forbiddenCommands)" = 'curl [|] sh|rules|permanent' ]
  # And with no rules file at all they fall back to the built-in, never to an allowance.
  rm -f "$p/.nightshift/rules.json"
  [ "$(setting "$p" protectedDirs)" = '|built-in|-' ]
  [ "$(setting "$p" expectedEmail)" = '|built-in|-' ]
}

# Row 2 -------------------------------------------------------------------------------------
@test "row 2: a one-shift allowance alone lifts the built-in deny" {
  p="$(unarmed prec-row2a)"
  [ "$(setting "$p" elevation.containers)" = 'deny|rules|permanent' ]
  [ "$(allowed "$p" containers 'docker compose up')" = 1 ]
  policy "$p" '"allowances":[{"category":"containers","scope":"category","provenance":"one-shift"}]'
  [ "$(setting "$p" elevation.containers)" = 'allow|one-shift|shift' ]
  [ "$(allowed "$p" containers 'docker compose up')" = 0 ]
  # The other four are untouched.
  [ "$(setting "$p" elevation.sudo)" = 'deny|rules|permanent' ]
  [ "$(allowed "$p" sudo 'sudo id')" = 1 ]
}

@test "row 2: a rules allow alone lifts the built-in deny, and outlives the shift" {
  p="$(unarmed prec-row2b)"
  rules_set "$p" '.elevation.containers.policy = "allow"'
  [ "$(setting "$p" elevation.containers)" = 'allow|rules|permanent' ]
  [ "$(allowed "$p" containers 'docker compose up')" = 0 ]
  # No shift policy is needed for it, and archiving tonight's does not revoke it.
  [ ! -e "$p/.nightshift/shift-policy.json" ]
}

@test "row 2: a shift-policy allowance tagged rules reports rules and permanent" {
  p="$(unarmed prec-row2c)"
  policy "$p" '"allowances":[{"category":"daemons","scope":"category","provenance":"rules"}]'
  [ "$(setting "$p" elevation.daemons)" = 'allow|rules|permanent' ]
  [ "$(allowed "$p" daemons 'systemctl start postgres')" = 0 ]
}

@test "row 2: a category the owner denies in rules stays denied under every built-in" {
  p="$(unarmed prec-row2d)"
  rules_set "$p" '.elevation.sudo.policy = "deny"'
  policy "$p" ''
  [ "$(setting "$p" elevation.sudo)" = 'deny|rules|permanent' ]
  [ "$(allowed "$p" sudo 'sudo id')" = 1 ]
}

@test "row 2: a category missing from rules.elevation falls back to the built-in deny" {
  p="$(unarmed prec-row2e)"
  rules_set "$p" 'del(.elevation)'
  [ "$(setting "$p" elevation.sudo)" = 'deny|built-in|-' ]
  [ "$(allowed "$p" sudo 'sudo id')" = 1 ]
  # The guard still has a pattern to match with.
  run bash -c '. "$1"; ns_policy_elevation_pattern "$2" sudo' _ "$LIB" "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'd[o]as'
}

# The built-in is what a workspace falls back to; the template is what the owner reads and edits.
# Character-for-character identity is how the fallback cannot quietly gate a different set of
# commands than the file it stands in for.
@test "row 2: the built-in pattern for every category is the template's, character for character" {
  local c want
  for c in sudo containers global-packages daemons external-services; do
    want="$(jq -r --arg c "$c" '.elevation[$c].pattern' "$RULES_TEMPLATE")"
    [ -n "$want" ]
    run bash -c '. "$1"; ns_policy_default_pattern "$2"' _ "$LIB" "$c"
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ] || { echo "$c built-in: $output"; echo "$c template: $want"; return 1; }
  done
}

# Elevation gates creating system state, never reading it — the same corpus the guard suites
# match, checked here against the built-in patterns alone.
@test "row 2: the built-in patterns match creation and leave inspection alone" {
  local p pat cmd
  p="$(unarmed prec-row2f)"
  rules_set "$p" 'del(.elevation)'
  matches() { # <category> <command>
    pat="$(bash -c '. "$1"; ns_policy_elevation_pattern "$2" "$3"' _ "$LIB" "$p" "$1")"
    printf '%s' "$2" | grep -qE "$pat"
  }
  for cmd in 'docker run alpine' 'docker create alpine' 'docker start web' 'docker build .' \
    'docker compose up -d' 'docker-compose up'; do
    matches containers "$cmd" || { echo "containers missed: $cmd"; return 1; }
  done
  for cmd in 'docker ps' 'docker logs web' 'docker inspect web'; do
    ! matches containers "$cmd" || { echo "containers over-matched: $cmd"; return 1; }
  done
  for cmd in 'brew install jq' 'apt-get upgrade jq' 'cargo install ripgrep' 'go install ./cmd/x'; do
    matches global-packages "$cmd" || { echo "global-packages missed: $cmd"; return 1; }
  done
  for cmd in 'brew list' 'apt-get --version'; do
    ! matches global-packages "$cmd" || { echo "global-packages over-matched: $cmd"; return 1; }
  done
  for cmd in '/usr/bin/sudo id' 'sudo;id' "sh -c 'sudo id'"; do
    matches sudo "$cmd" || { echo "sudo missed: $cmd"; return 1; }
  done
  ! matches sudo 'pseudo-random' || { echo "sudo over-matched: pseudo-random"; return 1; }
}

# Row 3 -------------------------------------------------------------------------------------
@test "row 3: an exact-plan allowance permits its own commands and nothing else" {
  p="$(unarmed prec-row3a)"
  bound_plan "$p" null 'sudo apt-get install -y jq' 'sudo systemctl restart nginx'
  [ "$(setting "$p" elevation.sudo)" = 'exact-plan|exact-plan|shift' ]
  [ "$(allowed "$p" sudo 'sudo apt-get install -y jq')" = 0 ]
  [ "$(allowed "$p" sudo 'sudo systemctl restart nginx')" = 0 ]
  # Whitespace is normalized on both sides, so the same command still matches.
  [ "$(allowed "$p" sudo '  sudo   apt-get  install -y jq ')" = 0 ]
  # Anything else in the category is a mismatch, not a denial: the caller parks it.
  [ "$(allowed "$p" sudo 'sudo rm -rf /')" = 2 ]
  [ "$(allowed "$p" sudo '')" = 2 ]
}

@test "row 3: an exact plan is bound to its digest" {
  p="$(unarmed prec-digest)"
  target="$(work_target "$p")"
  cmd='sudo apt-get install -y jq'

  # A digest that covers nothing: the plan grants nothing either.
  exact_plan "$p" null "$target" \
    '0000000000000000000000000000000000000000000000000000000000000000' "$cmd"
  [ "$(setting "$p" elevation.sudo)" = 'exact-plan|exact-plan|shift' ]
  [ "$(allowed "$p" sudo "$cmd")" = 2 ]

  # A digest the owner really signed, for a different command.
  exact_plan "$p" null "$target" "$(plan_digest "$target" "$SHIFT_ID" 'sudo id')" "$cmd"
  [ "$(allowed "$p" sudo "$cmd")" = 2 ]

  # A digest signed for another shift cannot be replayed into this one.
  exact_plan "$p" null "$target" "$(plan_digest "$target" ffffffffffffffff "$cmd")" "$cmd"
  [ "$(allowed "$p" sudo "$cmd")" = 2 ]

  # And the digest that does cover this plan.
  bound_plan "$p" null "$cmd"
  [ "$(allowed "$p" sudo "$cmd")" = 0 ]
}

@test "row 3: an exact plan is bound to the work target it was approved against" {
  p="$(unarmed prec-target)"
  other="$BATS_TEST_TMPDIR/elsewhere"
  mkdir -p "$other"
  cmd='sudo apt-get install -y jq'
  # Signed correctly, but for somebody else's tree.
  exact_plan "$p" null "$other" "$(plan_digest "$other" "$SHIFT_ID" "$cmd")" "$cmd"
  [ "$(allowed "$p" sudo "$cmd")" = 2 ]
  bound_plan "$p" null "$cmd"
  [ "$(allowed "$p" sudo "$cmd")" = 0 ]
  # A target that cannot be resolved at all fails closed rather than waving the plan through.
  rm -rf "$p/.git"
  [ "$(allowed "$p" sudo "$cmd")" = 2 ]
}

@test "row 3: an exact plan expires with the shift" {
  p="$(unarmed prec-expiry)"
  cmd='sudo apt-get install -y jq'
  bound_plan "$p" "$(($(date +%s) + 3600))" "$cmd"
  [ "$(allowed "$p" sudo "$cmd")" = 0 ]
  bound_plan "$p" "$(($(date +%s) - 60))" "$cmd"
  [ "$(setting "$p" elevation.sudo)" = 'exact-plan|exact-plan|shift' ]
  [ "$(allowed "$p" sudo "$cmd")" = 2 ]
}

@test "row 3: an exact plan also runs out on its own clock" {
  p="$(unarmed prec-plan-expiry)"
  cmd='sudo apt-get install -y jq'
  bound_plan "$p" null "$cmd"
  # No expiry at all: the shift's clock is the plan's only clock.
  [ "$(allowed "$p" sudo "$cmd")" = 0 ]
  # An explicit null says the same thing.
  with_plan_expiry "$p" null
  [ "$(allowed "$p" sudo "$cmd")" = 0 ]
  # Ahead of now, and the digest is untouched by it: still bound.
  with_plan_expiry "$p" "$(($(date +%s) + 3600))"
  [ "$(allowed "$p" sudo "$cmd")" = 0 ]
  # Passed: the owner's approval has run out even though the shift has not.
  with_plan_expiry "$p" "$(($(date +%s) - 60))"
  [ "$(setting "$p" elevation.sudo)" = 'exact-plan|exact-plan|shift' ]
  [ "$(allowed "$p" sudo "$cmd")" = 2 ]
}

@test "row 3: a category allowance beside an exact plan wins, and the category applies" {
  p="$(unarmed prec-row3b)"
  policy "$p" '"allowances":[
    {"category":"sudo","scope":"exact-plan","provenance":"one-shift",
     "plan":{"commands":["sudo apt-get install -y jq"],"workTarget":"/work/repo",
             "digest":"3b1c9a5e77d0426f8a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071"}},
    {"category":"sudo","scope":"category","provenance":"one-shift"}]'
  [ "$(setting "$p" elevation.sudo)" = 'allow|one-shift|shift' ]
  [ "$(allowed "$p" sudo 'sudo apt-get install -y jq')" = 0 ]
  [ "$(allowed "$p" sudo 'sudo anything at all')" = 0 ]
}

@test "row 3: an exact plan for one category leaves the others denied" {
  p="$(unarmed prec-row3c)"
  target="$(work_target "$p")"
  cmd='docker compose up -d'
  jq -n --arg target "$target" --arg id "$SHIFT_ID" --arg cmd "$cmd" \
    --arg digest "$(plan_digest "$target" "$SHIFT_ID" "$cmd")" '{
      schemaVersion: 1, shiftId: $id, createdAt: "2026-09-02T02:30:00Z",
      source: "composition", deadlineEpoch: null, verificationLevel: "final",
      toolingPolicy: "existing-tools",
      allowances: [{
        category: "containers", scope: "exact-plan", provenance: "one-shift",
        plan: { commands: [$cmd], workTarget: $target, digest: $digest }
      }]
    }' >"$p/.nightshift/shift-policy.json"
  [ "$(allowed "$p" containers "$cmd")" = 0 ]
  [ "$(allowed "$p" sudo 'sudo docker compose up -d')" = 1 ]
  [ "$(allowed "$p" daemons 'systemctl start docker')" = 1 ]
}

# Row 4 -------------------------------------------------------------------------------------
@test "row 4: shift-defaults never appears as the source of an effective value" {
  p="$(unarmed prec-row4)"
  bash "$SP" --project "$p" defaults-set --verificationProfile strict --hours 10 \
    --toolingPolicy auto-add --execution run-direct >/dev/null
  run bash "$SP" --project "$p" resolve --json
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -qF '"source":"defaults"'; then
    return 1
  fi
  # The remembered choices prefill the next question; they do not decide tonight.
  [ "$(setting "$p" toolingPolicy)" = 'existing-tools|built-in|-' ]
  [ "$(setting "$p" verificationLevel)" = 'none|built-in|-' ]
  # Once a composition step copies a choice into the policy, the policy is the source.
  policy "$p" ''
  [ "$(setting "$p" toolingPolicy)" = 'existing-tools|one-shift|shift' ]
  [ "$(setting "$p" verificationLevel)" = 'final|one-shift|shift' ]
  run bash "$SP" --project "$p" defaults-get
  printf '%s' "$output" | jq -e '.toolingPolicy == "auto-add"' >/dev/null
}

# Row 5 -------------------------------------------------------------------------------------
@test "row 5: the Gates block is the file, and the policy keeps only its digest" {
  p="$(unarmed prec-row5)"
  digest='3b1c9a5e77d0426f8a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071'
  policy "$p" "\"gatesDigest\":\"$digest\""
  # No second copy of the commands: the resolved view carries no gate list at all.
  run bash "$SP" --project "$p" resolve --json
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -qF "$GATES_BLOCK"; then
    return 1
  fi
  if printf '%s' "$output" | grep -qiF gatesdigest; then
    return 1
  fi
  # Last writer wins on the block itself; the policy is not consulted for the commands.
  printf '## Items\n' >"$p/.nightshift/punch-list.md"
  run bash "$SP" --project "$p" get
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e --arg d "$digest" '.gatesDigest == $d' >/dev/null
  # And once armed no tool may rewrite the policy the digest lives in.
  : >"$p/.nightshift/.shift-armed"
  bash "$SP" --project "$p" get >"$p/again.json"
  run bash "$SP" --project "$p" set --from-json "$p/again.json"
  [ "$status" -eq 4 ]
}

# Row 6 -------------------------------------------------------------------------------------
@test "row 6: a malformed policy grants nothing and never falls back to an archived one" {
  p="$(unarmed prec-row6)"
  policy "$p" '"allowances":[{"category":"containers","scope":"category","provenance":"one-shift"}]'
  [ "$(setting "$p" elevation.containers)" = 'allow|one-shift|shift' ]
  bash "$SP" --project "$p" archive >/dev/null
  archived="$(find "$p/.nightshift/archive" -name 'shift-policy.json' | head -n 1)"
  [ -f "$archived" ]

  # A hand edit that breaks one field: the archived snapshot must not stand in for it.
  jq '.verificationLevel = "loud"' "$archived" >"$p/.nightshift/shift-policy.json"
  [ "$(setting "$p" elevation.containers)" = 'deny|rules|permanent' ]
  [ "$(setting "$p" verificationLevel)" = 'none|built-in|-' ]
  [ "$(setting "$p" toolingPolicy)" = 'existing-tools|built-in|-' ]
  [ "$(allowed "$p" containers 'docker compose up')" = 1 ]

  # Rules keep applying through the malformation.
  rules_set "$p" '.protectedDirs = "secrets"'
  [ "$(setting "$p" protectedDirs)" = 'secrets|rules|permanent' ]

  # And the refusal Start prints names the exact field.
  run bash "$SP" --project "$p" get
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'verificationLevel must be none, final, per-item, or custom'
}

@test "row 6: an unreadable policy is reported, never repaired or deleted" {
  p="$(unarmed prec-row6b)"
  printf '{ truncated\n' >"$p/.nightshift/shift-policy.json"
  before="$(cksum "$p/.nightshift/shift-policy.json")"
  run bash "$SP" --project "$p" get
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'not JSON'
  run bash "$SP" --project "$p" resolve --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.settings["elevation.sudo"].value == "deny"' >/dev/null
  [ "$(cksum "$p/.nightshift/shift-policy.json")" = "$before" ]
}
