#!/usr/bin/env bats
# Native rollback and recovery: the bash helper settles a provisioning transaction, proves the
# restore, and finishes the late stages — every case on a PATH that has jq and no python3, so
# the recovery path carries no second toolchain.

ROOT="$BATS_TEST_DIRNAME/.."
RECOVER="$ROOT/plugins/nightshift/runtime/provision-recover.sh"
PROVISION="$ROOT/plugins/nightshift/runtime/provision.sh"
START="$ROOT/plugins/nightshift/skills/start/SKILL.md"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/provisioning"

load helpers
. "$BATS_TEST_DIRNAME/fixtures/provisioning/recover-fixtures.sh"

# The toolset every case runs on: jq, no python3, plus the two tools the restore and its proof
# need beyond the usual POSIX set.
RECOVER_TOOLSET="bash sh jq git sed grep find sort ls awk cat tr head tail wc cut mkdir cp \
mv rm rmdir ln env cmp date uname test dirname basename readlink stat printf true false xargs \
mktemp base64"

# recover_bin <dir-name> — the controlled PATH, with whichever sha256 tool this host carries.
# A host with none cannot prove a restore, and the suite says so rather than passing quietly.
recover_bin() {
  local d tool real
  d="$(build_toolset_bin "$1" $RECOVER_TOOLSET)" || return 1
  for tool in sha256sum shasum openssl; do
    if real="$(resolve_tool_path "$tool" 2>/dev/null)"; then
      ln -s "$real" "$d/$tool"
    fi
  done
  if [ ! -e "$d/sha256sum" ] && [ ! -e "$d/shasum" ] && [ ! -e "$d/openssl" ]; then
    echo "test host carries no sha256 tool" >&2
    return 1
  fi
  [ ! -e "$d/python3" ] || { echo "toolset leaked python3" >&2; return 1; }
  printf '%s' "$d"
}

setup() {
  RECOVER_BIN="$(recover_bin recover-bin)"
  recover_reset
}

# recover <project> [args...] — the helper, on the controlled PATH.
recover() {
  local p="$1"
  shift
  env PATH="$RECOVER_BIN" bash "$RECOVER" --project "$p" "$@"
}

# provision <project> [args...] — the CLI verb, on the same controlled PATH.
provision() {
  local p="$1"
  shift
  env PATH="$RECOVER_BIN" bash "$PROVISION" --project "$p" "$@"
}

tree_outside() {
  find "$1" \( -path "$1/.git" -o -path "$1/.git/*" -o -path "$1/.nightshift" \
    -o -path "$1/.nightshift/*" \) -prune -o -print | sort
}

fingerprint() {
  (cd "$1" && find . \( -type f -o -type l \) -exec cksum {} \; | sort)
}

@test "no transaction is a settled report, not a failure" {
  p="$(new_project rec-none)"
  run recover "$p"
  [ "$status" -eq 0 ]
  [ "$output" = '{"detail":"no transaction","ok":true,"recovered":false}' ]
}

@test "rollback restores bytes from the blob store" {
  p="$(new_project rec-blob)"
  printf 'owner baseline\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json blob
  recover_touch recover-tool.json
  printf 'engine rewrote this\n' >"$p/recover-tool.json"
  recover_write_tx "$p" "$p" apply false

  run recover "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .ok == true and .rolledBack == true and .proven == true
    and .capabilityId == "fixture-recover"
    and .touched == ["recover-tool.json"]
  ' >/dev/null
  [ "$(cat "$p/recover-tool.json")" = "owner baseline" ]
  [ ! -e "$(recover_tx_path "$p")" ]
  [ ! -e "$(recover_store "$p")" ]
}

@test "rollback restores bytes from the base64 content when the blob file is gone" {
  p="$(new_project rec-content)"
  printf 'owner baseline\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json content
  recover_touch recover-tool.json
  printf 'engine rewrote this\n' >"$p/recover-tool.json"
  recover_write_tx "$p" "$p" smoke false
  [ ! -e "$(recover_store "$p")" ]

  run recover "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.ok == true and .proven == true' >/dev/null
  [ "$(cat "$p/recover-tool.json")" = "owner baseline" ]
  [ ! -e "$(recover_tx_path "$p")" ]
}

