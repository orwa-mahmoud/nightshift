#!/usr/bin/env bats
# The skill-scan summary is built from the scanner output already written.
# It does not start either scanner.

REPORT="$BATS_TEST_DIRNAME/skill-scan-report.py"
WF="$BATS_TEST_DIRNAME/../.github/workflows/skill-scanners.yml"
HOL="$BATS_TEST_DIRNAME/../.github/workflows/hol-plugin-scanner.yml"

@test "a passing scan names the tool, the scope, and the severity totals" {
  json="$BATS_TEST_TMPDIR/pass.json"
  cat >"$json" <<'EOF'
{"summary":{"findings_by_severity":{"critical":0,"high":0,"medium":0,"low":0,"info":0}},"results":[]}
EOF
  start=$(date +%s)
  run python3 "$REPORT" --tool "Cisco skill-scanner" --scope "plugins/nightshift/skills" --exit 0 --json "$json"
  end=$(date +%s)
  [ "$status" -eq 0 ]
  [ $((end - start)) -le 2 ]
  printf '%s\n' "$output" | grep -q '### Cisco skill-scanner'
  printf '%s\n' "$output" | grep -q 'Outcome: pass'
  printf '%s\n' "$output" | grep -q 'Scope: plugins/nightshift/skills'
  printf '%s\n' "$output" | grep -q 'high 0'
  printf '%s\n' "$output" | grep -q 'Affected skill paths: none'
}

@test "a failing scan keeps the finding path and the scanner exit" {
  json="$BATS_TEST_TMPDIR/fail.json"
  cat >"$json" <<'EOF'
{"summary":{"findings_by_severity":{"critical":0,"high":1,"medium":0,"low":0,"info":0}},
 "results":[{"skill_directory":"plugins/nightshift/skills/nightshift","findings":[
   {"severity":"high","file_path":"plugins/nightshift/skills/nightshift/SKILL.md"}]}]}
EOF
  run python3 "$REPORT" --tool "Cisco skill-scanner" --scope "plugins/nightshift/skills" --exit 1 --json "$json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'Outcome: fail'
  printf '%s\n' "$output" | grep -q 'scanner exit 1'
  printf '%s\n' "$output" | grep -q 'high 1'
  printf '%s\n' "$output" | grep -q 'plugins/nightshift/skills/nightshift/SKILL.md'
}

@test "an unrelated change is a skip and a broken filter is a classification failure" {
  run python3 "$REPORT" --tool "NVIDIA SkillSpector" --outcome skip \
    --why "No skill or scanner paths changed; the scan did not run."
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'Outcome: skip'
  printf '%s\n' "$output" | grep -q 'The scanner was not run.'
  run python3 "$REPORT" --tool "NVIDIA SkillSpector" --outcome classification-failed \
    --why "Unable to determine changed paths for the skill scan."
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'Outcome: classification-failed'
  printf '%s\n' "$output" | grep -q 'path filter did not return a decision'
}

@test "a report that is not JSON is a parse failure and invents no totals" {
  echo 'not json' >"$BATS_TEST_TMPDIR/bad.json"
  run python3 "$REPORT" --tool "Cisco skill-scanner" --exit 0 --json "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'Severity totals: unavailable'
  printf '%s\n' "$output" | grep -q 'Parse error:'
  ! printf '%s\n' "$output" | grep -q 'high 0' || false
}

@test "the workflow reports from the same scan and leaves the HOL gate alone" {
  [ "$(grep -c 'skill-scanner" scan-all' "$WF")" -eq 1 ]
  [ "$(grep -c 'skillspector" scan' "$WF")" -eq 1 ]
  grep -q -- '--fail-on-severity high' "$WF"
  grep -q 'skill-scan-report.py' "$WF"
  grep -q 'min_score: 80' "$HOL"
  grep -q 'fail_on_severity: high' "$HOL"
  grep -q 'hol-plugin-scanner.yml' "$HOL"
}
