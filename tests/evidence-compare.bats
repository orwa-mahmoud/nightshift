#!/usr/bin/env bats
# The evidence comparison: how a baseline scores against the ledger as it stands now.

bats_require_minimum_version 1.5.0

ROOT="$BATS_TEST_DIRNAME/.."
EC="$ROOT/plugins/nightshift/runtime/evidence-compare.sh"
EV="$ROOT/plugins/nightshift/runtime/evidence.sh"
SP="$ROOT/plugins/nightshift/runtime/shift-policy.sh"
SCHEMAS="$ROOT/plugins/nightshift/skills/nightshift/references/schemas/v1"
VALIDATOR="$BATS_TEST_DIRNAME/helpers/validate-json-schema.py"

load helpers

# The comparison renders a clock into its verdict line, so every run pins one.
setup() { export NIGHTSHIFT_EVIDENCE_NOW=2026-09-02T00:00:00Z; }

# ---------------------------------------------------------------------------------------------
# Fixtures. Every record is built here, never spelled out at a call site, so one change of the
# ledger contract is one change of these functions.

# finding_json <id> <status> <digest> [locator] — one finding of the eslint source.
finding_json() {
  jq -nc --arg id "$1" --arg status "$2" --arg digest "$3" \
    --arg locator "${4:-src/app.js:1}" '{
      schemaVersion: 1, id: $id, domain: "lint", sourceClass: "eslint", source: "eslint .",
      scope: "src/", severity: "medium", confidence: "high", impact: "developer",
      status: $status, ladder: "observed", locator: $locator, digest: $digest,
      firstSeen: "2026-09-02T00:00:00Z", lastChecked: "2026-09-02T00:00:00Z",
      action: "", host: "claude", workTarget: "/repo"
    }'
}

# deduped_json <id> <status> <sourceClass> <digest> <tool> <tool> — one finding two tools found.
deduped_json() {
  jq -nc --arg id "$1" --arg status "$2" --arg cls "$3" --arg digest "$4" \
    --arg a "$5" --arg b "$6" '{
      schemaVersion: 1, id: $id, domain: "lint", sourceClass: $cls, source: ($cls + " ."),
      scope: "src/", severity: "high", confidence: "high", impact: "developer",
      status: $status, ladder: "observed", locator: "src/dupe.js:2", digest: $digest,
      firstSeen: "2026-09-02T00:00:00Z", lastChecked: "2026-09-02T00:00:00Z",
      action: "", host: "claude", workTarget: "/repo", sources: [$a, $b]
    }'
}

# baseline_json <id> <status> <env-digest> [id=digest ...] — one baseline of the eslint source.
baseline_json() {
  local id="$1" status="$2" env="$3" pairs="" one
  shift 3
  for one in "$@"; do
    pairs="$pairs${pairs:+,}$one"
  done
  jq -nc --arg id "$id" --arg status "$status" --arg env "$env" --arg pairs "$pairs" '{
    schemaVersion: 1, id: $id, domain: "baseline", sourceClass: "eslint",
    source: "eslint .", scope: "src/", severity: "info", confidence: "high",
    impact: "developer", status: $status, ladder: "measured", locator: "src/",
    digest: ("digest-" + $id), firstSeen: "2026-09-02T00:00:00Z",
    lastChecked: "2026-09-02T00:00:00Z", action: "", host: "claude", workTarget: "/repo",
    details: {
      sourceCommand: "eslint .", environmentDigest: $env, rawDigest: ("raw-" + $id),
      seen: ($pairs | if . == "" then [] else split(",") end
            | map(split("=") | { id: .[0], digest: .[1] }))
    }
  }'
}

# append <project> <record> — one record onto the ledger, refusing silence on a rejection.
append() {
  local p="$1" rec="$2"
  bash "$EV" --project "$p" append --record "$rec" >/dev/null
}

# dispose <project> <id> <disposition> — the ledger's own disposition verb.
dispose() {
  bash "$EV" --project "$1" disposition "$2" "$3" >/dev/null
}

# ledger <project> — an initialised, empty ledger.
ledger() {
  bash "$EV" --project "$1" init >/dev/null
}