@test "rollback falls back to content when the blob id survives but its file does not" {
  p="$(new_project rec-orphan)"
  printf 'owner baseline\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json orphan
  recover_touch recover-tool.json
  printf 'engine rewrote this\n' >"$p/recover-tool.json"
  recover_write_tx "$p" "$p" apply true

  run recover "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.ok == true and .proven == true' >/dev/null
  [ "$(cat "$p/recover-tool.json")" = "owner baseline" ]
}

@test "rollback restores a file whose bytes are not valid UTF-8" {
  p="$(new_project rec-binary)"
  printf 'head\001\002\377tail\n' >"$p/recover-tool.json"
  before="$(cksum "$p/recover-tool.json")"
  recover_keep "$p" "$p" recover-tool.json content
  recover_touch recover-tool.json
  printf 'engine rewrote this\n' >"$p/recover-tool.json"
  recover_write_tx "$p" "$p" apply false

  run recover "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.proven == true' >/dev/null
  [ "$(cksum "$p/recover-tool.json")" = "$before" ]
}

@test "created files are removed and their empty parents pruned up to the work target" {
  p="$(new_project rec-prune)"
  mkdir -p "$p/config/deep" "$p/staging/only"
  printf 'owner note\n' >"$p/config/owner.txt"
  printf 'new\n' >"$p/config/deep/recover-tool.rc"
  printf 'new\n' >"$p/staging/only/recover-tool.json"
  recover_new config/deep/recover-tool.rc
  recover_new staging/only/recover-tool.json
  recover_touch config/deep/recover-tool.rc
  recover_touch staging/only/recover-tool.json
  recover_write_tx "$p" "$p" apply false

  run recover "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.rolledBack == true and .proven == true' >/dev/null
  [ ! -e "$p/config/deep/recover-tool.rc" ]
  [ ! -e "$p/staging/only/recover-tool.json" ]
  # An empty parent goes; a parent still holding owner work stays; the target itself is never
  # a candidate.
  [ ! -e "$p/config/deep" ]
  [ -d "$p/config" ]
  [ "$(cat "$p/config/owner.txt")" = "owner note" ]
  [ ! -e "$p/staging/only" ]
  [ ! -e "$p/staging" ]
  [ -d "$p" ]
}

@test "a corrupt blob leaves the transaction and the store in place and exits 3" {
  p="$(new_project rec-corrupt)"
  printf 'owner baseline\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json blob
  recover_touch recover-tool.json
  printf 'engine rewrote this\n' >"$p/recover-tool.json"
  recover_write_tx "$p" "$p" apply false
  blob="$(recover_blob_id recover-tool.json)"
  printf 'corrupted store\n' >"$(recover_store "$p")/$blob"

  run recover "$p"
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '
    .ok == false and .rolledBack == false and .proven == false
    and .detail == "restored bytes do not match baseline digest: recover-tool.json"
  ' >/dev/null
  [ -f "$(recover_tx_path "$p")" ]
  [ -f "$(recover_store "$p")/$blob" ]
}

@test "a directory where a created file was recorded exits 3 and touches nothing" {
  p="$(new_project rec-blocked)"
  mkdir -p "$p/recover-tool.json"
  printf 'owner work\n' >"$p/recover-tool.json/keep.txt"
  recover_new recover-tool.json
  recover_touch recover-tool.json
  recover_write_tx "$p" "$p" apply true
  before="$(fingerprint "$p")"

  run recover "$p"
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '
    .proven == false and .detail == "created path still present: recover-tool.json"
  ' >/dev/null
  [ "$(fingerprint "$p")" = "$before" ]
  [ -f "$(recover_tx_path "$p")" ]
}

@test "an entry with nothing to restore from exits 3 rather than writing an empty file" {
  p="$(new_project rec-empty)"
  printf 'owner baseline\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json none
  recover_touch recover-tool.json
  printf 'engine rewrote this\n' >"$p/recover-tool.json"
  recover_write_tx "$p" "$p" capture-baseline false

  run recover "$p"
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '
    .ok == false and .proven == false
    and .detail == "restored bytes do not match baseline digest: recover-tool.json"
  ' >/dev/null
  # Unrestorable is not the same as empty: what is on disk stays readable.
  [ "$(cat "$p/recover-tool.json")" = "engine rewrote this" ]
  [ -f "$(recover_tx_path "$p")" ]
}

