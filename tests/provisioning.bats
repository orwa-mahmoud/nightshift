#!/usr/bin/env bats
# Adversarial provisioning: policy refusals, fake-recipe apply, rollback, recover.

ROOT="$BATS_TEST_DIRNAME/.."
PROVISION="$ROOT/plugins/nightshift/runtime/provision.sh"
LINKER="$ROOT/plugins/nightshift/runtime/link-workspace.sh"
WIN="$ROOT/plugins/nightshift/runtime/windows/provision.ps1"
ENGINE="$ROOT/plugins/nightshift/skills/nightshift/references/compose/provisioning-engine.md"
SCHEMA="$ROOT/plugins/nightshift/skills/nightshift/references/schemas/v1/capability-recipe.json"
START="$ROOT/plugins/nightshift/skills/start/SKILL.md"
HUNT="$ROOT/plugins/nightshift/skills/hunt/SKILL.md"
HELPERS="$BATS_TEST_DIRNAME/helpers.bash"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/provisioning"
RECOVER_RECIPE="$FIXTURES/recover-recipe.json"
OWNER_DIRTY_SH="$FIXTURES/owner-dirty.sh"
INSTALL_TX="$FIXTURES/install-transaction.sh"

# Everything a host needs to resolve a policy and take a surface baseline, minus python3.
PROVISION_TOOLSET_NO_PYTHON="bash sh jq git sed grep find sort ls awk cat tr head tail wc cut \
mkdir cp rm mv ln env date uname test dirname basename printf true false mktemp shasum"

load helpers

provision() {
  bash "$PROVISION" "$@"
}

enable_auto_add() {
  # The effective tooling policy is the one-shift policy Start writes before arming. The test
  # project is already armed and the writer refuses while armed by design, so write the fixture.
  printf 'repository\n' >"$1/.nightshift/work-mode"
  printf '%s\n' "$1" >"$1/.nightshift/work-target"
  jq -n '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-01-01T00:00:00Z",source:"start-defaults",deadlineEpoch:null,verificationLevel:"none",toolingPolicy:"auto-add",allowances:[]}' \
    >"$1/.nightshift/shift-policy.json"
}

# auto_add <project> [--tooling P] [--allow CAT] [--rules-allow CAT] [--exact-plan CAT --command C]
# The elevation cases need allowances and an exact-plan digest, which the fixture script builds
# with the resolver's own helpers.
auto_add() {
  local p="$1"
  shift
  bash "$FIXTURES/write-shift-policy.sh" --project "$p" "$@"
}

allow_in_rules() {
  bash "$FIXTURES/write-rules-elevation.sh" --project "$1" --category "$2" --policy "$3"
}

# The frictionless grant an unattended shift needs, so a permission reason can only come from
# the check under test.
grant_unattended() {
  mkdir -p "$1/.claude"
  jq -n '{permissions:{defaultMode:"bypassPermissions"}}' >"$1/.claude/settings.local.json"
}

tree_outside() {
  find "$1" \( -path "$1/.git" -o -path "$1/.git/*" -o -path "$1/.nightshift" -o -path "$1/.nightshift/*" \) -prune -o -print | sort
}

# recover_seed_baseline <project> — the exact content `recover-recipe.json`'s baseline captured:
# nightshift-keep.txt and nightshift-config.json present with their original bytes,
# generated/nested/nightshift-fake.txt absent. Matches the digests baked into every
# recover-tx-*.json fixture, so a proof-checking recovery accepts the restore.
recover_seed_baseline() {
  local p="$1"
  printf 'baseline\n' >"$p/nightshift-keep.txt"
  printf '{"ok":true}\n' >"$p/nightshift-config.json"
}

# recover_seed_mutated <project> — the interrupted-mid-transaction state every rollback-path
# fixture (apply, smoke, rollback) expects to find on disk: the two existing files overwritten,
# and the file that did not exist yet created under a nested directory (to exercise empty-parent
# pruning back up to, not including, the project root). Reused as-is for the finish-path fixtures
# (record, commit-tooling), where the exact bytes do not matter — that path never restores them.
recover_seed_mutated() {
  local p="$1"
  printf 'mutated\n' >"$p/nightshift-keep.txt"
  printf '{"mutated":true}\n' >"$p/nightshift-config.json"
  mkdir -p "$p/generated/nested"
  printf 'new\n' >"$p/generated/nested/nightshift-fake.txt"
}

