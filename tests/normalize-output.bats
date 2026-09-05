#!/usr/bin/env bats
# normalize-output turns one tool's raw output into one compact summary a model can read
# instead of the file, and that two nights can diff byte for byte. The golden fixtures are
# the contract: a change to the shape of a summary changes them, deliberately.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
SH="$PLUGIN/runtime/normalize-output.sh"
PS1_TWIN="$PLUGIN/runtime/windows/normalize-output.ps1"
LOGIC="$BATS_TEST_DIRNAME/windows/normalize-output-logic.ps1"
RUN_PS1="$BATS_TEST_DIRNAME/windows/run.ps1"
FIX="$BATS_TEST_DIRNAME/fixtures/normalize"
PWSH_BIN="$(command -v pwsh 2>/dev/null || true)"

FORMATS="eslint-json tsc coverage-summary sarif npm-audit junit lcov"
CASES="sample edge broken"

# Every format carries the three shared cases; a format whose parser has a shape of
# its own carries more. all_cases is what every loop over the fixtures reads.
all_cases() {
  case "$1" in
    eslint-json) printf '%s strings' "$CASES" ;;
    tsc) printf '%s continuation pretty colour summary-only partial watch clean' "$CASES" ;;
    coverage-summary) printf '%s unmeasured' "$CASES" ;;
    sarif) printf '%s wide' "$CASES" ;;
    junit) printf '%s nested cdata truncated cut mismatched torn-cdata torn-comment empty-suite no-counts' "$CASES" ;;
    lcov) printf '%s unmeasured' "$CASES" ;;
    *) printf '%s' "$CASES" ;;
  esac
}

# The exit code a case is held to, read from its own golden: an unavailable summary
# is one line and exit 3, anything else is a summary and exit 0.
expected_status() {
  case "$(head -1 "$FIX/$1/$2.expected.md")" in
    unavailable*) printf 3 ;;
    *) printf 0 ;;
  esac
}

# The extension a fixture case carries, so the goldens can sit beside their input.
fixture_input() {
  local fmt="$1" name="$2" f
  for f in "$FIX/$fmt/$name".*; do
    case "$f" in *.expected.*) continue ;; esac
    printf '%s' "tests/fixtures/normalize/$fmt/${f##*/}"
    return 0
  done
  return 1
}

# bash 3.2 is the floor this plugin supports, so every run goes through /bin/bash.
normalize() {
  run /bin/bash "$SH" "$@"
}

# Whichever sha256 tool this host carries; the helper picks the same one.
digest_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum <"$1" | cut -d' ' -f1
  else
    shasum -a 256 <"$1" | cut -d' ' -f1
  fi
}

@test "every format renders its golden markdown summary" {
  cd "$ROOT"
  for fmt in $FORMATS; do
    for name in $(all_cases "$fmt"); do
      input="$(fixture_input "$fmt" "$name")"
      want="$(expected_status "$fmt" "$name")"
      normalize --format "$fmt" --input "$input"
      [ "$status" -eq "$want" ] \
        || { echo "$fmt/$name expected exit $want, got $status"; return 1; }
      printf '%s\n' "$output" | diff - "$FIX/$fmt/$name.expected.md" \
        || { echo "$fmt/$name markdown drifted"; return 1; }
    done
  done
}

@test "every format renders its golden canonical JSON summary" {
  cd "$ROOT"
  for fmt in $FORMATS; do
    for name in $(all_cases "$fmt"); do
      input="$(fixture_input "$fmt" "$name")"
      normalize --format "$fmt" --input "$input" --json
      printf '%s\n' "$output" | diff - "$FIX/$fmt/$name.expected.json" \
        || { echo "$fmt/$name JSON drifted"; return 1; }
    done
  done
}