@test "late stages finish natively with a real tooling commit and an inventory row" {
  p="$(new_project rec-finish)"
  printf '{}\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json both
  mkdir -p "$p/config"
  printf 'on\n' >"$p/config/recover-tool.rc"
  recover_new config/recover-tool.rc
  printf '{"lint":true}\n' >"$p/recover-tool.json"
  recover_touch recover-tool.json
  recover_touch config/recover-tool.rc
  recover_write_tx "$p" "$p" record false "$FIXTURES/recover-recipe-native.json"
  [ -d "$(recover_store "$p")" ]

  run recover "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .ok == true and .recovered == true and .finished == true
    and .capabilityId == "fixture-recover"
    and (.setupCommit | test("^[0-9a-f]{40}$"))
    and .touched == ["recover-tool.json", "config/recover-tool.rc"]
  ' >/dev/null
  setup_commit="$(printf '%s\n' "$output" | jq -r '.setupCommit')"

  # The install stands: a finish is not a rollback.
  [ "$(cat "$p/recover-tool.json")" = '{"lint":true}' ]
  [ "$(cat "$p/config/recover-tool.rc")" = "on" ]

  git -C "$p" log -1 --format=%s | grep -qx 'chore(tooling): fixture-recover'
  [ "$(git -C "$p" rev-parse HEAD)" = "$setup_commit" ]
  [ -z "$(git -C "$p" status --porcelain -- recover-tool.json config/recover-tool.rc)" ]

  jq -e --arg sha "$setup_commit" '
    .schemaVersion == 1 and .tickProof == false
    and (.updatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and ([.items[] | select(.capability == "fixture-recover")] | length) == 1
    and (.items[] | select(.capability == "fixture-recover")
         | .command == "recover-tool --version"
         and .source == "recipe"
         and .recipeVersion == "1"
         and .setupCommit == $sha
         and .configFiles == ["recover-tool.json", "config/recover-tool.rc"]
         and (.verifiedAt | test("^[0-9]{4}-")))
  ' "$p/.nightshift/capabilities.json" >/dev/null

  [ ! -e "$(recover_tx_path "$p")" ]
  [ ! -e "$(recover_store "$p")" ]
}

@test "a finish replaces the capability's existing inventory row and keeps the others" {
  p="$(new_project rec-inventory)"
  jq -n '{
    schemaVersion: 1, source: "detector", updatedAt: "2026-01-01T00:00:00Z", tickProof: true,
    items: [
      {capability: "other-tool", command: "other --version", source: "detector"},
      {capability: "fixture-recover", command: "stale", source: "detector"}
    ]
  }' >"$p/.nightshift/capabilities.json"
  printf 'on\n' >"$p/recover-tool.json"
  recover_new recover-tool.json
  recover_touch recover-tool.json
  recover_write_tx "$p" "$p" commit-tooling false "$FIXTURES/recover-recipe-native.json"

  run recover "$p"
  [ "$status" -eq 0 ]
  jq -e '
    .source == "detector" and .tickProof == false
    and (.items | length) == 2
    and (.items[] | select(.capability == "other-tool") | .command == "other --version")
    and (.items[] | select(.capability == "fixture-recover")
         | .command == "recover-tool --version" and .source == "recipe")
  ' "$p/.nightshift/capabilities.json" >/dev/null
}

@test "a finish with nothing staged records no commit and still clears the transaction" {
  p="$(new_project rec-nocommit)"
  printf 'on\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json both
  recover_touch recover-tool.json
  git -C "$p" add recover-tool.json
  git -C "$p" commit -q -m 'owner committed the config already'
  head_before="$(git -C "$p" rev-parse HEAD)"
  recover_write_tx "$p" "$p" commit-tooling false "$FIXTURES/recover-recipe-native.json"

  run recover "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.finished == true and .setupCommit == ""' >/dev/null
  [ "$(git -C "$p" rev-parse HEAD)" = "$head_before" ]
  [ ! -e "$(recover_tx_path "$p")" ]
  [ ! -e "$(recover_store "$p")" ]
}