@test "unknown flags do not mutate" {
  p="$(new_project prov-unknown)"
  enable_auto_add "$p"
  printf 'keep\n' >"$p/nightshift-keep.txt"
  before="$(cksum "$p/nightshift-keep.txt")"
  run provision --project "$p" --recipe /tmp/nope apply
  [ "$status" -ne 0 ]
  [ "$(cksum "$p/nightshift-keep.txt")" = "$before" ]
  [ ! -e "$p/.nightshift/provision-surface" ]
  [ ! -e "$p/.nightshift/provision-baseline" ]
}

@test "baseline diff and rollback restore the write surface" {
  p="$(new_project prov-seatbelt)"
  enable_auto_add "$p"
  printf 'baseline\n' >"$p/nightshift-keep.txt"
  run provision --project "$p" baseline --surface nightshift-keep.txt --surface nightshift-fake.txt
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.ok == true' >/dev/null
  [ -f "$p/.nightshift/provision-surface" ]
  printf 'mutated\n' >"$p/nightshift-keep.txt"
  printf 'new\n' >"$p/nightshift-fake.txt"
  run provision --project "$p" diff
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.touched | index("nightshift-keep.txt") and index("nightshift-fake.txt")' >/dev/null
  run provision --project "$p" rollback
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.ok == true and .rolledBack == true' >/dev/null
  [ "$(cat "$p/nightshift-keep.txt")" = "baseline" ]
  [ ! -e "$p/nightshift-fake.txt" ]
  [ ! -e "$p/.nightshift/provision-surface" ]
  [ ! -e "$p/.nightshift/provision-transaction.json" ]
}

@test "one --surface takes the documented path list, and the flag still repeats" {
  p="$(new_project prov-surface-list)"
  enable_auto_add "$p"
  printf 'one\n' >"$p/nightshift-keep.txt"
  printf 'two\n' >"$p/nightshift-second.txt"

  run provision --project "$p" baseline --surface nightshift-keep.txt nightshift-second.txt
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.ok == true' >/dev/null
  listed="$(cut -f1 "$p/.nightshift/provision-surface" | sort | tr '\n' ' ')"
  [ "$listed" = "nightshift-keep.txt nightshift-second.txt " ]

  run provision --project "$p" baseline --surface nightshift-keep.txt --surface nightshift-second.txt
  [ "$status" -eq 0 ]
  repeated="$(cut -f1 "$p/.nightshift/provision-surface" | sort | tr '\n' ' ')"
  [ "$repeated" = "$listed" ]
}

@test "a --surface that names no path is a usage error, not a mutation" {
  p="$(new_project prov-surface-empty)"
  enable_auto_add "$p"
  run provision --project "$p" baseline --surface --project "$p"
  [ "$status" -eq 1 ]
  [ ! -e "$p/.nightshift/provision-surface" ]
  [ ! -e "$p/.nightshift/provision-baseline" ]
}

@test "symlink to /tmp/victim does not write outside the work target" {
  p="$(new_project prov-symlink)"
  enable_auto_add "$p"
  victim="$(mktemp "${TMPDIR:-/tmp}/ns-victim.XXXXXX")"
  printf 'secret\n' >"$victim"
  before="$(cksum "$victim")"
  ln -s "$victim" "$p/nightshift-keep.txt"
  run provision --project "$p" baseline --surface nightshift-keep.txt
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | jq -e '.ok == false and .refused == true' >/dev/null
  [ "$(cksum "$victim")" = "$before" ]
  [ "$(cat "$victim")" = "secret" ]
  [ ! -e "$p/.nightshift/provision-surface" ]

  rm -f "$p/nightshift-keep.txt"
  printf 'baseline\n' >"$p/nightshift-keep.txt"
  run provision --project "$p" baseline --surface nightshift-keep.txt --surface nightshift-fake.txt
  [ "$status" -eq 0 ]
  rm -f "$p/nightshift-keep.txt"
  ln -s "$victim" "$p/nightshift-keep.txt"
  printf 'planted\n' >"$p/nightshift-fake.txt"
  run provision --project "$p" rollback
  [ "$status" -eq 0 ]
  [ "$(cksum "$victim")" = "$before" ]
  [ "$(cat "$victim")" = "secret" ]
  [ "$(cat "$p/nightshift-keep.txt")" = "baseline" ]
  [ ! -L "$p/nightshift-keep.txt" ]
  [ ! -e "$p/nightshift-fake.txt" ]
  rm -f "$victim"
}