@test "the JSON summary is one canonical object with sorted keys" {
  cd "$ROOT"
  for fmt in $FORMATS; do
    for name in $(all_cases "$fmt"); do
      [ "$(expected_status "$fmt" "$name")" -eq 0 ] || continue
      input="$(fixture_input "$fmt" "$name")"
      normalize --format "$fmt" --input "$input" --json
      [ "$status" -eq 0 ]
      [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
      printf '%s' "$output" | jq -e '
        .version == 1 and (.digest | test("^[0-9a-f]{64}$"))
        and (.source | test("^[0-9a-f]{64}$")) and (.input | test("/") | not)
        and (.headline | length) > 0 and (.items | type) == "array"
        and .shown == (.items | length) and .total >= .shown
      ' >/dev/null || { echo "$fmt/$name is not a usable finding body"; return 1; }
      printf '%s' "$output" | jq -e 'keys == (keys | sort)' >/dev/null
      printf '%s' "$output" | jq -e '.counts | keys == (keys | sort)' >/dev/null
      printf '%s' "$output" | jq -e '.items | all(keys == (keys | sort))' >/dev/null
    done
  done
}

@test "a finding body carries the fields a tool-output record needs" {
  cd "$ROOT"
  normalize --format eslint-json --input "$(fixture_input eslint-json sample)" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .format == "eslint-json" and .files == 3 and .total == 6
    and .counts.errors == 4 and .counts.warnings == 2
    and (.items[0] | .severity == "error" and .file == "src/app.js" and .line == 12)
  ' >/dev/null
}

# The summary is only worth having if the ledger can carry it. This builds the record the
# receipt template describes and appends it, so a change to either shape fails here.
@test "a tool-output summary becomes a record the evidence ledger accepts" {
  p="$(new_project normalize-ledger)"
  run /bin/bash "$PLUGIN/runtime/evidence.sh" --project "$p" init
  [ "$status" -eq 0 ]
  cd "$ROOT"
  summary="$(/bin/bash "$SH" --format eslint-json \
    --input "$(fixture_input eslint-json sample)" --json)"
  record="$(printf '%s' "$summary" | jq -c --arg target "$p" '{
    schemaVersion: 1, id: "eslint-baseline", domain: "tool-output", sourceClass: "tool",
    source: "eslint -f json .", sourceTool: "eslint", scope: ".", severity: "high",
    confidence: "high", impact: "developer", status: "open", ladder: "measured",
    locator: .input, digest: .digest, firstSeen: "2026-09-04T00:00:00Z",
    lastChecked: "2026-09-04T00:00:00Z", action: .headline, host: "claude",
    workTarget: $target, message: (.counts | tostring),
    details: { rawDigest: .source }
  }')"
  run /bin/bash "$PLUGIN/runtime/evidence.sh" --project "$p" append --record "$record"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  run /bin/bash "$PLUGIN/runtime/evidence.sh" --project "$p" render
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF '| eslint-baseline | tool-output |'
  digest="$(printf '%s' "$summary" | jq -r .digest)"
  grep -qF "$digest" "$p/.nightshift/evidence/findings.jsonl"
}

@test "rows sort by severity descending, then file, line, code and detail" {
  cd "$ROOT"
  normalize --format eslint-json --input "$(fixture_input eslint-json sample)"
  [ "$status" -eq 0 ]
  rows="$(printf '%s\n' "$output" \
    | awk -F' \\| ' '/^\| (error|warning|note|critical) / {
        sub(/^\| /, "", $1); print $1 "|" $2 "|" $3
      }')"
  [ "$(printf '%s\n' "$rows" | head -1)" = "error|src/app.js|12" ]
  [ "$(printf '%s\n' "$rows" | sed -n '3p')" = "error|src/lib/parse.js|1" ]
  [ "$(printf '%s\n' "$rows" | tail -1)" = "warning|src/lib/parse.js|90" ]
}

