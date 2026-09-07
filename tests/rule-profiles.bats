load helpers

APPLY="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/apply-profile.sh"
PROFILES="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/profiles"
SETUP="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/setup/SKILL.md"
PUNCHLIST_TEMPLATE="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/templates/punch-list.md"

# Prints only the text of the punch list's `## Gates` block (between the heading and the next
# `## ` heading), the same slice apply-profile.sh rewrites.
gates_block() {
  awk '/^## Gates$/ { f = 1; next } /^## / { f = 0 } f' "$1"
}

@test "shipped v1 profiles are version 1 and use only schema keys" {
  schema="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/nightshift-rules.schema.json"
  for name in no-push strict-secrets isolated-branch; do
    f="$PROFILES/$name.json"
    [ -f "$f" ]
    jq -e --arg n "$name" '.name == $n and .version == 1 and .risk and .use and (.rules|type=="object")' "$f" >/dev/null
    jq -e --slurpfile s "$schema" '
      .rules | keys | all(. as $k | ($s[0].properties | has($k)) and $k != "$schema")
    ' "$f" >/dev/null
  done
}

@test "shipped v2 profiles are version 2 with the documented shiftDefaults and gates" {
  for name in fast balanced strict; do
    f="$PROFILES/$name.json"
    [ -f "$f" ]
    jq -e --arg n "$name" '.name == $n and .version == 2 and .risk and .use and (.rules|type=="object")' "$f" >/dev/null
  done
  jq -e '
    .shiftDefaults.verificationProfile == "fast"
    and .shiftDefaults.toolingPolicy == "existing-tools"
    and .shiftDefaults.execution == "run-direct"
    and .gates.itemGate == []
    and (.gates | has("siteInspection") | not)
  ' "$PROFILES/fast.json" >/dev/null
  jq -e '
    .shiftDefaults.verificationProfile == "balanced"
    and (.shiftDefaults | has("toolingPolicy") | not)
    and (.shiftDefaults | has("execution") | not)
    and .gates == null
    and .rules.stallMax == 0
    and .rules.stallWarnEvery == 3
    and .rules.watchMinutes == 10
    and .rules.watchRetrySeconds == "30 120"
  ' "$PROFILES/balanced.json" >/dev/null
  jq -e '
    .shiftDefaults.verificationProfile == "strict"
    and (.shiftDefaults | has("toolingPolicy") | not)
    and (.shiftDefaults | has("execution") | not)
    and .gates == null
  ' "$PROFILES/strict.json" >/dev/null
}

@test "list and preview are deterministic and write nothing" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  before="$(cksum "$p/.nightshift/rules.json")"
  run bash "$APPLY" --project "$p" --list
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'no-push'
  printf '%s' "$output" | grep -q 'isolated-branch'
  printf '%s' "$output" | grep -q 'not a subscription'
  run bash "$APPLY" --project "$p" --profile no-push --mode fill
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Dry run'
  printf '%s' "$output" | grep -q 'forbiddenCommands'
  first="$output"
  run bash "$APPLY" --project "$p" --profile no-push --mode fill
  [ "$output" = "$first" ]
  [ "$(cksum "$p/.nightshift/rules.json")" = "$before" ]
}

@test "fill keeps owner values and replace shows a full next file" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  python3 -c '
import json,sys
p=sys.argv[1]
with open(p) as f: d=json.load(f)
d["forbiddenCommands"]="rm -rf"
with open(p,"w") as f: json.dump(d,f)
' "$p/.nightshift/rules.json"
  run bash "$APPLY" --project "$p" --profile no-push --mode fill --apply
  [ "$status" -eq 0 ]
  jq -e '.forbiddenCommands == "rm -rf"' "$p/.nightshift/rules.json" >/dev/null
  jq '.["$schema"] = 42' "$p/.nightshift/rules.json" >"$p/rules.tmp"
  mv "$p/rules.tmp" "$p/.nightshift/rules.json"
  run bash "$APPLY" --project "$p" --profile no-push --mode replace --apply
  [ "$status" -eq 0 ]
  jq -e '.forbiddenCommands == "git .*push"' "$p/.nightshift/rules.json" >/dev/null
  jq -e '
    (.["$schema"] | type) == "string"
    and (.["$schema"] | length) > 0
    and (.toolDeny.AskUserQuestion | type) == "string"
    and (.toolDeny.request_user_input | type) == "string"
    and (.toolDeny.AskQuestion | type) == "string"
    and (.watchMinutes | type) == "number"
    and (.clockOutMessage | length) > 0
  ' "$p/.nightshift/rules.json" >/dev/null
}