@test "failed tooling commit stays consistent when rollback runs" {
  p="$(new_project prov-commit)"
  enable_auto_add "$p"
  printf 'baseline\n' >"$p/nightshift-keep.txt"
  run provision --project "$p" baseline --surface nightshift-keep.txt --surface capabilities-row.txt
  [ "$status" -eq 0 ]
  printf 'tool\n' >"$p/nightshift-keep.txt"
  printf '{"id":"fixture"}\n' >"$p/capabilities-row.txt"
  # Model writes inventory only after commit. A failed commit rolls the surface back.
  run provision --project "$p" rollback
  [ "$status" -eq 0 ]
  [ "$(cat "$p/nightshift-keep.txt")" = "baseline" ]
  [ ! -e "$p/capabilities-row.txt" ]
  [ ! -e "$p/.nightshift/capabilities.json" ]
}

@test "the seatbelt does not require python under auto-add" {
  p="$(new_project prov-pre-runtime)"
  grant_unattended "$p"
  # shellcheck disable=SC2086
  bin="$(build_toolset_bin prov-no-python $PROVISION_TOOLSET_NO_PYTHON)"
  [ ! -e "$bin/python3" ]
  auto_add "$p"
  printf 'baseline\n' >"$p/nightshift-keep.txt"
  run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    bash "$PROVISION" --project "$p" baseline --surface nightshift-keep.txt
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.ok == true' >/dev/null
}

@test "Windows provision.ps1 names baseline diff recover rollback" {
  [ -f "$WIN" ]
  grep -qF 'baseline' "$WIN"
  grep -qF 'diff' "$WIN"
  grep -qF 'recover' "$WIN"
  grep -qF 'rollback' "$WIN"
  if grep -qF "'plan'" "$WIN"; then
    return 1
  fi
}

@test "Start and Hunt name the thin seatbelt" {
  grep -qF 'provision.sh' "$ENGINE"
  grep -qF 'baseline' "$ENGINE"
  grep -qF 'provision.sh' "$START"
  grep -qE 'provision\.sh[^`]* recover' "$START"
  grep -qF 'provision.sh' "$HUNT"
  grep -qF 'baseline' "$HUNT"
}

# Recovery residue, owner-file safety, and no-retry — every recover-tx-*.json fixture represents
# a crash at that exact stage of `recover-recipe.json`'s transaction (capabilityId
# "fixture-recover", allowedFiles nightshift-keep.txt + nightshift-config.json +
# generated/nested/nightshift-fake.txt). `recover_seed_baseline` reproduces the untouched state
# those fixtures' baseline digests were computed against; `recover_seed_mutated` reproduces the
# fully-written, not-yet-committed state. Every case also drops an owner file outside any
# allowedFiles list first and proves it comes back byte-identical.

@test "recover from an interrupted authorize leaves nothing outside allowedFiles" {
  p="$(new_project prov-rec-authorize)"
  enable_auto_add "$p"
  bash "$OWNER_DIRTY_SH" "$p"
  owner_before="$(cksum "$p/owner-live-edit.txt")"
  recover_seed_baseline "$p"
  clean="$(tree_outside "$p")"
  bash "$INSTALL_TX" "$FIXTURES/recover-tx-authorize.json" "$p" "$RECOVER_RECIPE"
  run provision --project "$p" recover
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.ok == true and .rolledBack == true and .proven == true and .capabilityId == "fixture-recover"' >/dev/null
  [ "$(cat "$p/nightshift-keep.txt")" = "baseline" ]
  [ "$(cat "$p/nightshift-config.json")" = '{"ok":true}' ]
  [ ! -e "$p/.nightshift/provision-transaction.json" ]
  [ ! -e "$p/.nightshift/provision-baseline" ]
  [ "$(cksum "$p/owner-live-edit.txt")" = "$owner_before" ]
  [ "$(tree_outside "$p")" = "$clean" ]
}