@test "the headline, the table and one anchored source line are the whole summary" {
  cd "$ROOT"
  normalize --format lcov --input "$(fixture_input lcov sample)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "lcov: 68.57% lines covered, 288/420 in 3 files" ]
  printf '%s\n' "$output" | grep -qx '| severity | file | line | code | detail |'
  printf '%s\n' "$output" | grep -qx 'showing 3 of 3 items'
  printf '%s\n' "$output" | tail -2 | head -1 | grep -qE '^result: sha256:[0-9a-f]{64}$'
  printf '%s\n' "$output" | tail -1 | grep -qE '^source: tests/fixtures/normalize/lcov/sample\.info sha256:[0-9a-f]{64}$'
  digest="$(printf '%s\n' "$output" | tail -1 | sed 's/.*sha256://')"
  [ "$digest" = "$(digest_of "$FIX/lcov/sample.info")" ]
  # The result line is the summary's own digest, and it is not the file's.
  result="$(printf '%s\n' "$output" | tail -2 | head -1 | sed 's/.*sha256://')"
  [ "$result" != "$digest" ]
  normalize --format lcov --input "$(fixture_input lcov sample)" --json
  printf '%s' "$output" | jq -e --arg r "$result" --arg s "$digest" \
    '.digest == $r and .source == $s and .input == "sample.info"' >/dev/null
}

@test "--top bounds the table and the count line still names the total" {
  cd "$ROOT"
  normalize --format eslint-json --input "$(fixture_input eslint-json sample)" --top 2
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^| error\|^| warning')" -eq 2 ]
  printf '%s\n' "$output" | grep -qx 'showing 2 of 6 items'

  normalize --format eslint-json --input "$(fixture_input eslint-json sample)" --top 0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'showing 0 of 6 items'
  if printf '%s\n' "$output" | grep -q '^| severity'; then echo "unexpected table header"; return 1; fi
}

# A report that nests its suites states the same tests twice: once on the outer suite and
# once on each suite inside it. Adding both reports every test twice, so only a leaf counts.
@test "a nested JUnit report counts its leaf suites once" {
  cd "$ROOT"
  normalize --format junit --input "$(fixture_input junit nested)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "junit: 5 tests, 1 failure, 0 errors, 1 skipped in 2 suites" ]
  normalize --format junit --input "$(fixture_input junit nested)" --json
  printf '%s' "$output" | jq -e '
    .counts.tests == 5 and .counts.failures == 1 and .counts.skipped == 1 and .files == 2
    and .total == 1
  ' >/dev/null
}

# A failure payload that quotes a suite element is prose. Read as markup it adds phantom
# suites, phantom tests and phantom rows.
@test "a CDATA payload and a comment never become JUnit markup" {
  cd "$ROOT"
  normalize --format junit --input "$(fixture_input junit cdata)" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .counts.tests == 2 and .counts.failures == 1 and .files == 1 and .total == 1
    and (.items[0] | .file == "tests.test_report" and .code == "failure")
  ' >/dev/null
  printf '%s' "$output" | grep -q 'ghost' && { echo 'a quoted element became markup'; return 1; }
  printf '%s' "$output" | grep -q 'phantom' && { echo 'a quoted element became a row'; return 1; }
  true
}

# A percentage of nothing is not full coverage. Every surface says so in the same word.
@test "a metric with no denominator reads unmeasured, never 100%" {
  cd "$ROOT"
  normalize --format coverage-summary --input "$(fixture_input coverage-summary unmeasured)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" \
    = "coverage: lines unmeasured, statements 75.00%, functions 100.00%, branches unmeasured across 2 files" ]
  printf '%s\n' "$output" | grep -qx '| info | src/generated/schema.ts | - | lines | 0/0 lines covered (unmeasured) |'
  normalize --format coverage-summary --input "$(fixture_input coverage-summary unmeasured)" --json
  printf '%s' "$output" | jq -e '
    (.headline | test("lines unmeasured")) and .counts.linesTotal == 0
    and ([.items[] | select(.file == "src/generated/schema.ts")]
         | .[0] | .severity == "info" and (.message | test("unmeasured")))
  ' >/dev/null
  printf '%s' "$output" | grep -q 'lines 100' && { echo 'a zero denominator read as 100%'; return 1; }

  # The whole-report case: total.lines.total 0 across the board.
  normalize --format coverage-summary --input "$(fixture_input coverage-summary edge)"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '%' && { echo 'a report of nothing printed a percentage'; return 1; }

  # LCOV says the same thing through LF:0.
  normalize --format lcov --input "$(fixture_input lcov unmeasured)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "lcov: 45.00% lines covered, 9/20 in 2 files" ]
  printf '%s\n' "$output" | grep -qx '| info | src/generated/schema.js | - | lines | 0/0 lines covered (unmeasured) |'
  normalize --format lcov --input "$(fixture_input lcov edge)"
  [ "$(printf '%s\n' "$output" | head -1)" = "lcov: unmeasured lines covered, 0/0 in 1 file" ]
}