# policy_mode <project> <completionMode> [id ...] — tonight's completion mode and selected debt,
# written the way composition writes it. A shift control file is never written from a command
# string; this is the one place the document is composed.
policy_mode() {
  local p="$1" mode="$2" ids="" one
  shift 2
  for one in "$@"; do
    ids="$ids${ids:+,}$one"
  done
  jq -n --arg mode "$mode" --arg ids "$ids" '{
    schemaVersion: 1, shiftId: "9f2c40ab77e51d63", createdAt: "2026-09-02T00:00:00Z",
    source: "composition", deadlineEpoch: null, verificationLevel: "final",
    toolingPolicy: "existing-tools", completionMode: $mode,
    selectedDebt: ($ids | if . == "" then [] else split(",") end)
  }' >"$p/.nightshift/shift-policy.json"
}

# unarmed_project <name> — a project whose gate has not been armed, so composition may still
# write tonight's policy through the helper.
unarmed_project() {
  local p
  p="$(new_project "$1")"
  rm -f "$p/.nightshift/.shift-armed"
  printf '%s' "$p"
}

# policy_candidate_bad_debt <project> — a candidate policy whose debt list is not all ids.
policy_candidate_bad_debt() {
  jq -n '{
    schemaVersion: 1, shiftId: "9f2c40ab77e51d63", createdAt: "2026-09-02T00:00:00Z",
    source: "composition", verificationLevel: "final", toolingPolicy: "existing-tools",
    selectedDebt: ["f1", 7]
  }' >"$1/candidate.json"
}

# compare <project> <baseline> [flag] — the comparison, through bats' run.
compare() {
  local p="$1" id="$2"
  shift 2
  bash "$EC" --project "$p" --baseline "$id" "$@"
}

# every_class <project> — a ledger of the eslint source carrying one finding of every class.
# c1 fixed, u1 untouched, r1 re-reported with another digest, h1 for a human only, p1 parked,
# d1 rejected as a duplicate of what tsc found, x1 unmeasured, g1 gone from the re-measurement,
# and n1 that the baseline never saw. b2 is the re-measurement: same environment, and it still
# reports r1 and n1.
every_class() {
  local p="$1"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1 \
    c1=dc1 u1=du1 r1=dr1 h1=dh1 p1=dp1 d1=dd1 x1=dx1 g1=dg1)"
  append "$p" "$(finding_json c1 fixed dc1)"
  append "$p" "$(finding_json u1 open du1)"
  append "$p" "$(finding_json r1 open dr2)"
  append "$p" "$(finding_json h1 human-only dh1)"
  append "$p" "$(finding_json p1 open dp1)"
  append "$p" "$(deduped_json d1 rejected eslint dd1 eslint tsc)"
  append "$p" "$(finding_json x1 unmeasured dx1)"
  append "$p" "$(finding_json n1 open dn1)"
  dispose "$p" p1 parked
  dispose "$p" d1 duplicate
  append "$p" "$(baseline_json b2 open env-1 r1=dr2 n1=dn1)"
}

# class_of <id> — the class the last --json output gave that id.
class_of() {
  printf '%s\n' "$output" | jq -r --arg id "$1" '.rows[] | select(.id == $id) | .class'
}

# ---------------------------------------------------------------------------------------------

@test "every class is decided by the record and the baseline that carry it" {
  p="$(new_project ec-classes)"
  every_class "$p"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  [ "$(class_of c1)" = cleared ]
  [ "$(class_of u1)" = unchanged ]
  [ "$(class_of r1)" = regressed ]
  [ "$(class_of h1)" = human-only ]
  [ "$(class_of p1)" = parked ]
  [ "$(class_of d1)" = rejected-duplicate ]
  [ "$(class_of x1)" = unavailable ]
  [ "$(class_of g1)" = cleared ]
  [ "$(class_of n1)" = new ]
  printf '%s\n' "$output" | jq -e '.summary == {
    "cleared": 2, "human-only": 1, "new": 1, "parked": 1, "regressed": 1,
    "rejected-duplicate": 1, "selectedDebtOutstanding": [], "total": 9,
    "unavailable": 1, "unchanged": 1
  }' >/dev/null
  printf '%s\n' "$output" | jq -e '.pass == false and .mode == "clear-all"' >/dev/null
}