@test "recover from an interrupted capture-baseline leaves nothing outside allowedFiles" {
  p="$(new_project prov-rec-capture-baseline)"
  enable_auto_add "$p"
  bash "$OWNER_DIRTY_SH" "$p"
  owner_before="$(cksum "$p/owner-live-edit.txt")"
  recover_seed_baseline "$p"
  clean="$(tree_outside "$p")"
  bash "$INSTALL_TX" "$FIXTURES/recover-tx-capture-baseline.json" "$p" "$RECOVER_RECIPE"
  run provision --project "$p" recover
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.ok == true and .rolledBack == true and .proven == true and .capabilityId == "fixture-recover"' >/dev/null
  [ "$(cat "$p/nightshift-keep.txt")" = "baseline" ]
  [ "$(cat "$p/nightshift-config.json")" = '{"ok":true}' ]
  [ ! -e "$p/.nightshift/provision-transaction.json" ]
  [ ! -e "$p/.nightshift/provision-baseline" ]
  [ "$(cksum "$p/owner-live-edit.txt")" = "$owner_before" ]
  [ "$(tree_outside "$p")" = "$clean" ]
}

@test "recover from an interrupted apply restores the blob and content baselines and prunes created files" {
  p="$(new_project prov-rec-apply)"
  enable_auto_add "$p"
  bash "$OWNER_DIRTY_SH" "$p"
  owner_before="$(cksum "$p/owner-live-edit.txt")"
  recover_seed_baseline "$p"
  clean="$(tree_outside "$p")"
  recover_seed_mutated "$p"
  bash "$INSTALL_TX" "$FIXTURES/recover-tx-apply-failed.json" "$p" "$RECOVER_RECIPE"
  run provision --project "$p" recover
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.ok == true and .rolledBack == true and .proven == true and .capabilityId == "fixture-recover"' >/dev/null
  [ "$(cat "$p/nightshift-keep.txt")" = "baseline" ]
  [ "$(cat "$p/nightshift-config.json")" = '{"ok":true}' ]
  [ ! -e "$p/generated" ]
  [ ! -e "$p/.nightshift/provision-transaction.json" ]
  [ ! -e "$p/.nightshift/provision-baseline" ]
  [ "$(cksum "$p/owner-live-edit.txt")" = "$owner_before" ]
  [ "$(tree_outside "$p")" = "$clean" ]
}

@test "recover from an interrupted smoke restores baseline and prunes created files" {
  p="$(new_project prov-rec-smoke)"
  enable_auto_add "$p"
  bash "$OWNER_DIRTY_SH" "$p"
  owner_before="$(cksum "$p/owner-live-edit.txt")"
  recover_seed_baseline "$p"
  clean="$(tree_outside "$p")"
  recover_seed_mutated "$p"
  bash "$INSTALL_TX" "$FIXTURES/recover-tx-smoke-failed.json" "$p" "$RECOVER_RECIPE"
  run provision --project "$p" recover
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.ok == true and .rolledBack == true and .proven == true and .capabilityId == "fixture-recover"' >/dev/null
  [ "$(cat "$p/nightshift-keep.txt")" = "baseline" ]
  [ "$(cat "$p/nightshift-config.json")" = '{"ok":true}' ]
  [ ! -e "$p/generated" ]
  [ ! -e "$p/.nightshift/provision-transaction.json" ]
  [ ! -e "$p/.nightshift/provision-baseline" ]
  [ "$(cksum "$p/owner-live-edit.txt")" = "$owner_before" ]
  [ "$(tree_outside "$p")" = "$clean" ]
}