# Two paths that differ only outside ASCII are two files. The display form folds both
# to the same bytes, so the count has to read what the report gave.
@test "the SARIF file count uniques the uri the report gave" {
  cd "$ROOT"
  normalize --format sarif --input "$(fixture_input sarif wide)" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .files == 2 and .counts.warnings == 2
    and ([.items[].file] | unique | length) == 1
  ' >/dev/null
}

# eslint writes severity as a number; a few formatters write the same number as a string.
@test "an eslint severity written as a string is the same level" {
  cd "$ROOT"
  normalize --format eslint-json --input "$(fixture_input eslint-json strings)" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .counts.errors == 1 and .counts.warnings == 1 and .total == 3
    and ([.items[] | select(.code == "no-unused-vars")] | .[0].severity) == "error"
    and ([.items[] | select(.code == "eqeqeq")] | .[0].severity) == "warning"
    and ([.items[] | select(.code == "no-console")] | .[0].severity) == "note"
  ' >/dev/null
}

# An input of nothing but continuation lines is a report this parser did not read.
@test "a tsc report of only continuation lines is unavailable, not a clean compile" {
  cd "$ROOT"
  normalize --format tsc --input "$(fixture_input tsc continuation)"
  [ "$status" -eq 3 ]
  [ "$output" = "unavailable tsc: the input holds no TypeScript diagnostics" ]

  # A report that states its own total is still a summary, even at zero.
  normalize --format tsc --input "$(fixture_input tsc edge)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "tsc: 0 errors, 0 warnings in 0 files" ]
}

# The result digest is the identity of what the run found. Raw bytes that move without
# moving a count must not read as a regression, and a count that drops must move it.
@test "the result digest follows the counts, not the bytes" {
  cd "$ROOT"
  cp "$FIX/eslint-json/sample.json" "$BATS_TEST_TMPDIR/first.json"
  jq -c . <"$FIX/eslint-json/sample.json" >"$BATS_TEST_TMPDIR/reformatted.json"
  ! cmp -s "$BATS_TEST_TMPDIR/first.json" "$BATS_TEST_TMPDIR/reformatted.json"
  jq -c '[.[] | .messages |= map(select(.severity != 2))]' \
    <"$FIX/eslint-json/sample.json" >"$BATS_TEST_TMPDIR/fixed.json"

  first="$(/bin/bash "$SH" --format eslint-json --input "$BATS_TEST_TMPDIR/first.json" --json)"
  again="$(/bin/bash "$SH" --format eslint-json --input "$BATS_TEST_TMPDIR/reformatted.json" --json)"
  fixed="$(/bin/bash "$SH" --format eslint-json --input "$BATS_TEST_TMPDIR/fixed.json" --json)"

  [ "$(printf '%s' "$first" | jq -r .digest)" = "$(printf '%s' "$again" | jq -r .digest)" ]
  [ "$(printf '%s' "$first" | jq -r .source)" != "$(printf '%s' "$again" | jq -r .source)" ]
  [ "$(printf '%s' "$first" | jq -r .digest)" != "$(printf '%s' "$fixed" | jq -r .digest)" ]
  printf '%s' "$fixed" | jq -e '.counts.errors == 0' >/dev/null
}

