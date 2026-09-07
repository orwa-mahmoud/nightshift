load helpers

SCHEMA="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/nightshift-rules.schema.json"
TEMPLATE="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json"
VALIDATOR="$BATS_TEST_DIRNAME/helpers/validate-json-schema.py"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/rules-schema"
KNOBS="$BATS_TEST_DIRNAME/../docs/knobs.md"
SETUP="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/setup/SKILL.md"

validate() {
  python3 "$VALIDATOR" "$SCHEMA" "$1"
}

@test "the rules schema is valid JSON and describes the shipped keys" {
  jq -e 'type == "object"' "$SCHEMA" >/dev/null
  jq -e '.additionalProperties == false' "$SCHEMA" >/dev/null
  for k in toolDeny forbiddenCommands neverCommitPatterns expectedEmail protectedDirs elevation \
    stallMax stallWarnEvery longUnitWarnMinutes watchMinutes watchRetrySeconds watchAgent receiptsAutoCommit \
    notifyCommand revivalPrompt freshRevivalPrompt clockOutMessage shift handoff archive retention; do
    jq -e --arg k "$k" '.properties | has($k)' "$SCHEMA" >/dev/null \
      || { echo "schema missing $k"; return 1; }
  done
  jq -e '.properties["$schema"]' "$SCHEMA" >/dev/null
  jq -e '.required | index("toolDeny")' "$SCHEMA" >/dev/null
  jq -e '.properties.toolDeny.required | index("AskUserQuestion")' "$SCHEMA" >/dev/null
  jq -e '.properties.toolDeny.required | index("request_user_input")' "$SCHEMA" >/dev/null
  jq -e '.properties.toolDeny.required | index("AskQuestion")' "$SCHEMA" >/dev/null
}

@test "the shipped rules template validates against the schema" {
  validate "$TEMPLATE"
}

@test "a copied rules file still validates after setup copies the template" {
  p="$(new_project)"
  validate "$p/.nightshift/rules.json"
}

@test "unknown properties, wrong types, and invalid values are rejected" {
  for f in unknown-property stallMax-string watchMinutes-negative \
    toolDeny-not-object toolDeny-value-number watchRetrySeconds-bad; do
    run validate "$FIXTURES/$f.json"
    [ "$status" -ne 0 ] || { echo "fixture should fail: $f"; return 1; }
  done
}

@test "a partial owner file with only valid keys still validates" {
  f="$BATS_TEST_TMPDIR/partial.json"
  printf '%s\n' '{"toolDeny":{"AskUserQuestion":"","request_user_input":"","AskQuestion":""},"stallMax":4,"watchMinutes":0}' >"$f"
  validate "$f"
}

@test "all three native question-tool keys are required explicitly" {
  f="$BATS_TEST_TMPDIR/missing-native-tool.json"
  printf '%s\n' '{"toolDeny":{"AskUserQuestion":"park"}}' >"$f"
  run validate "$f"
  [ "$status" -ne 0 ]
  printf '%s\n' '{"toolDeny":{"AskUserQuestion":"park","request_user_input":"park"}}' >"$f"
  run validate "$f"
  [ "$status" -ne 0 ]
  printf '%s\n' '{"stallMax":4}' >"$f"
  run validate "$f"
  [ "$status" -ne 0 ]
}

@test "elevation carries all five categories, closed to any other" {
  jq -e '.properties.elevation.additionalProperties == false' "$SCHEMA" >/dev/null
  for c in sudo containers global-packages daemons external-services; do
    jq -e --arg c "$c" '.properties.elevation.properties | has($c)' "$SCHEMA" >/dev/null \
      || { echo "schema missing elevation.$c"; return 1; }
    jq -e --arg c "$c" '
      .properties.elevation.properties[$c]
      | .additionalProperties == false
        and (.required | index("policy"))
        and (.properties.policy.enum == ["deny", "allow"])
        and (.properties.pattern.type == "string")
    ' "$SCHEMA" >/dev/null || { echo "elevation.$c is not policy+pattern"; return 1; }
  done
}