@test "a late stage marked failed rolls back instead of finishing" {
  p="$(new_project rec-late-failed)"
  printf 'owner baseline\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json both
  recover_touch recover-tool.json
  printf 'engine rewrote this\n' >"$p/recover-tool.json"
  recover_write_tx "$p" "$p" record true "$FIXTURES/recover-recipe-native.json"

  run recover "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.rolledBack == true and .proven == true' >/dev/null
  [ "$(cat "$p/recover-tool.json")" = "owner baseline" ]
  [ "$(git -C "$p" log -1 --format=%s)" = init ]
  [ ! -e "$p/.nightshift/capabilities.json" ]
}

@test "a late stage whose recipe is gone rolls back rather than guessing" {
  p="$(new_project rec-no-recipe)"
  printf 'owner baseline\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json both
  recover_touch recover-tool.json
  printf 'engine rewrote this\n' >"$p/recover-tool.json"
  recover_write_tx "$p" "$p" record false "$p/absent-recipe.json"

  run recover "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.rolledBack == true and .proven == true' >/dev/null
  [ "$(cat "$p/recover-tool.json")" = "owner baseline" ]
}

@test "a malformed stage exits 2 naming the field and touches nothing" {
  p="$(new_project rec-bad-stage)"
  printf 'owner note\n' >"$p/recover-tool.json"
  cp "$FIXTURES/recover-malformed-stage.json" "$(recover_tx_path "$p")"
  before="$(fingerprint "$p")"

  run recover "$p"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | jq -e '
    .ok == false and .malformed == true
    and .detail == "malformed transaction: stage"
  ' >/dev/null
  [ "$(fingerprint "$p")" = "$before" ]
  [ -f "$(recover_tx_path "$p")" ]
}

@test "a malformed baseline entry exits 2 naming the entry and its field" {
  p="$(new_project rec-bad-baseline)"
  cp "$FIXTURES/recover-malformed-baseline.json" "$(recover_tx_path "$p")"
  run recover "$p"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | jq -e \
    '.detail == "malformed transaction: baseline[\"recover-tool.json\"].existed"' >/dev/null
}

@test "a transaction that is not JSON exits 2 naming the document" {
  p="$(new_project rec-bad-doc)"
  cp "$FIXTURES/recover-malformed-document.json" "$(recover_tx_path "$p")"
  run recover "$p"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | jq -e '.detail == "malformed transaction: document"' >/dev/null
  [ -f "$(recover_tx_path "$p")" ]
}

@test "a baseline key that escapes the work target exits 2 and never leaves the tree" {
  p="$(new_project rec-escape)"
  outside="$BATS_TEST_TMPDIR/rec-escape-outside.txt"
  printf 'not ours\n' >"$outside"
  recover_new "../rec-escape-outside.txt"
  recover_write_tx "$p" "$p" apply false

  run recover "$p"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | jq -e '.malformed == true' >/dev/null
  printf '%s\n' "$output" | grep -qF 'malformed transaction: baseline'
  [ -f "$outside" ]
}

@test "a baseline key naming an owner state file exits 2" {
  p="$(new_project rec-locked)"
  recover_new "punch-list.md"
  recover_write_tx "$p" "$p" apply false
  run recover "$p"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | jq -e \
    '.detail == "malformed transaction: baseline[\"punch-list.md\"]"' >/dev/null
}

@test "an unproven baseline exits 3 and Start refuses to arm with the named repair" {
  p="$(new_project rec-refuse)"
  printf 'owner baseline\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json blob
  recover_touch recover-tool.json
  recover_write_tx "$p" "$p" rollback true
  printf 'corrupted store\n' >"$(recover_store "$p")/$(recover_blob_id recover-tool.json)"

  run recover "$p"
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '.ok == false and .proven == false' >/dev/null

  # The contract for that exit code, and the repair, are the preflight's: it decides the verdict and
  # prints the words, so a test on Start's prose would hold a copy rather than the thing.
  PRE="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/start-preflight.sh"
  EXPLAIN="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  grep -qF 'refuse "provision an interrupted install cannot be proven recovered"' "$PRE"
  grep -qF '.nightshift/provision-transaction.json and provision-baseline/, restore by hand or run' "$PRE"
  grep -qF 'ns provision rollback after fixing the target, then Start again' "$PRE"
  # Why it refuses, said once, where the verdict is explained.
  grep -qF 'product work on top of it would build on a half-applied change' "$EXPLAIN"
}