# The ledger's severity words are not a tool's. The template carries the mapping, and every
# word a summary can print has to survive the trip through it.
@test "every summary severity maps to a severity the ledger accepts" {
  TEMPLATES="$PLUGIN/skills/nightshift/references/receipt-templates.md"
  for pair in 'critical` → `critical' 'error` → `high' 'high` → `high' 'warning` → `medium' \
    'moderate` → `medium' 'note` → `info' 'low` → `low' 'info` → `info'; do
    grep -qF "$pair" "$TEMPLATES" || { echo "the template does not map: $pair"; return 1; }
  done

  p="$(new_project normalize-severity)"
  run /bin/bash "$PLUGIN/runtime/evidence.sh" --project "$p" init
  [ "$status" -eq 0 ]
  cd "$ROOT"
  summary="$(/bin/bash "$SH" --format eslint-json \
    --input "$(fixture_input eslint-json sample)" --json)"
  i=0
  for pair in critical:critical error:high high:high warning:medium moderate:medium \
    note:info low:low info:info; do
    i=$((i + 1))
    ledger="${pair#*:}"
    record="$(printf '%s' "$summary" | jq -c --arg target "$p" --arg sev "$ledger" \
      --arg id "tool-severity-$i" '{
        schemaVersion: 1, id: $id, domain: "tool-output", sourceClass: "tool",
        source: "eslint -f json .", sourceTool: "eslint", scope: ".", severity: $sev,
        confidence: "high", impact: "developer", status: "open", ladder: "measured",
        locator: .input, digest: .digest, firstSeen: "2026-09-04T00:00:00Z",
        lastChecked: "2026-09-04T00:00:00Z", action: .headline, host: "claude",
        workTarget: $target, details: { rawDigest: .source }
      }')"
    run /bin/bash "$PLUGIN/runtime/evidence.sh" --project "$p" append --record "$record"
    [ "$status" -eq 0 ] || { echo "$pair rejected: $output"; return 1; }
  done
  run /bin/bash "$PLUGIN/runtime/evidence.sh" --project "$p" validate
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "pytest-junit is an alias: the same bytes as junit" {
  cd "$ROOT"
  normalize --format pytest-junit --input "$(fixture_input junit sample)"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | diff - "$FIX/junit/sample.expected.md"
  normalize --format pytest-junit --input "$(fixture_input junit sample)" --json
  printf '%s' "$output" | jq -e '.format == "junit"' >/dev/null
}

@test "an unreadable shape is unavailable with a reason, never zero findings" {
  cd "$ROOT"
  for fmt in $FORMATS; do
    normalize --format "$fmt" --input "$(fixture_input "$fmt" broken)"
    [ "$status" -eq 3 ] || { echo "$fmt broken exited $status"; return 1; }
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
    printf '%s\n' "$output" | grep -qE "^unavailable $fmt: .+" \
      || { echo "$fmt: $output"; return 1; }
    if printf '%s\n' "$output" | grep -qi '0 errors'; then echo "unparsed input read as clean"; return 1; fi
  done
}

@test "a missing input is unavailable, and an unknown format is a usage error" {
  cd "$ROOT"
  normalize --format tsc --input "$BATS_TEST_TMPDIR/absent.txt"
  [ "$status" -eq 3 ]
  [ "$output" = "unavailable tsc: the input is not a readable file" ]

  normalize --format made-up --input "$(fixture_input tsc sample)"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'unknown format: made-up'

  normalize --format tsc
  [ "$status" -eq 1 ]
  normalize --input "$(fixture_input tsc sample)"
  [ "$status" -eq 1 ]
  normalize --format tsc --input "$(fixture_input tsc sample)" --top nine
  [ "$status" -eq 1 ]
}