@test "fill refuses an old file with no explicit Codex question policy" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  jq 'del(.toolDeny.request_user_input)' "$p/.nightshift/rules.json" >"$p/rules.tmp"
  mv "$p/rules.tmp" "$p/.nightshift/rules.json"
  before="$(cksum "$p/.nightshift/rules.json")"
  run bash "$APPLY" --project "$p" --profile no-push --mode fill --apply
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -q 'explicit native question policy'
  [ "$(cksum "$p/.nightshift/rules.json")" = "$before" ]
}

@test "unknown keys, malformed profiles, and armed writes are refused" {
  p="$(new_project)"
  run bash "$APPLY" --project "$p" --profile not-a-profile --mode fill
  [ "$status" -eq 1 ]
  run bash "$APPLY" --project "$p" --profile '../nightshift-rules-template' --mode fill
  [ "$status" -eq 1 ]
  : >"$p/.nightshift/.shift-armed"
  run bash "$APPLY" --project "$p" --profile no-push --mode fill --apply
  [ "$status" -eq 2 ]
  if jq -e '.forbiddenCommands == "git .*push"' "$p/.nightshift/rules.json" >/dev/null; then
    return 1
  fi
}

@test "v2 preview writes nothing and previews shift-defaults and the Gates block" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  cp "$PUNCHLIST_TEMPLATE" "$p/.nightshift/punch-list.md"
  run bash "$APPLY" --project "$p" --profile fast --mode fill
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Proposed shift-defaults.json'
  printf '%s' "$output" | grep -q '"verificationProfile": "fast"'
  printf '%s' "$output" | grep -q 'Proposed ## Gates block'
  [ ! -f "$p/.nightshift/shift-defaults.json" ]
  gates_block "$p/.nightshift/punch-list.md" | grep -qF '_None configured._'
}

# A profile writes the remembered choices where they are read from, so applying one cannot leave
# the same setting in two files that disagree.
@test "apply fast writes the shift block and an empty Gates placeholder" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  cp "$PUNCHLIST_TEMPLATE" "$p/.nightshift/punch-list.md"
  run bash "$APPLY" --project "$p" --profile fast --mode fill --apply
  [ "$status" -eq 0 ]
  jq -e '
    .shift.verificationProfile == "fast"
    and .shift.hours == null
    and .shift.toolingPolicy == "existing-tools"
    and .shift.execution == "run-direct"
  ' "$p/.nightshift/rules.json" >/dev/null
  # And the legacy file is not resurrected beside it.
  [ ! -f "$p/.nightshift/shift-defaults.json" ]
  # What the profile wrote is what composition reads back.
  run bash -c '. "$1"; ns_policy_read_defaults "$2"' \
    _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  printf '%s' "$output" | jq -e '.verificationProfile == "fast" and .execution == "run-direct"' >/dev/null
  gates_block "$p/.nightshift/punch-list.md" | grep -qF '_None configured._'
}

@test "apply strict after fast changes only verificationProfile and leaves the Gates block untouched" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  cp "$PUNCHLIST_TEMPLATE" "$p/.nightshift/punch-list.md"
  bash "$APPLY" --project "$p" --profile fast --mode fill --apply >/dev/null
  before_gates="$(cksum "$p/.nightshift/punch-list.md")"
  run bash "$APPLY" --project "$p" --profile strict --mode fill --apply
  [ "$status" -eq 0 ]
  jq -e '
    .shift.verificationProfile == "strict"
    and .shift.toolingPolicy == "existing-tools"
    and .shift.execution == "run-direct"
  ' "$p/.nightshift/rules.json" >/dev/null
  [ "$(cksum "$p/.nightshift/punch-list.md")" = "$before_gates" ]
}