# A tool-output finding carries the digest of its result, not of the file the tool wrote.
# The two are different facts: rerunning a linter rewrites the file byte for byte while the
# counts stand still, and a comparison that reads the file digest calls that a regression.
@test "a tool-output digest survives a rerun and moves when the counts do" {
  NORMALIZE="$ROOT/plugins/nightshift/runtime/normalize-output.sh"
  RAW="$BATS_TEST_DIRNAME/fixtures/normalize/eslint-json/sample.json"
  cp "$RAW" "$BATS_TEST_TMPDIR/before.json"
  jq -c . <"$RAW" >"$BATS_TEST_TMPDIR/rerun.json"
  jq -c '[.[] | .messages |= map(select(.severity != 2))]' <"$RAW" >"$BATS_TEST_TMPDIR/after.json"
  cmp -s "$BATS_TEST_TMPDIR/before.json" "$BATS_TEST_TMPDIR/rerun.json" \
    && { echo 'the rerun is byte-identical, so it proves nothing'; return 1; }

  digest_of_run() {
    bash "$NORMALIZE" --format eslint-json --input "$1" --json | jq -r .digest
  }
  before="$(digest_of_run "$BATS_TEST_TMPDIR/before.json")"
  rerun="$(digest_of_run "$BATS_TEST_TMPDIR/rerun.json")"
  after="$(digest_of_run "$BATS_TEST_TMPDIR/after.json")"
  [ "$before" = "$rerun" ] || { echo 'the same counts gave two digests'; return 1; }
  [ "$before" != "$after" ] || { echo 'dropped counts kept one digest'; return 1; }

  # Only the raw bytes moved: still reported, with the digest the baseline recorded.
  p="$(new_project ec-tool-rerun)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1 "eslint-lint=$before")"
  append "$p" "$(finding_json eslint-lint open "$rerun")"
  run compare "$p" b1 --json
  [ "$(class_of eslint-lint)" = unchanged ] \
    || { echo "a rerun scored $(class_of eslint-lint)"; return 1; }

  # The counts dropped and the work is done: that is improvement, and it is scored as such.
  q="$(new_project ec-tool-fixed)"
  ledger "$q"
  append "$q" "$(baseline_json b1 open env-1 "eslint-lint=$before")"
  append "$q" "$(finding_json eslint-lint fixed "$after")"
  run compare "$q" b1 --json
  [ "$(class_of eslint-lint)" = cleared ] \
    || { echo "a fix scored $(class_of eslint-lint)"; return 1; }
  printf '%s\n' "$output" | jq -e '.pass == true and .summary.cleared == 1' >/dev/null
}

@test "the JSON carries exactly the documented keys, sorted, one line, one newline" {
  p="$(new_project ec-keys)"
  every_class "$p"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  [ "$(printf '%s\n' "$output" | jq -r 'keys_unsorted | join(",")')" \
    = "baseline,mode,pass,rows,schemaVersion,sourceStatus,summary" ]
  [ "$(printf '%s\n' "$output" | jq -r '.rows[0] | keys_unsorted | join(",")')" \
    = "class,digest,id,locator,sources" ]
  [ "$(printf '%s\n' "$output" | jq -r '.summary | keys_unsorted | join(",")')" \
    = "cleared,human-only,new,parked,regressed,rejected-duplicate,selectedDebtOutstanding,total,unavailable,unchanged" ]
  [ "$(printf '%s\n' "$output" | jq -r '.baseline')" = b1 ]
  [ "$(printf '%s\n' "$output" | jq -r '.schemaVersion')" = 1 ]
  # Rows in byte order by id, and the document on one line ending in exactly one newline.
  [ "$(printf '%s\n' "$output" | jq -r '[.rows[].id] == ([.rows[].id] | sort)')" = true ]
  bash "$EC" --project "$p" --baseline b1 --json >"$BATS_TEST_TMPDIR/keys.json" || { [ $? -eq 3 ]; }
  [ "$(wc -l <"$BATS_TEST_TMPDIR/keys.json")" -eq 1 ]
}