@test "recover from a crash mid-rollback finishes the restore and prunes created files" {
  p="$(new_project prov-rec-rollback)"
  enable_auto_add "$p"
  bash "$OWNER_DIRTY_SH" "$p"
  owner_before="$(cksum "$p/owner-live-edit.txt")"
  recover_seed_baseline "$p"
  clean="$(tree_outside "$p")"
  recover_seed_mutated "$p"
  bash "$INSTALL_TX" "$FIXTURES/recover-tx-rollback-failed.json" "$p" "$RECOVER_RECIPE"
  run provision --project "$p" recover
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.ok == true and .rolledBack == true and .proven == true and .capabilityId == "fixture-recover"' >/dev/null
  [ "$(cat "$p/nightshift-keep.txt")" = "baseline" ]
  [ "$(cat "$p/nightshift-config.json")" = '{"ok":true}' ]
  [ ! -e "$p/generated" ]
  [ ! -e "$p/.nightshift/provision-transaction.json" ]
  [ ! -e "$p/.nightshift/provision-baseline" ]
  [ "$(cksum "$p/owner-live-edit.txt")" = "$owner_before" ]
  [ "$(tree_outside "$p")" = "$clean" ]
}

@test "recover from an interrupted record finishes natively with a real commit" {
  p="$(new_project prov-rec-record)"
  enable_auto_add "$p"
  bash "$OWNER_DIRTY_SH" "$p"
  owner_before="$(cksum "$p/owner-live-edit.txt")"
  recover_seed_baseline "$p"
  recover_seed_mutated "$p"
  before="$(tree_outside "$p")"
  bash "$INSTALL_TX" "$FIXTURES/recover-tx-record.json" "$p" "$RECOVER_RECIPE"
  run provision --project "$p" recover
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .ok == true and .recovered == true and .finished == true
    and .capabilityId == "fixture-recover" and (.setupCommit | length) > 0
  ' >/dev/null
  [ ! -e "$p/.nightshift/provision-transaction.json" ]
  sha="$(git -C "$p" rev-parse HEAD)"
  git -C "$p" log -1 --format=%s | grep -qx 'chore(tooling): fixture-recover'
  jq -e --arg sha "$sha" '.items[] | select(.capability == "fixture-recover" and .setupCommit == $sha)' \
    "$p/.nightshift/capabilities.json" >/dev/null
  [ "$(cksum "$p/owner-live-edit.txt")" = "$owner_before" ]
  [ "$(tree_outside "$p")" = "$before" ]
}

@test "recover from an interrupted commit-tooling finishes natively with a real commit" {
  p="$(new_project prov-rec-commit-tooling)"
  enable_auto_add "$p"
  bash "$OWNER_DIRTY_SH" "$p"
  owner_before="$(cksum "$p/owner-live-edit.txt")"
  recover_seed_baseline "$p"
  recover_seed_mutated "$p"
  before="$(tree_outside "$p")"
  bash "$INSTALL_TX" "$FIXTURES/recover-tx-commit-tooling.json" "$p" "$RECOVER_RECIPE"
  run provision --project "$p" recover
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .ok == true and .recovered == true and .finished == true
    and .capabilityId == "fixture-recover" and (.setupCommit | length) > 0
  ' >/dev/null
  [ ! -e "$p/.nightshift/provision-transaction.json" ]
  sha="$(git -C "$p" rev-parse HEAD)"
  git -C "$p" log -1 --format=%s | grep -qx 'chore(tooling): fixture-recover'
  jq -e --arg sha "$sha" '.items[] | select(.capability == "fixture-recover" and .setupCommit == $sha)' \
    "$p/.nightshift/capabilities.json" >/dev/null
  [ "$(cksum "$p/owner-live-edit.txt")" = "$owner_before" ]
  [ "$(tree_outside "$p")" = "$before" ]
}

@test "unknown apply does not mutate a leftover failed transaction; recover settles it" {
  p="$(new_project prov-no-retry)"
  enable_auto_add "$p"
  recover_seed_baseline "$p"
  recover_seed_mutated "$p"
  bash "$INSTALL_TX" "$FIXTURES/recover-tx-apply-failed.json" "$p" "$RECOVER_RECIPE"
  run provision --project "$p" --recipe "$FIXTURES/smoke-fail.json" apply
  [ "$status" -ne 0 ]
  [ -f "$p/.nightshift/provision-transaction.json" ]
  run provision --project "$p" recover
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/provision-transaction.json" ]
  [ "$(cat "$p/nightshift-keep.txt")" = "baseline" ]
  [ "$(cat "$p/nightshift-config.json")" = '{"ok":true}' ]
  [ ! -e "$p/generated" ]
}