@test "apply of a v1 profile changes only the guards; the shift block and Gates stay untouched" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  cp "$PUNCHLIST_TEMPLATE" "$p/.nightshift/punch-list.md"
  bash "$APPLY" --project "$p" --profile fast --mode fill --apply >/dev/null
  before_shift="$(jq -cS '.shift' "$p/.nightshift/rules.json")"
  before_gates="$(cksum "$p/.nightshift/punch-list.md")"
  run bash "$APPLY" --project "$p" --profile no-push --mode replace --apply
  [ "$status" -eq 0 ]
  jq -e '.forbiddenCommands == "git .*push"' "$p/.nightshift/rules.json" >/dev/null
  [ "$(jq -cS '.shift' "$p/.nightshift/rules.json")" = "$before_shift" ]
  [ "$(cksum "$p/.nightshift/punch-list.md")" = "$before_gates" ]
}

@test "v2 apply refuses while armed and writes no shift-defaults.json" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  cp "$PUNCHLIST_TEMPLATE" "$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  run bash "$APPLY" --project "$p" --profile fast --mode fill --apply
  [ "$status" -eq 2 ]
  [ ! -f "$p/.nightshift/shift-defaults.json" ]
}

@test "a v2 profile with a non-null gates refuses to apply without a punch list" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  rm -f "$p/.nightshift/punch-list.md"
  run bash "$APPLY" --project "$p" --profile fast --mode fill --apply
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -q 'punch-list.md'
}

@test "gates.itemGate renders commands, and the site-inspection sentence only when that key is present" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  cp "$PUNCHLIST_TEMPLATE" "$p/.nightshift/punch-list.md"
  plugincopy="$BATS_TEST_TMPDIR/plugincopy"
  mkdir -p "$plugincopy"
  cp -R "$BATS_TEST_DIRNAME/../plugins" "$plugincopy/plugins"
  cat >"$plugincopy/plugins/nightshift/skills/nightshift/references/profiles/probe.json" <<'JSON'
{
  "name": "probe",
  "version": 2,
  "risk": "low",
  "use": "test",
  "rules": {},
  "shiftDefaults": null,
  "gates": {
    "itemGate": ["eslint .", "tsc --noEmit"],
    "siteInspection": { "every": "5 items", "commands": ["knip"] }
  }
}
JSON
  run bash "$plugincopy/plugins/nightshift/runtime/apply-profile.sh" --project "$p" --profile probe --mode fill --apply
  [ "$status" -eq 0 ]
  gates="$(gates_block "$p/.nightshift/punch-list.md")"
  printf '%s' "$gates" | grep -qF '`eslint .`'
  printf '%s' "$gates" | grep -qF '`tsc --noEmit`'
  printf '%s' "$gates" | grep -qF '**Site inspection**'
  printf '%s' "$gates" | grep -qF 'every 5 items'
  printf '%s' "$gates" | grep -qF '`knip`'

  cat >"$plugincopy/plugins/nightshift/skills/nightshift/references/profiles/probe2.json" <<'JSON'
{
  "name": "probe2",
  "version": 2,
  "risk": "low",
  "use": "test",
  "rules": {},
  "shiftDefaults": null,
  "gates": { "itemGate": ["eslint ."] }
}
JSON
  run bash "$plugincopy/plugins/nightshift/runtime/apply-profile.sh" --project "$p" --profile probe2 --mode fill --apply
  [ "$status" -eq 0 ]
  gates2="$(gates_block "$p/.nightshift/punch-list.md")"
  printf '%s' "$gates2" | grep -qF '`eslint .`'
  if printf '%s' "$gates2" | grep -qF '**Site inspection**'; then
    return 1
  fi
}