@test "the Markdown table names the same rows and ends in one summary line" {
  p="$(new_project ec-md)"
  every_class "$p"
  bash "$EC" --project "$p" --baseline b1 --md >"$BATS_TEST_TMPDIR/compare.md" || { [ $? -eq 3 ]; }
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/compare.md")" = '# Comparison' ]
  grep -qF '| ID | Class | Digest | Sources | Locator |' "$BATS_TEST_TMPDIR/compare.md"
  grep -qF 'Mode: clear-all' "$BATS_TEST_TMPDIR/compare.md"
  grep -qF 'Result: fail' "$BATS_TEST_TMPDIR/compare.md"
  grep -qF '| u1 | unchanged | du1 | eslint | src/app.js:1 |' "$BATS_TEST_TMPDIR/compare.md"
  grep -qF '| d1 | rejected-duplicate | dd1 | eslint, tsc | src/dupe.js:2 |' \
    "$BATS_TEST_TMPDIR/compare.md"
  grep -qF 'Summary: new 1, cleared 2, unchanged 1, regressed 1, unavailable 1, rejected-duplicate 1, parked 1, human-only 1' \
    "$BATS_TEST_TMPDIR/compare.md"
  [ "$(grep -c '^| ' "$BATS_TEST_TMPDIR/compare.md")" -eq 11 ]
}

@test "a tool that cannot run is never an improvement" {
  p="$(new_project ec-unavailable)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1 i1=di1 i2=di2)"
  append "$p" "$(finding_json i1 fixed di1)"
  append "$p" "$(finding_json i2 fixed di2)"
  run compare "$p" b1 --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.pass == true and .summary.cleared == 2' >/dev/null
  # The rerun cannot run the tool, so the source reports itself unavailable.
  append "$p" "$(baseline_json b2 unavailable env-1)"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '.summary.cleared == 0 and .summary.unavailable == 2' >/dev/null
  printf '%s\n' "$output" | jq -e '[.rows[].class] | unique == ["unavailable"]' >/dev/null
  printf '%s\n' "$output" | jq -e '.pass == false' >/dev/null
}

@test "an environment that moved makes every finding of the source unavailable" {
  p="$(new_project ec-environment)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1 e1=de1 e2=de2)"
  append "$p" "$(finding_json e1 fixed de1)"
  append "$p" "$(finding_json e2 fixed de2)"
  append "$p" "$(baseline_json b2 open env-2)"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '[.rows[].class] | unique == ["unavailable"]' >/dev/null
  printf '%s\n' "$output" | jq -e '.summary.cleared == 0 and .pass == false' >/dev/null
}

@test "environment-moved absence is unavailable, not cleared" {
  p="$(new_project ec-env-absence)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1 gone1=dg1)"
  append "$p" "$(baseline_json b2 open env-2)"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  [ "$(class_of gone1)" = unavailable ]
  printf '%s\n' "$output" | jq -e '.summary.cleared == 0 and .pass == false' >/dev/null
}

@test "an id no record and no re-measurement speaks for is unavailable, not cleared" {
  p="$(new_project ec-unmeasured)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1 q1=dq1)"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  [ "$(class_of q1)" = unavailable ]
  printf '%s\n' "$output" | jq -e '.pass == false' >/dev/null
}

@test "clear-all passes only when every measured finding is cleared" {
  p="$(new_project ec-clear-all)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1 k1=dk1 k2=dk2)"
  append "$p" "$(finding_json k1 fixed dk1)"
  append "$p" "$(finding_json k2 open dk2)"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '.mode == "clear-all" and .pass == false' >/dev/null
  [ "$(class_of k2)" = unchanged ]
  append "$p" "$(finding_json k2 fixed dk2)"
  run compare "$p" b1 --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.pass == true and .summary.cleared == 2' >/dev/null
}

@test "no-regression-plus-selected-debt passes on the debt the owner selected" {
  p="$(new_project ec-debt)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1 k1=dk1 k2=dk2)"
  append "$p" "$(finding_json k1 fixed dk1)"
  append "$p" "$(finding_json k2 open dk2)"
  policy_mode "$p" no-regression-plus-selected-debt k1
  run compare "$p" b1 --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" \
    | jq -e '.mode == "no-regression-plus-selected-debt" and .pass == true' >/dev/null
  # The same ledger fails clear-all: k2 is still open.
  policy_mode "$p" clear-all
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '.pass == false' >/dev/null
  # Debt the shift did not clear fails its own mode.
  policy_mode "$p" no-regression-plus-selected-debt k1 k2
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '.pass == false' >/dev/null
  # And a regression fails it whatever the debt says.
  policy_mode "$p" no-regression-plus-selected-debt k1
  append "$p" "$(finding_json k2 open dk3)"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  [ "$(class_of k2)" = regressed ]
  printf '%s\n' "$output" | jq -e '.pass == false' >/dev/null
}