@test "a JSON format needs jq; the awk formats do not" {
  cd "$ROOT"
  bin="$(build_toolset_bin normalize-no-jq bash sh awk sort sed grep cut tr cat head tail wc \
    mktemp rm mv cp printf test dirname basename env uname date find true false)"
  for tool in shasum sha256sum openssl; do
    real="$(command -v "$tool" 2>/dev/null)" && ln -sf "$real" "$bin/$tool"
  done
  [ ! -e "$bin/jq" ]
  [ ! -e "$bin/python3" ]

  for fmt in eslint-json coverage-summary sarif npm-audit; do
    run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
      /bin/bash "$SH" --format "$fmt" --input "$(fixture_input "$fmt" sample)"
    [ "$status" -eq 3 ] || { echo "$fmt exited $status: $output"; return 1; }
    [ "$output" = "unavailable $fmt: jq is required to read this format and is not on PATH" ]
  done

  for fmt in tsc junit lcov; do
    run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
      /bin/bash "$SH" --format "$fmt" --input "$(fixture_input "$fmt" sample)"
    [ "$status" -eq 0 ] || { echo "$fmt exited $status: $output"; return 1; }
    printf '%s\n' "$output" | diff - "$FIX/$fmt/sample.expected.md"
    run env -i PATH="$bin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
      /bin/bash "$SH" --format "$fmt" --input "$(fixture_input "$fmt" sample)" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | diff - "$FIX/$fmt/sample.expected.json"
  done
}

@test "carriage returns, tabs and non-ASCII bytes reduce to the same summary" {
  cd "$ROOT"
  printf 'src/a.ts(1,2): error TS1000: bad.\r\nFound 1 error.\r\n' >"$BATS_TEST_TMPDIR/crlf.txt"
  normalize --format tsc --input "$BATS_TEST_TMPDIR/crlf.txt"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx '| error | src/a.ts | 1 | TS1000 | bad. |'

  printf 'src/x.ts(3,1): error TS2322: caf\xc3\xa9  keeps\tone space.\n' >"$BATS_TEST_TMPDIR/utf8.txt"
  normalize --format tsc --input "$BATS_TEST_TMPDIR/utf8.txt"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx '| error | src/x.ts | 3 | TS2322 | caf keeps one space. |'
}

@test "a pipe in a detail is escaped in the table and kept in the JSON" {
  cd "$ROOT"
  normalize --format eslint-json --input "$(fixture_input eslint-json sample)"
  printf '%s\n' "$output" | grep -qF "Unexpected mix of '\\|\\|' and '&&'."
  normalize --format eslint-json --input "$(fixture_input eslint-json sample)" --json
  printf '%s' "$output" | jq -e '[.items[].message] | any(test("\\|\\|"))' >/dev/null
}

@test "the helper reads the project and writes nothing" {
  p="$(new_project normalize-readonly)"
  cp "$FIX/lcov/sample.info" "$p/lcov.info"
  git -C "$p" add -A
  git -C "$p" -c user.name=t -c user.email=t@example.com commit -q -m fixture
  before="$(git -C "$p" status --porcelain)"
  run /bin/bash "$SH" --format lcov --input "$p/lcov.info"
  [ "$status" -eq 0 ]
  [ "$(git -C "$p" status --porcelain)" = "$before" ]
  [ ! -e "$p/.nightshift/evidence" ]
}

@test "the same input always yields the same bytes" {
  cd "$ROOT"
  first="$(/bin/bash "$SH" --format sarif --input "$(fixture_input sarif sample)" --json)"
  second="$(/bin/bash "$SH" --format sarif --input "$(fixture_input sarif sample)" --json)"
  [ "$first" = "$second" ]
}

@test "the summary carries no carriage return and ends with one newline" {
  cd "$ROOT"
  /bin/bash "$SH" --format junit --input "$(fixture_input junit sample)" >"$BATS_TEST_TMPDIR/out.md"
  if LC_ALL=C grep -q "$(printf '\r')" "$BATS_TEST_TMPDIR/out.md"; then echo "carriage return in output"; return 1; fi
  [ "$(tail -c 1 "$BATS_TEST_TMPDIR/out.md" | od -An -c | tr -d ' ')" = '\n' ]
}

