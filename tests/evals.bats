#!/usr/bin/env bats
# Deterministic contract evals and the contract SDK.

ROOT="$BATS_TEST_DIRNAME/.."
EVALS="$ROOT/evals"
VALIDATE="$EVALS/validate.sh"
RUN="$EVALS/run.sh"
SCHEMA_PY="$ROOT/tests/helpers/validate-json-schema.py"
IDS="$ROOT/plugins/nightshift/skills/nightshift/references/schemas/v1/identifiers.json"

@test "validate.sh is executable and prints the configured size budget" {
  [ -x "$VALIDATE" ]
  run bash "$VALIDATE"
  echo "$output"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'maxBytes=32768'
  printf '%s\n' "$output" | grep -q 'measuredBytes='
  printf '%s\n' "$output" | grep -q 'maxEstimatedTokens=8192'
  printf '%s\n' "$output" | grep -q 'measuredEstimatedTokens='
}

@test "run.sh writes a human-review report that is not a model gate" {
  [ -x "$RUN" ]
  run bash "$RUN"
  [ "$status" -eq 0 ]
  [ -f "$EVALS/reports/latest.md" ]
  [ -f "$EVALS/reports/latest.json" ]
  grep -qF 'Deterministic result: **pass**' "$EVALS/reports/latest.md"
  grep -qF 'informational model evaluation' "$EVALS/reports/latest.md"
  grep -qF 'not a release gate' "$EVALS/reports/latest.md"
  python3 "$SCHEMA_PY" "$EVALS/schema/report-v1.json" "$EVALS/reports/latest.json"
  jq -e '.informationalBaseline.gate == false' "$EVALS/reports/latest.json" >/dev/null
  jq -e '.ok == true' "$EVALS/reports/latest.json" >/dev/null
}

@test "every priority case matches the case schema" {
  python3 "$SCHEMA_PY" "$EVALS/schema/case-v1.json" "$EVALS/cases/v1.json" && return 1
  n="$(jq 'length' "$EVALS/cases/v1.json")"
  [ "$n" -ge 20 ]
  i=0
  while [ "$i" -lt "$n" ]; do
    f="$BATS_TEST_TMPDIR/case-$i.json"
    jq ".[$i]" "$EVALS/cases/v1.json" >"$f"
    python3 "$SCHEMA_PY" "$EVALS/schema/case-v1.json" "$f" \
      || { echo "case $i failed schema"; return 1; }
    i=$((i + 1))
  done
}

@test "frozen identifiers cover hosts, work modes, evidence, and capabilities" {
  jq -e '.schemaVersion == 1' "$IDS" >/dev/null
  for host in claude codex cursor; do
    jq -e --arg h "$host" '.hosts | index($h)' "$IDS" >/dev/null
  done
  jq -e '.workModes | index("repository")' "$IDS" >/dev/null
  jq -e '.workModes | index("artifact")' "$IDS" >/dev/null
  jq -e '.capabilityStatus | index("available-but-failing")' "$IDS" >/dev/null
  jq -e '.evidenceLadder | index("verified-after-change")' "$IDS" >/dev/null
}

@test "a malformed contract fails with a precise reason" {
  run bash "$VALIDATE" "$EVALS/fixtures/malformed/missing-ending.md"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'missing ending'
  run bash "$VALIDATE" "$EVALS/fixtures/malformed/broken-ref.md"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'broken reference'
}

@test "oversized instructions fail and print the budget versus the measured size" {
  f="$BATS_TEST_TMPDIR/oversized.md"
  {
    printf '%s\n' '# Oversized — finite — a contract that blows the byte budget'
    printf '%s\n' 'Use when testing the oversized-instruction check.'
    printf '%s\n' 'Supported on any repository. Never invent work.'
    printf '%s\n' '```text'
    printf '%s\n' '- [ ] **Oversized contract.**'
    printf '%s\n' '  - Ends when the validator reports oversized instructions.'
    printf '%s\n' '  - Verify: evals/validate.sh fails.'
    printf '%s\n' '```'
    python3 -c 'print("x" * 40000)'
  } >"$f"
  run bash "$VALIDATE" "$f"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'maxBytes=32768'
  printf '%s\n' "$output" | grep -q 'measuredBytes='
  printf '%s\n' "$output" | grep -q 'oversized instructions'
}

@test "an unknown case field is rejected by the schema" {
  f="$BATS_TEST_TMPDIR/bad-case.json"
  jq '.[0] + {surprise: true}' "$EVALS/cases/v1.json" >"$f"
  run python3 "$SCHEMA_PY" "$EVALS/schema/case-v1.json" "$f"
  [ "$status" -ne 0 ]
}