@test "an absent or unreadable policy scores the strict mode" {
  p="$(new_project ec-default-mode)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1 k1=dk1)"
  append "$p" "$(finding_json k1 open dk1)"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '.mode == "clear-all" and .pass == false' >/dev/null
  printf 'not a policy\n' >"$p/.nightshift/shift-policy.json"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '.mode == "clear-all"' >/dev/null
}

@test "same-root-cause dedupe keeps every originating tool in the row" {
  p="$(new_project ec-dedupe)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1 y1=dy1)"
  append "$p" "$(deduped_json y1 fixed eslint dy1 eslint tsc)"
  append "$p" "$(deduped_json y2 rejected tsc dy2 tsc eslint)"
  dispose "$p" y2 duplicate
  run compare "$p" b1 --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    [.rows[] | select(.id == "y1") | .sources] == [["eslint", "tsc"]]' >/dev/null
  # The record tsc raised is in scope because it kept eslint in sources, and it is reported as
  # the duplicate it is — never erased.
  [ "$(class_of y2)" = rejected-duplicate ]
  printf '%s\n' "$output" | jq -e '
    [.rows[] | select(.id == "y2") | .sources] == [["eslint", "tsc"]]' >/dev/null
}

@test "the shift policy accepts the completion mode and the selected debt" {
  p="$(unarmed_project ec-policy)"
  policy_mode "$p" no-regression-plus-selected-debt f1 f2
  run bash "$SP" --project "$p" set --from-json "$p/.nightshift/shift-policy.json"
  [ "$status" -eq 0 ]
  python3 "$VALIDATOR" "$SCHEMAS/shift-policy.json" "$p/.nightshift/shift-policy.json"
  # The two fields score findings; they grant nothing, so the resolved view stays silent.
  run bash "$SP" --project "$p" resolve --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.settings | has("completionMode") | not' >/dev/null
  printf '%s\n' "$output" | jq -e '.settings | has("selectedDebt") | not' >/dev/null
}

@test "the shift policy refuses a mode or a debt list it cannot score" {
  p="$(unarmed_project ec-policy-bad)"
  policy_mode "$p" clear-most
  run bash "$SP" --project "$p" set --from-json "$p/.nightshift/shift-policy.json"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'completionMode must be clear-all or no-regression-plus-selected-debt'
  policy_candidate_bad_debt "$p"
  run bash "$SP" --project "$p" set --from-json "$p/candidate.json"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'selectedDebt[1] must be a finding id'
}

@test "the finding schema declares the two lifecycle domains and their details" {
  jq -e '.lifecycleDomains == ["baseline", "checkpoint"]' "$SCHEMAS/finding.json" >/dev/null
  jq -e '.details.baseline
         == ["command", "environmentDigest", "rawDigest", "scope", "seen", "sourceClass", "versions"]' \
    "$SCHEMAS/finding.json" >/dev/null
  jq -e '.details.checkpoint | index("baseline") != null' "$SCHEMAS/finding.json" >/dev/null
  # The required set is unchanged: a lifecycle record is an ordinary record with details.
  jq -e '.required | length == 18 and (index("details") == null)' \
    "$SCHEMAS/finding.json" >/dev/null
}

@test "a baseline the ledger does not carry is refused, and so is a finding named as one" {
  p="$(new_project ec-refusals)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1 k1=dk1)"
  append "$p" "$(finding_json k1 open dk1)"
  run --separate-stderr compare "$p" nope --json
  [ "$status" -eq 2 ]
  printf '%s\n' "$stderr" | grep -qF 'no baseline record with id nope'
  run --separate-stderr compare "$p" k1 --json
  [ "$status" -eq 2 ]
  printf '%s\n' "$stderr" | grep -qF 'k1 is not a baseline record'
  run --separate-stderr bash "$EC" --project "$p"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -qF 'usage: evidence-compare.sh --project DIR --baseline ID'
}