@test "the native Windows twin ships and is registered in the Windows suite" {
  [ -f "$PS1_TWIN" ]
  [ -f "$LOGIC" ]
  grep -qF 'normalize-output-logic.ps1' "$RUN_PS1"
  grep -qF 'normalize-output.ps1' "$PS1_TWIN"
}

# The parity proof: bash and PowerShell over the same fixture, diffed byte for byte. Two
# engines that agree here also agree with each other's ledger, which is the whole point of a
# summary a night can compare against another night.
@test "both engines print the same bytes for every fixture" {
  if ! have_pwsh; then
    skip 'pwsh not installed'
  fi
  cd "$ROOT"
  for fmt in $FORMATS; do
    for name in $(all_cases "$fmt"); do
      input="$(fixture_input "$fmt" "$name")"
      for mode in md json; do
        shflag=""
        psflag=""
        if [ "$mode" = json ]; then
          shflag=--json
          psflag=-Json
        fi
        # An unreadable fixture exits 3 on purpose; the line it prints is what we compare.
        /bin/bash "$SH" --format "$fmt" --input "$input" $shflag \
          >"$BATS_TEST_TMPDIR/sh.out" || true
        "$PWSH_BIN" -NoProfile -NonInteractive -File "$PS1_TWIN" \
          -Format "$fmt" -InputPath "$input" $psflag >"$BATS_TEST_TMPDIR/ps.out" || true
        cmp "$BATS_TEST_TMPDIR/sh.out" "$BATS_TEST_TMPDIR/ps.out" \
          || { echo "$fmt/$name $mode differs between engines"; return 1; }
      done
    done
  done
}

@test "the Windows logic suite passes when pwsh is present" {
  if ! have_pwsh; then
    skip 'pwsh not installed'
  fi
  run "$PWSH_BIN" -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "the composition and quality skills name the helper as optional" {
  QUALITY="$PLUGIN/skills/quality/SKILL.md"
  grep -qF 'runtime/normalize-output.sh' "$QUALITY"
  grep -qF 'If present,' "$QUALITY"
  grep -qF 'Both helpers here are optional' "$QUALITY"
  for shift in clear-quality-debt coverage-hunt vulnerability-sweep flaky-test-repair \
    api-contract-drift seo-audit; do
    grep -qF 'normalize-output.sh' "$PLUGIN/skills/nightshift/references/shifts/$shift.md" \
      || { echo "$shift does not name the helper"; return 1; }
  done
  grep -qF 'tool-output' "$PLUGIN/skills/nightshift/references/receipt-templates.md"
  grep -qF 'runtime/normalize-output.sh' "$ROOT/docs/evidence-capabilities.md"
}

# The report's own total is the authority on how many errors there were. Reading fewer than it
# counted means a diagnostic shape this parser does not know, and a count it cannot stand behind
# is unavailable — never rounded down to what happened to parse.
@test "a tsc report never reports fewer errors than it counted" {
  cd "$ROOT"
  normalize --format tsc --input tests/fixtures/normalize/tsc/summary-only.txt
  [ "$status" -eq 3 ]
  [ "$output" = 'unavailable tsc: the report counts 3 errors and this parser read 0' ]

  normalize --format tsc --input tests/fixtures/normalize/tsc/partial.txt
  [ "$status" -eq 3 ]
  [ "$output" = 'unavailable tsc: the report counts 3 errors and this parser read 1' ]

  # No row is invented to reach the total.
  normalize --format tsc --input tests/fixtures/normalize/tsc/summary-only.txt --json
  [ "$status" -eq 3 ]
  case "$output" in *'"items"'*) return 1 ;; esac
}

