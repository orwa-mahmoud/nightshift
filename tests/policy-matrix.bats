#!/usr/bin/env bats
# The 02A acceptance matrix, expressed as deterministic helper-level checks: no model runs, no
# skill invocations — every case drives shift-policy.sh, preflight-needs.sh, and park-needs.sh
# directly, the same way composition and Start do, and reads the answer back through the one
# resolver.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
SP="$ROOT/plugins/nightshift/runtime/shift-policy.sh"
PRE="$ROOT/plugins/nightshift/runtime/preflight-needs.sh"
PARK="$ROOT/plugins/nightshift/runtime/park-needs.sh"
SCHEMAS="$ROOT/plugins/nightshift/skills/nightshift/references/schemas/v1"
VALIDATOR="$BATS_TEST_DIRNAME/helpers/validate-json-schema.py"

sp() {
  local p="$1"
  shift
  bash "$SP" --project "$p" "$@"
}

pre() {
  local p="$1"
  shift
  bash "$PRE" --project "$p" "$@"
}

# A project with rules but no armed marker: composition writes before the clock starts.
unarmed() {
  local p
  p="$(new_project "${1:-mtx}")"
  rm -f "$p/.nightshift/.shift-armed"
  printf '%s' "$p"
}

# The profile -> level map every composition path and Start's own safe defaults share.
level_for_profile() {
  case "$1" in
    fast) printf 'none' ;;
    balanced) printf 'final' ;;
    strict) printf 'per-item' ;;
    custom) printf 'custom' ;;
  esac
}

policy_json() { # <shiftId> <toolingPolicy> <verificationLevel> [source]
  printf '{"schemaVersion":1,"shiftId":"%s","createdAt":"2026-09-02T02:30:00Z",' "$1"
  printf '"source":"%s","deadlineEpoch":null,"verificationLevel":"%s","toolingPolicy":"%s"}\n' \
    "${4:-composition}" "$3" "$2"
}

# ---------------------------------------------------------------------------------------------
# 1. Tooling policy x verification level, in repository mode: every one of the twelve combinations
# is accepted by shift-policy.sh set and resolved with source one-shift, expiry shift. The shift
# policy schema and the resolver carry no notion of work mode — see the artifact-mode test below
# for why that refusal lives in composition instead.

@test "every tooling policy x verification level combination is accepted and resolves as one-shift" {
  p="$(unarmed mtx-repo)"
  i=0
  for tooling in existing-tools review-missing auto-add; do
    for level in none final per-item custom; do
      i=$((i + 1))
      sid="$(printf '1%015x' "$i")"
      policy_json "$sid" "$tooling" "$level" >"$p/candidate.json"
      run sp "$p" set --from-json "$p/candidate.json"
      [ "$status" -eq 0 ] || { echo "set refused for $tooling/$level: $output"; return 1; }
      run sp "$p" resolve --json
      [ "$status" -eq 0 ] || { echo "resolve failed for $tooling/$level: $output"; return 1; }
      printf '%s' "$output" | jq -e --arg t "$tooling" --arg l "$level" '
        .settings.toolingPolicy == {value: $t, source: "one-shift", expiry: "shift"}
        and .settings.verificationLevel == {value: $l, source: "one-shift", expiry: "shift"}
      ' >/dev/null || { echo "resolved mismatch for $tooling/$level: $output"; return 1; }
    done
  done
}

# ---------------------------------------------------------------------------------------------
# 2. Repository/artifact mode. shift-policy.sh and its schema are deliberately work-mode-agnostic
# (grep confirms neither lib/policy.sh nor runtime/shift-policy.sh reads .nightshift/work-mode);
# the frozen interface places the artifact refusal in composition — Setup, Hunt, and Quality never
# offer review-missing or auto-add once work mode is artifact, and explain why in words. That is
# the one part of this matrix that is agent judgment rather than a mechanical helper, so its
# deterministic surface is the exact wording those three skills carry, not a shift-policy.sh exit
# code.

@test "artifact mode's refusal of auto-add and review-missing is exact and identical across every composition skill" {
  setup_skill="$ROOT/plugins/nightshift/skills/setup/SKILL.md"
  hunt_skill="$ROOT/plugins/nightshift/skills/hunt/SKILL.md"
  quality_skill="$ROOT/plugins/nightshift/skills/quality/SKILL.md"

  grep -qF 'repository-tool policies (`auto-add` and' "$setup_skill"
  grep -qF '`review-missing`) are invalid there.' "$setup_skill"

  grep -qF 'Artifact mode refuses repository-tool policies (`auto-add`, `review-missing`) and explains why' "$hunt_skill"

  grep -qF 'Artifact mode refuses repository-tool policies' "$quality_skill"
  grep -qF '(`auto-add` and `review-missing`) and explains why; only existing-tools is valid there.' "$quality_skill"

  # Meanwhile the mechanical layer stays permissive on purpose: shift-policy.sh never reads
  # .nightshift/work-mode, so composition — never the helper — is what must refuse. (The schema's
  # toolingPolicy description documents the rule in prose; it is not a structural enum split by
  # work mode, so the schema alone cannot enforce it — the next test proves the helper accepts
  # every value regardless of work mode.)
  if grep -qiE 'work.mode' "$ROOT/plugins/nightshift/runtime/shift-policy.sh"; then
    return 1
  fi
  if grep -qiE 'work.mode' "$SCHEMAS/shift-policy.json"; then
    return 1
  fi
}