@test "the template denies every category and ships the pattern the owner can edit" {
  ere_ok() {
    printf '' | grep -qE "$1" 2>/dev/null
    [ "$?" -le 1 ]
  }
  for c in sudo containers global-packages daemons external-services; do
    jq -e --arg c "$c" '.elevation[$c].policy == "deny"' "$TEMPLATE" >/dev/null \
      || { echo "template does not deny $c"; return 1; }
    pat="$(jq -r --arg c "$c" '.elevation[$c].pattern' "$TEMPLATE")"
    [ -n "$pat" ] || { echo "template has no pattern for $c"; return 1; }
    ere_ok "$pat" || { echo "template pattern for $c is not a valid ERE"; return 1; }
  done
  # forbiddenCommands stays the owner's own list; the categories are the visible switch.
  jq -e '.forbiddenCommands == ""' "$TEMPLATE" >/dev/null
}

@test "the shipped patterns match the commands they name and leave ordinary work alone" {
  match() { # <category> <command>
    printf '%s' "$2" | grep -qE "$(jq -r --arg c "$1" '.elevation[$c].pattern' "$TEMPLATE")"
  }
  match sudo 'sudo apt-get install ripgrep'
  match sudo '/usr/bin/sudo id'
  match sudo 'sudo;id'
  match sudo "sh -c 'sudo apt-get install -y jq'"
  match sudo "eval 'sudo id'"
  match containers 'docker compose up -d'
  match containers 'docker run alpine'
  match containers 'docker create alpine'
  match containers 'docker start web'
  match containers 'docker build .'
  match containers 'podman run alpine'
  match containers 'curl --unix-socket /var/run/docker.sock http://localhost/info'
  match global-packages 'npm install -g pnpm'
  match global-packages 'pip3 install --user black'
  match global-packages 'pip install black'
  match global-packages 'cargo install ripgrep'
  match global-packages 'go install example.com/cmd@latest'
  match global-packages 'brew install shellcheck'
  match global-packages 'apt-get upgrade jq'
  match daemons 'systemctl start postgres'
  match external-services 'gh auth login'
  if match containers 'docker ps'; then
    return 1
  fi
  if match containers 'docker logs web'; then
    return 1
  fi
  if match containers 'npm test'; then
    return 1
  fi
  if match global-packages 'brew list'; then
    return 1
  fi
  if match sudo 'psql -h localhost -c "select 1"'; then
    return 1
  fi
  if match daemons 'pytest tests/'; then
    return 1
  fi
}

@test "an unknown category, an unknown field, and a bad policy are rejected" {
  for f in elevation-unknown-category elevation-unknown-field elevation-bad-policy \
    elevation-missing-policy elevation-empty-pattern; do
    run validate "$FIXTURES/$f.json"
    [ "$status" -ne 0 ] || { echo "fixture should fail: $f"; return 1; }
  done
}

@test "rules without an elevation object still validate" {
  f="$BATS_TEST_TMPDIR/no-elevation.json"
  printf '%s\n' '{"toolDeny":{"AskUserQuestion":"","request_user_input":"","AskQuestion":""}}' >"$f"
  validate "$f"
}

@test "knobs and setup document editor discovery of the schema" {
  grep -qF 'nightshift-rules.schema.json' "$KNOBS"
  grep -qF 'json.schemas' "$KNOBS"
  grep -qF '.nightshift/rules.json' "$KNOBS"
  grep -qF 'nightshift-rules.schema.json' "$SETUP"
  grep -qF 'docs/knobs.md' "$SETUP"
}

@test "a numeric bound applies to numbers and says nothing about null" {
  # A nullable field carrying a bound has to validate when it is unset. Its `type` is what
  # rejects a wrong type; `minimum` is only about numbers.
  f="$BATS_TEST_TMPDIR/hours.json"
  jq '.shift.hours = null' "$TEMPLATE" >"$f"
  validate "$f"
  jq '.shift.hours = 1' "$TEMPLATE" >"$f"
  validate "$f"
  jq '.shift.hours = 6' "$TEMPLATE" >"$f"
  validate "$f"

  # And the bound still bites where it applies.
  jq '.shift.hours = 0' "$TEMPLATE" >"$f"
  run validate "$f"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'below minimum 1'
  jq '.shift.hours = -3' "$TEMPLATE" >"$f"
  run validate "$f"
  [ "$status" -ne 0 ]
  # A wrong type is still a wrong type, and it is `type` that says so.
  jq '.shift.hours = "six"' "$TEMPLATE" >"$f"
  run validate "$f"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'expected integer|null'
}