@test "a --pretty tsc diagnostic is read, with or without its colours" {
  cd "$ROOT"
  for name in pretty colour; do
    normalize --format tsc --input "tests/fixtures/normalize/tsc/$name.txt" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e '.counts.errors == 1' >/dev/null
    printf '%s\n' "$output" | jq -e '.items[0].file == "src/index.ts"' >/dev/null
    printf '%s\n' "$output" | jq -e '.items[0].line == 1' >/dev/null
    printf '%s\n' "$output" | jq -e '.items[0].code == "TS2322"' >/dev/null
  done
  # The two reports say the same thing, so they carry the same result digest.
  normalize --format tsc --input tests/fixtures/normalize/tsc/pretty.txt --json
  a="$(printf '%s\n' "$output" | jq -r .digest)"
  normalize --format tsc --input tests/fixtures/normalize/tsc/colour.txt --json
  [ "$(printf '%s\n' "$output" | jq -r .digest)" = "$a" ]
}

@test "a watch log is several reports, and none of them is the answer" {
  cd "$ROOT"
  normalize --format tsc --input tests/fixtures/normalize/tsc/watch.txt
  [ "$status" -eq 3 ]
  [ "$output" = 'unavailable tsc: the input holds more than one TypeScript report' ]
}

@test "a tsc report that counted no errors is a clean compile" {
  cd "$ROOT"
  normalize --format tsc --input tests/fixtures/normalize/tsc/clean.txt --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.counts.errors == 0 and .counts.warnings == 0' >/dev/null
}

# A reader that closes elements nobody closed is answering about a document nobody wrote. The
# JUnit reader stays a bounded format reader: it refuses what it cannot finish, naming the reason,
# and never returns a confident summary of a report that was cut off.
@test "an unfinished JUnit report is unavailable, never a clean run" {
  cd "$ROOT"
  normalize --format junit --input tests/fixtures/normalize/junit/truncated.xml
  [ "$status" -eq 3 ]
  [ "$output" = 'unavailable junit: the report ends with an unclosed testsuite element' ]

  normalize --format junit --input tests/fixtures/normalize/junit/cut.xml
  [ "$status" -eq 3 ]
  [ "$output" = 'unavailable junit: the report holds a tag that never closes' ]

  normalize --format junit --input tests/fixtures/normalize/junit/mismatched.xml
  [ "$status" -eq 3 ]
  [ "$output" = 'unavailable junit: the report holds a testsuite that closes without opening' ]
}

@test "a payload section that never ends is unavailable, not a shorter document" {
  cd "$ROOT"
  normalize --format junit --input tests/fixtures/normalize/junit/torn-cdata.xml
  [ "$status" -eq 3 ]
  [ "$output" = 'unavailable junit: the report ends inside an unterminated CDATA section' ]

  normalize --format junit --input tests/fixtures/normalize/junit/torn-comment.xml
  [ "$status" -eq 3 ]
  [ "$output" = 'unavailable junit: the report ends inside an unterminated comment' ]
}

@test "a finished JUnit report still reads, counts and all" {
  cd "$ROOT"
  # A suite that closes with nothing in it ran nothing, and says so.
  normalize --format junit --input tests/fixtures/normalize/junit/empty-suite.xml --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.counts.tests == 0 and .files == 1' >/dev/null

  # A suite that states no counts is read as the zeros it states, not refused.
  normalize --format junit --input tests/fixtures/normalize/junit/no-counts.xml --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.counts.tests == 0 and .files == 1' >/dev/null

  # Nesting, escaped text and a valid CDATA payload are unchanged by any of this.
  normalize --format junit --input tests/fixtures/normalize/junit/nested.xml --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.counts.tests == 5 and .files == 2' >/dev/null
  normalize --format junit --input tests/fixtures/normalize/junit/cdata.xml --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.counts.tests == 2 and .counts.failures == 1' >/dev/null
  normalize --format junit --input tests/fixtures/normalize/junit/sample.xml --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.counts.tests == 14 and .counts.failures == 3' >/dev/null
}