@test "the helper itself is work-mode-agnostic: artifact mode's refusal is composition's job, not shift-policy.sh's" {
  p="$(unarmed mtx-artifact)"
  printf 'artifact\n' >"$p/.nightshift/work-mode"
  printf '%s\n' "$p" >"$p/.nightshift/work-target"
  for tooling in existing-tools review-missing auto-add; do
    policy_json cccccccccccccccc "$tooling" final >"$p/candidate.json"
    run sp "$p" set --from-json "$p/candidate.json"
    [ "$status" -eq 0 ] || { echo "helper unexpectedly refused $tooling in artifact mode: $output"; return 1; }
  done
  # A composition step that respects the contract would never have written review-missing or
  # auto-add here in the first place — existing-tools is the only value it may persist.
  policy_json cccccccccccccccc existing-tools final >"$p/candidate.json"
  run sp "$p" set --from-json "$p/candidate.json"
  [ "$status" -eq 0 ]
  run sp "$p" resolve --json
  printf '%s' "$output" | jq -e '.settings.toolingPolicy.value == "existing-tools"' >/dev/null
}

# ---------------------------------------------------------------------------------------------
# 3. Remembered vs override: shift-defaults.json only ever prefills; a shift-policy.json answer
# that disagrees is what the resolver reports, and defaults-get never moves on its own.

@test "a one-shift override never rewrites the remembered defaults it disagreed with" {
  p="$(unarmed mtx-override)"
  sp "$p" defaults-set --verificationProfile strict --toolingPolicy existing-tools \
    --execution review-first >/dev/null
  policy_json dddddddddddddddd auto-add none >"$p/candidate.json"
  sp "$p" set --from-json "$p/candidate.json" >/dev/null

  run sp "$p" resolve --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .settings.toolingPolicy == {value: "auto-add", source: "one-shift", expiry: "shift"}
    and .settings.verificationLevel == {value: "none", source: "one-shift", expiry: "shift"}
  ' >/dev/null

  run sp "$p" defaults-get
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .toolingPolicy == "existing-tools" and .verificationProfile == "strict"
  ' >/dev/null
}

# ---------------------------------------------------------------------------------------------
# 4. Interactive vs scheduled Start is a helper-level property here: an absent policy is exit 3
# with {}, which is the one signal Start's own text branches on to write start-defaults instead of
# asking (it never asks on any host). A start-defaults document for every remembered profile
# validates against the shipped schema.

@test "get on an absent policy is the exact signal start-defaults exists for, for every remembered profile" {
  i=0
  for profile in fast balanced strict custom; do
    i=$((i + 1))
    p="$(unarmed "mtx-start-$profile")"
    run sp "$p" get
    [ "$status" -eq 3 ] || { echo "$profile: get did not exit 3 on an absent policy"; return 1; }
    [ "$output" = '{}' ] || { echo "$profile: get printed $output instead of {}"; return 1; }

    level="$(level_for_profile "$profile")"
    sid="$(printf '2%015x' "$i")"
    printf '{"schemaVersion":1,"shiftId":"%s","createdAt":"2026-09-02T04:00:00Z",' "$sid" >"$p/start.json"
    printf '"source":"start-defaults","deadlineEpoch":null,"verificationLevel":"%s",' "$level" >>"$p/start.json"
    printf '"toolingPolicy":"existing-tools","allowances":[]}\n' >>"$p/start.json"

    python3 "$VALIDATOR" "$SCHEMAS/shift-policy.json" "$p/start.json" \
      || { echo "$profile: start-defaults document failed schema validation"; return 1; }

    run sp "$p" set --from-json "$p/start.json"
    [ "$status" -eq 0 ] || { echo "$profile: set refused the start-defaults document: $output"; return 1; }
    run sp "$p" get
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e --arg l "$level" '
      .source == "start-defaults" and .toolingPolicy == "existing-tools"
      and .verificationLevel == $l and .allowances == []
    ' >/dev/null || { echo "$profile: written start-defaults document reads back wrong: $output"; return 1; }
  done
}

# ---------------------------------------------------------------------------------------------
# 5. Preflight gap present/absent: the same resolver the matrix already exercised is what the
# preflight and the parking step both read, so a gap that closes is a gap that stops being parked.

@test "a preflight gap is present without an allowance and absent once one is granted, and parking follows" {
  p="$(unarmed mtx-gap)"
  guard_elevation "$p"
  cat >"$p/.nightshift/punch-list.md" <<'MD'
## Items

- [ ] **1. Bring the stack up with docker compose.**
  - `docker compose up -d`
MD
  run pre "$p" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.gaps == [{"category":"containers","title":"1. Bring the stack up with docker compose."}]' >/dev/null

  run bash "$PARK" --project "$p"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'parked containers: 1. Bring the stack up with docker compose.' ]
  [ "${lines[1]}" = 'park-needs: added 1' ]
  grep -qF 'needs allowance: containers' "$p/.nightshift/parking-lot.md"

  q="$(unarmed mtx-gap-closed)"
  guard_elevation "$q"
  cp "$p/.nightshift/punch-list.md" "$q/.nightshift/punch-list.md"
  policy_json eeeeeeeeeeeeeeee existing-tools final >"$q/candidate.json"
  jq '.allowances = [{"category":"containers","scope":"category","provenance":"one-shift"}]' \
    "$q/candidate.json" >"$q/candidate2.json"
  sp "$q" set --from-json "$q/candidate2.json" >/dev/null

  run pre "$q" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.gaps == []' >/dev/null

  run bash "$PARK" --project "$q"
  [ "$status" -eq 0 ]
  [ "$output" = 'park-needs: added 0' ]
  [ ! -e "$q/.nightshift/parking-lot.md" ]
}