@test "malformed v2 shiftDefaults or gates are refused before any write" {
  p="$(new_project)"
  rm -f "$p/.nightshift/.shift-armed"
  cp "$PUNCHLIST_TEMPLATE" "$p/.nightshift/punch-list.md"
  plugincopy="$BATS_TEST_TMPDIR/plugincopy-bad"
  mkdir -p "$plugincopy"
  cp -R "$BATS_TEST_DIRNAME/../plugins" "$plugincopy/plugins"
  cat >"$plugincopy/plugins/nightshift/skills/nightshift/references/profiles/bad-sd.json" <<'JSON'
{
  "name": "bad-sd", "version": 2, "risk": "low", "use": "t", "rules": {},
  "shiftDefaults": { "verificationProfile": "nope" }, "gates": null
}
JSON
  run bash "$plugincopy/plugins/nightshift/runtime/apply-profile.sh" --project "$p" --profile bad-sd --mode fill
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -q 'verificationProfile'
  [ ! -f "$p/.nightshift/shift-defaults.json" ]

  cat >"$plugincopy/plugins/nightshift/skills/nightshift/references/profiles/bad-gates.json" <<'JSON'
{
  "name": "bad-gates", "version": 2, "risk": "low", "use": "t", "rules": {},
  "shiftDefaults": null,
  "gates": { "itemGate": ["x"], "siteInspection": { "every": "abc", "commands": [] } }
}
JSON
  run bash "$plugincopy/plugins/nightshift/runtime/apply-profile.sh" --project "$p" --profile bad-gates --mode fill
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -q 'siteInspection.every'
}

@test "profiles never fetch the network and setup documents confirmation" {
  if grep -E 'curl|wget|http' "$APPLY" "$PROFILES"/*.json; then
    return 1
  fi
  grep -qE 'ns"? apply-profile' "$SETUP"
  grep -qF 'one-time local copy' "$SETUP"
  grep -qF 'Refuse `--apply` while armed' "$SETUP"
  grep -qF 'every version-1 or version-2 JSON' "$SETUP"
  grep -qF 'every version-1 or version-2 JSON file' "$BATS_TEST_DIRNAME/../docs/knobs.md"
}

@test "the documented profile versions are the ones the helper accepts" {
  grep -qF '.version == 1 or .version == 2' "$APPLY"
  for f in "$PROFILES"/*.json; do
    v="$(jq -r '.version' "$f")"
    [ "$v" = 1 ] || [ "$v" = 2 ] || { echo "$f is version $v"; return 1; }
  done
  # The shipped v2 profiles the docs name by name.
  for name in balanced fast strict; do
    [ "$(jq -r '.version' "$PROFILES/$name.json")" = 2 ] || { echo "$name is not v2"; return 1; }
  done
}

@test "Windows apply-profile usage errors name native flags" {
  ps1="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/apply-profile.ps1"
  grep -qF -- '-Mode must be replace or fill' "$ps1"
  if grep -qF '--mode must be' "$ps1"; then
    return 1
  fi
}

LOGIC="$BATS_TEST_DIRNAME/windows/apply-profile-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"

@test "Windows CI runs the portable apply-profile armed-refuse suite" {
  [ -f "$LOGIC" ]
  grep -qF 'apply-profile-logic.ps1' "$RUN"
  grep -qF 'refuse to write rules while the shift is armed' "$LOGIC"
}

@test "Windows apply-profile refuses Apply when armed if pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}

# The Doctor and Setup skills hand the model these two invocations verbatim. A form the parser
# rejects sends it back with "--mode must be replace or fill" and no profile listed.
@test "the invocations Doctor and Setup name run as written" {
  DOCTOR="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/doctor/SKILL.md"
  grep -qF -- '--list' "$DOCTOR"
  grep -qF -- '--mode fill' "$DOCTOR"
  grep -qF -- '--mode fill|replace' "$SETUP"

  p="$(new_project profiles-documented)"
  run bash "$APPLY" --project "$p" --list
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'balanced'

  for mode in fill replace; do
    run bash "$APPLY" --project "$p" --profile balanced --mode "$mode"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    printf '%s\n' "$output" | grep -qF "Mode:    $mode"
  done
}