@test "a workspace with no ledger and a ledger line that is not JSON are both named" {
  p="$(new_project ec-no-ledger)"
  run --separate-stderr compare "$p" b1 --json
  [ "$status" -eq 2 ]
  printf '%s\n' "$stderr" | grep -qF 'no ledger at'
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1 k1=dk1)"
  printf '%s\n' '{not json' >>"$p/.nightshift/evidence/findings.jsonl"
  run --separate-stderr compare "$p" b1 --json
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -qF 'malformed JSON on line 2'
}

# ---------------------------------------------------------------------------------------------
# Engine parity: the comparison reads JSON through jq or through python3, and the two halves must
# render the same bytes for the same ledger. controlled_bin, resolve_tool_path and
# build_toolset_bin come from tests/helpers.bash.

COMPARE_TOOLSET_WITH_JQ="bash sh jq git sed grep find sort ls awk cat tr head tail wc cut mkdir cp rm mv env cmp date uname test dirname basename readlink stat printf true false xargs mktemp chmod"
COMPARE_TOOLSET_NO_JQ="bash sh git sed grep find sort ls awk cat tr head tail wc cut mkdir cp rm mv env cmp date uname test dirname basename readlink stat printf true false xargs mktemp chmod"

@test "the jq and python3 halves render identical JSON and Markdown" {
  p="$(new_project ec-parity)"
  every_class "$p"
  policy_mode "$p" no-regression-plus-selected-debt c1 g1

  jqbin="$(build_toolset_bin ec-jq-bin $COMPARE_TOOLSET_WITH_JQ)"
  [ ! -e "$jqbin/python3" ]
  pybin="$(build_toolset_bin ec-py-bin $COMPARE_TOOLSET_NO_JQ)"
  [ ! -e "$pybin/jq" ]
  pyonly="$(build_toolset_bin ec-py-only python3)"
  [ ! -e "$pyonly/jq" ]

  for format in --json --md; do
    env PATH="$jqbin" bash "$EC" --project "$p" --baseline b1 "$format" \
      >"$BATS_TEST_TMPDIR/jq$format" 2>"$BATS_TEST_TMPDIR/jq$format.err" \
      || { [ $? -eq 3 ]; }
    env PATH="$pybin:$pyonly" bash "$EC" --project "$p" --baseline b1 "$format" \
      >"$BATS_TEST_TMPDIR/py$format" 2>"$BATS_TEST_TMPDIR/py$format.err" \
      || { [ $? -eq 3 ]; }
    cmp "$BATS_TEST_TMPDIR/jq$format" "$BATS_TEST_TMPDIR/py$format"
    cmp "$BATS_TEST_TMPDIR/jq$format.err" "$BATS_TEST_TMPDIR/py$format.err"
    [ -s "$BATS_TEST_TMPDIR/jq$format" ]
  done
  grep -qF '"mode":"no-regression-plus-selected-debt"' "$BATS_TEST_TMPDIR/jq--json"
}

@test "the comparison needs jq or python3 on PATH" {
  p="$(new_project ec-neither)"
  every_class "$p"
  bin="$(build_toolset_bin ec-neither-bin $COMPARE_TOOLSET_NO_JQ)"
  [ ! -e "$bin/jq" ]
  [ ! -e "$bin/python3" ]
  run --separate-stderr env PATH="$bin" bash "$EC" --project "$p" --baseline b1 --json
  [ "$status" -eq 2 ]
  printf '%s\n' "$stderr" | grep -qF 'JSON parser unavailable; compare in the skill'
}

@test "the comparison writes nothing" {
  p="$(new_project ec-readonly)"
  every_class "$p"
  before="$(find "$p/.nightshift" -type f | LC_ALL=C sort)"
  digest_before="$(cat "$p/.nightshift/evidence/findings.jsonl")"
  bash "$EC" --project "$p" --baseline b1 --json >/dev/null || { [ $? -eq 3 ]; }
  bash "$EC" --project "$p" --baseline b1 --md >/dev/null || [ $? -eq 3 ]
  [ "$(find "$p/.nightshift" -type f | LC_ALL=C sort)" = "$before" ]
  [ "$(cat "$p/.nightshift/evidence/findings.jsonl")" = "$digest_before" ]
}