@test "the CLI verbs delegate to the native helper" {
  p="$(new_project rec-verbs)"
  grep -qF 'provision-recover.sh' "$PROVISION"

  run provision "$p" recover
  [ "$status" -eq 0 ]
  [ "$output" = '{"detail":"no transaction","ok":true,"recovered":false}' ]

  run provision "$p" rollback
  [ "$status" -eq 0 ]
  [ "$output" = '{"detail":"no transaction","ok":true,"recovered":false}' ]
}

@test "the rollback verb undoes a late stage instead of finishing it" {
  p="$(new_project rec-force)"
  printf 'owner baseline\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json both
  recover_touch recover-tool.json
  printf 'engine rewrote this\n' >"$p/recover-tool.json"
  recover_write_tx "$p" "$p" commit-tooling false "$FIXTURES/recover-recipe-native.json"

  run provision "$p" rollback
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.rolledBack == true and .proven == true' >/dev/null
  [ "$(cat "$p/recover-tool.json")" = "owner baseline" ]
  [ ! -e "$p/.nightshift/capabilities.json" ]
}

@test "the diagnosis is read-only and classifies the baseline" {
  p="$(new_project rec-diagnose)"
  printf 'owner baseline\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json both
  recover_touch recover-tool.json
  printf 'engine rewrote this\n' >"$p/recover-tool.json"
  recover_write_tx "$p" "$p" apply false
  before="$(fingerprint "$p")"

  run recover "$p" --diagnose
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'provision transaction stage=apply capability=fixture-recover baseline=provable'
  [ "$(fingerprint "$p")" = "$before" ]

  printf 'corrupted store\n' >"$(recover_store "$p")/$(recover_blob_id recover-tool.json)"
  run recover "$p" --diagnose
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'baseline=unprovable'

  cp "$FIXTURES/recover-malformed-stage.json" "$(recover_tx_path "$p")"
  run recover "$p" --diagnose
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'provision-transaction.json is malformed (stage)'
}

@test "recovery leaves owner work outside the baseline untouched" {
  p="$(new_project rec-owner)"
  printf 'owner note - do not touch\n' >"$p/owner-note.txt"
  printf 'owner baseline\n' >"$p/recover-tool.json"
  recover_keep "$p" "$p" recover-tool.json both
  recover_touch recover-tool.json
  printf 'engine rewrote this\n' >"$p/recover-tool.json"
  recover_write_tx "$p" "$p" apply true
  before="$(cksum "$p/owner-note.txt")"
  tree_before="$(tree_outside "$p")"

  run recover "$p"
  [ "$status" -eq 0 ]
  [ "$(cksum "$p/owner-note.txt")" = "$before" ]
  [ "$(cat "$p/owner-note.txt")" = "owner note - do not touch" ]
  [ "$(tree_outside "$p")" = "$tree_before" ]
}

@test "a symlinked transaction is malformed, never followed" {
  p="$(new_project rec-symlink)"
  recover_new recover-tool.json
  recover_write_tx "$p" "$p" apply false
  mv "$(recover_tx_path "$p")" "$p/.nightshift/real-transaction.json"
  ln -s "$p/.nightshift/real-transaction.json" "$(recover_tx_path "$p")"

  run recover "$p"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | jq -e '.detail == "malformed transaction: document"' >/dev/null
}

@test "the helper rejects a non-numeric budget and reports its usage" {
  p="$(new_project rec-budget)"
  run recover "$p" --budget-seconds later
  [ "$status" -eq 1 ]

  run recover "$p" --budget-seconds 30
  [ "$status" -eq 0 ]
  [ "$output" = '{"detail":"no transaction","ok":true,"recovered":false}' ]
}