@test "compare temps are created mode 700" {
  grep -qF 'mktemp -d' "$EC"
  grep -qF 'chmod 700' "$EC"
}

# ---------------------------------------------------------------------------------------------
# The source answers for itself. A tool that could not run reports nothing whether or not the
# baseline had seen anything, so clear-all cannot read its silence as a clean sheet — and the
# answer travels as sourceStatus rather than as an invented row.

@test "an unavailable source with nothing to report never passes clear-all" {
  p="$(new_project ec-unavailable-empty)"
  ledger "$p"
  append "$p" "$(baseline_json b1 unavailable env-1)"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '.pass == false' >/dev/null
  printf '%s\n' "$output" | jq -e '.sourceStatus == "unavailable"' >/dev/null
  # No row is manufactured to carry the status, so the counts stay honest.
  printf '%s\n' "$output" | jq -e '.rows == [] and .summary.total == 0' >/dev/null
}

@test "a source that ran and found nothing is still a pass" {
  p="$(new_project ec-clean-empty)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1)"
  run compare "$p" b1 --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.pass == true and .sourceStatus == "available"' >/dev/null
}

@test "a clean empty measurement followed by a failed recheck stops passing" {
  p="$(new_project ec-empty-then-failed)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1)"
  run compare "$p" b1 --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.pass == true' >/dev/null
  # The next run of the same source could not complete.
  append "$p" "$(baseline_json b2 unavailable env-1)"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '.pass == false and .sourceStatus == "unavailable"' >/dev/null
}

@test "an environment that moved with nothing to report fails clear-all too" {
  p="$(new_project ec-env-empty)"
  ledger "$p"
  append "$p" "$(baseline_json b1 open env-1)"
  append "$p" "$(baseline_json b2 open env-2)"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '.pass == false and .sourceStatus == "unavailable"' >/dev/null
}

@test "no-regression keeps its own rule when a source with no rows is unavailable" {
  # This mode promises no regression and the owner's selected ids cleared. It carries no debt
  # here and nothing regressed, so its verdict is unchanged — the status is still reported.
  p="$(new_project ec-noreg-empty)"
  ledger "$p"
  policy_mode "$p" no-regression-plus-selected-debt
  append "$p" "$(baseline_json b1 unavailable env-1)"
  run compare "$p" b1 --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.pass == true and .sourceStatus == "unavailable"' >/dev/null
}

@test "no-regression still refuses to clear selected debt an unavailable source never measured" {
  p="$(new_project ec-noreg-debt)"
  ledger "$p"
  policy_mode "$p" no-regression-plus-selected-debt d1
  append "$p" "$(baseline_json b1 unavailable env-1 d1=dd1)"
  run compare "$p" b1 --json
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | jq -e '.pass == false' >/dev/null
  printf '%s\n' "$output" | jq -e '.summary.selectedDebtOutstanding == ["d1"]' >/dev/null
}

@test "both renderings carry the same source status" {
  p="$(new_project ec-status-md)"
  ledger "$p"
  append "$p" "$(baseline_json b1 unavailable env-1)"
  bash "$EC" --project "$p" --baseline b1 --md >"$BATS_TEST_TMPDIR/status.md" || { [ $? -eq 3 ]; }
  grep -qF 'Source: unavailable' "$BATS_TEST_TMPDIR/status.md"
  grep -qF 'Result: fail' "$BATS_TEST_TMPDIR/status.md"
  # The placeholder row says why the table is empty rather than calling the source clean.
  grep -qF '| — | — | — | — | unavailable |' "$BATS_TEST_TMPDIR/status.md"

  q="$(new_project ec-status-md-ok)"
  ledger "$q"
  append "$q" "$(baseline_json b1 open env-1)"
  bash "$EC" --project "$q" --baseline b1 --md >"$BATS_TEST_TMPDIR/ok.md"
  grep -qF 'Source: available' "$BATS_TEST_TMPDIR/ok.md"
  grep -qF '| — | — | — | — | empty |' "$BATS_TEST_TMPDIR/ok.md"
}
