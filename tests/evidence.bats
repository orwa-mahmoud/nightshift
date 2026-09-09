#!/usr/bin/env bats
# Versioned evidence ledger.

# `run --separate-stderr` (used below) is a Bats >=1.5.0 feature; declaring the requirement
# up front stops Bats from emitting an advisory BW002 warning on every run under 1.14.0.
bats_require_minimum_version 1.5.0

ROOT="$BATS_TEST_DIRNAME/.."
EV="$ROOT/plugins/nightshift/runtime/evidence.sh"
WIN="$ROOT/plugins/nightshift/runtime/windows/evidence.ps1"
SCHEMA="$ROOT/plugins/nightshift/skills/nightshift/references/schemas/v1/finding.json"
EXPORT="$ROOT/plugins/nightshift/runtime/export-support.sh"

# Resolved once per test process (Bats re-sources this whole file per @test). Empty when no
# pwsh binary exists anywhere on the real PATH.
PWSH_BIN="$(command -v pwsh 2>/dev/null || true)"

load helpers

sample() {
  jq -nc --arg id "$1" --arg host "${2:-claude}" '{
    schemaVersion:1, id:$id, domain:"lint", sourceClass:"eslint",
    source:"eslint --version", scope:"src/", severity:"medium",
    confidence:"high", impact:"developer", status:"open",
    ladder:"observed", locator:"src/app.js:3", digest:"abc",
    firstSeen:"2026-09-01T00:00:00Z", lastChecked:"2026-09-01T00:00:00Z",
    action:"fix", host:$host, workTarget:"/repo"
  }'
}

@test "a missing ledger is valid in an existing workspace" {
  p="$(new_project ev)"
  run bash "$EV" --project "$p" validate
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'no ledger'
}

@test "init append validate render and tsv export round-trip" {
  p="$(new_project ev2)"
  run bash "$EV" --project "$p" init
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/evidence/findings.jsonl" ]
  rec="$(sample f1 claude)"
  run bash "$EV" --project "$p" append --record "$rec" --raw "eslint output"
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/evidence/raw/f1.txt" ]
  run bash "$EV" --project "$p" validate
  [ "$status" -eq 0 ]
  run bash "$EV" --project "$p" render
  [ "$status" -eq 0 ]
  grep -q '| f1 |' "$p/.nightshift/evidence/findings.md"
  run bash "$EV" --project "$p" export-tsv
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q $'^id\tdomain'
  printf '%s\n' "$output" | grep -q $'^f1\tlint'
}

@test "identical records validate across host adapters" {
  p="$(new_project ev3)"
  bash "$EV" --project "$p" init >/dev/null
  bash "$EV" --project "$p" append --record "$(sample f2 claude)" >/dev/null
  bash "$EV" --project "$p" append --record "$(sample f3 codex)" >/dev/null
  bash "$EV" --project "$p" append --record "$(sample f4 cursor)" >/dev/null
  bash "$EV" --project "$p" validate
}

@test "malformed evidence is rejected" {
  p="$(new_project ev4)"
  bash "$EV" --project "$p" init >/dev/null
  rec="$(sample f5 claude | jq '.severity="nope"')"
  run bash "$EV" --project "$p" append --record "$rec"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'invalid severity'
}

@test "raw unrestricted remote locators are rejected unless marked untrusted" {
  p="$(new_project ev5)"
  bash "$EV" --project "$p" init >/dev/null
  rec="$(jq -nc '{
    schemaVersion:1, id:"f7", domain:"seo", sourceClass:"crawl", source:"curl",
    scope:"site", severity:"low", confidence:"low", impact:"user", status:"open",
    ladder:"declared", locator:"https://example.invalid/x", digest:"d",
    firstSeen:"t", lastChecked:"t", action:"", host:"claude", workTarget:"/r"
  }')"
  run bash "$EV" --project "$p" append --record "$rec"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'untrusted'
  rec="$(printf '%s' "$rec" | jq '.untrusted=true')"
  run bash "$EV" --project "$p" append --record "$rec"
  [ "$status" -eq 0 ]
}

@test "ladder promotion by prose is rejected" {
  p="$(new_project ev6)"
  bash "$EV" --project "$p" init >/dev/null
  bash "$EV" --project "$p" append --record "$(sample f8 claude)" >/dev/null
  rec="$(sample f8 claude | jq '.ladder="measured" | .promoteBy="prose" | .digest="x"')"
  run bash "$EV" --project "$p" append --record "$rec"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'prose'
}

@test "migrate is a no-op on a workspace with no ledger" {
  p="$(new_project ev7)"
  run bash "$EV" --project "$p" migrate
  [ "$status" -eq 0 ]
}

@test "Windows helper exists and names the same commands" {
  [ -f "$WIN" ]
  grep -q 'ValidateSet' "$WIN"
  grep -q 'init' "$WIN"
  grep -q 'export-tsv' "$WIN"
  grep -qi 'does not verify a Nightshift tick' "$WIN"
}

@test "support bundle omits evidence raw output" {
  grep -q 'evidence ledger raw output' "$EXPORT"
  grep -q 'evidence ledger raw output' "$ROOT/plugins/nightshift/runtime/windows/export-support.ps1"
}

# ---------------------------------------------------------------------------------------------
# Native-engine parity: the bash ledger (evidence.sh) and
# the native PowerShell ledger (windows/evidence.ps1) must behave byte-identically for the same
# command sequence and PATH. The pwsh leg runs whenever a pwsh binary exists and is skipped,
# never silently, when it does not.

# controlled_bin, fake_exe, resolve_tool_path, build_toolset_bin, and have_pwsh come from
# tests/helpers.bash — capabilities.bats needs the identical toolset-construction pattern, so
# it isn't duplicated here.

# The exact POSIX toolset a from-scratch bash implementation may lean on to read JSON Lines,
# hash text, and shell out to jq: everything evidence.sh needs to walk a project, hash raw
# text, and rewrite the ledger atomically — deliberately excluding python3 for the
# first list, and excluding both jq and python3 for the second.
EVIDENCE_TOOLSET_WITH_JQ="bash sh jq git sed grep find sort ls awk cat tr head tail wc cut mkdir cp rm mv env cmp date uname test dirname basename readlink stat printf true false xargs shasum openssl mktemp chmod"
EVIDENCE_TOOLSET_NO_JQ="bash sh git sed grep find sort ls awk cat tr head tail wc cut mkdir cp rm mv env cmp date uname test dirname basename readlink stat printf true false xargs shasum openssl mktemp chmod"

# capture_raw <prefix> -- <argv...> — runs argv, capturing stdout/stderr/exit code verbatim to
# <prefix>.out, <prefix>.err, <prefix>.code.
capture_raw() {
  local prefix="$1" rc=0
  shift
  "$@" >"$prefix.out" 2>"$prefix.err" || rc=$?
  printf '%s' "$rc" >"$prefix.code"
}

# sed_escape <string> — escapes a literal string for safe use inside a sed s/// pattern
# delimited by `/`.
sed_escape() {
  printf '%s' "$1" | sed -e 's/[]\/$*.^[]/\\&/g'
}

# normalize_project_path <prefix> <project> — rewrites <prefix>.out/.err in place, replacing
# every literal occurrence of the project's own absolute path with a fixed placeholder. `init`
# is the only command that ever prints an absolute path (the ledger's findings.jsonl path); no
# JSON record or file under evidence/ embeds one. Without this, three independently-named temp
# projects could never produce byte-identical stdout for that one step even when the engines
# agree perfectly.
normalize_project_path() {
  local prefix="$1" proj="$2" esc
  esc="$(sed_escape "$proj")"
  sed "s/${esc}/@PROJECT@/g" "$prefix.out" >"$prefix.out.norm" && mv "$prefix.out.norm" "$prefix.out"
  sed "s/${esc}/@PROJECT@/g" "$prefix.err" >"$prefix.err.norm" && mv "$prefix.err.norm" "$prefix.err"
}

# evidence_capture <prefix> <project> -- <argv...>
evidence_capture() {
  local prefix="$1" proj="$2"
  shift 2
  capture_raw "$prefix" "$@"
  normalize_project_path "$prefix" "$proj"
}

# assert_step_match <prefix-a> <prefix-b> — cmp's stdout, stderr, and exit code between two
# captured steps.
assert_step_match() {
  local a="$1" b="$2"
  cmp "$a.out" "$b.out"
  cmp "$a.err" "$b.err"
  cmp "$a.code" "$b.code"
}

# assert_step_ok <prefix> — the captured step must have exited 0; prints its stderr on failure.
assert_step_ok() {
  local prefix="$1"
  if [ "$(cat "$prefix.code")" != "0" ]; then
    echo "expected exit 0 for $prefix, got $(cat "$prefix.code"); stderr:" >&2
    cat "$prefix.err" >&2
    return 1
  fi
}

# assert_step_rejected <prefix> <expected-exit> <stderr-substring>
assert_step_rejected() {
  local prefix="$1" expect="$2" needle="$3"
  if [ "$(cat "$prefix.code")" != "$expect" ]; then
    echo "expected exit $expect for $prefix, got $(cat "$prefix.code"); stderr:" >&2
    cat "$prefix.err" >&2
    return 1
  fi
  if ! grep -qF "$needle" "$prefix.err"; then
    echo "expected stderr of $prefix to contain: $needle" >&2
    echo "actual stderr:" >&2
    cat "$prefix.err" >&2
    return 1
  fi
}

# ARGV is a global "return value" set by each argv_* builder below, then consumed by step_sh /
# consumed by step_ps1. This mirrors how bash 3.2 (no namerefs) has to pass array results back
# from a function.
argv_validate() { ARGV=(validate); }
argv_init() { ARGV=(init); }
argv_render() { ARGV=(render); }
argv_export_tsv() { ARGV=(export-tsv); }
argv_migrate() { ARGV=(migrate); }

# argv_append <record-json> [raw-text]
argv_append() {
  local rec="$1" raw="${2:-}"
  if [ -n "$raw" ]; then
    ARGV=(append --record "$rec" --raw "$raw")
  else
    ARGV=(append --record "$rec")
  fi
}

# argv_disposition <id> <disposition> [ladder]
argv_disposition() {
  local id="$1" disp="$2" ladder="${3:-}"
  if [ -n "$ladder" ]; then
    ARGV=(disposition "$id" "$disp" "$ladder")
  else
    ARGV=(disposition "$id" "$disp")
  fi
}

# build_ps1_argv — translates the POSIX-CLI $ARGV (as built by the argv_* functions above) into
# the flag-based PowerShell CLI: `-Project <p> <verb> -Record ... -Raw ... -Id ... -Disposition
# ... -Ladder ...`. The verb itself stays positional (Position 0 in the existing parameter set).
build_ps1_argv() {
  local verb="${ARGV[0]}"
  PARGV=("$verb")
  case "$verb" in
  append)
    PARGV+=(-Record "${ARGV[2]}")
    if [ "${#ARGV[@]}" -ge 5 ] && [ "${ARGV[3]}" = "--raw" ]; then
      PARGV+=(-Raw "${ARGV[4]}")
    fi
    ;;
  disposition)
    PARGV+=(-Id "${ARGV[1]}" -Disposition "${ARGV[2]}")
    if [ "${#ARGV[@]}" -ge 4 ]; then
      PARGV+=(-Ladder "${ARGV[3]}")
    fi
    ;;
  esac
}

# step_sh/step_ps1 <prefix> <project> [path-override]
# Run the command currently described by $ARGV against <project> through one engine, capturing
# it under <prefix>. When [path-override] is given, the child runs under that restricted PATH
# instead of the test's own (see the no-python and neither-parser tests below).
step_sh() {
  local prefix="$1" proj="$2" pathoverride="${3:-}"
  mkdir -p "$(dirname "$prefix")"
  if [ -n "$pathoverride" ]; then
    evidence_capture "$prefix" "$proj" env PATH="$pathoverride" bash "$EV" --project "$proj" "${ARGV[@]}"
  else
    evidence_capture "$prefix" "$proj" bash "$EV" --project "$proj" "${ARGV[@]}"
  fi
}

step_ps1() {
  local prefix="$1" proj="$2" pathoverride="${3:-}"
  mkdir -p "$(dirname "$prefix")"
  build_ps1_argv
  if [ -n "$pathoverride" ]; then
    evidence_capture "$prefix" "$proj" env PATH="$pathoverride" "$PWSH_BIN" -NoProfile -NonInteractive -File "$WIN" -Project "$proj" "${PARGV[@]}"
  else
    evidence_capture "$prefix" "$proj" "$PWSH_BIN" -NoProfile -NonInteractive -File "$WIN" -Project "$proj" "${PARGV[@]}"
  fi
}

# build_sequence_records — sets $R1 (a full record, firstSeen/lastChecked/digest already
# populated), $R2 and $R2_RAW (a record that leaves firstSeen/lastChecked/digest for append to
# default, whose raw text is stored as given), and
# $R3 (a full record with a remote locator marked untrusted). All literal strings, so every
# engine receives byte-identical --record/--raw input.
build_sequence_records() {
  R1='{"schemaVersion":1,"id":"p1","domain":"lint","sourceClass":"eslint","source":"eslint --version","scope":"src/","severity":"medium","confidence":"high","impact":"developer","status":"open","ladder":"observed","locator":"src/app.js:3","digest":"deadbeef","firstSeen":"2026-09-02T00:00:00Z","lastChecked":"2026-09-02T00:00:00Z","action":"fix","host":"claude","workTarget":"/repo"}'
  R2='{"schemaVersion":1,"id":"p2","domain":"secrets","sourceClass":"grep","source":"grep -R TOKEN","scope":"src/","severity":"high","confidence":"high","impact":"production","status":"open","ladder":"declared","locator":"src/config.js:10","action":"","host":"claude","workTarget":"/repo"}'
  R2_RAW=$'line one\napi_key=abcd\nline three\n'
  R3='{"schemaVersion":1,"id":"p3","domain":"seo","sourceClass":"crawl","source":"curl -I","scope":"site","severity":"low","confidence":"low","impact":"user","status":"open","ladder":"declared","locator":"https://example.invalid/x","untrusted":true,"digest":"deadbeef","firstSeen":"2026-09-02T00:00:00Z","lastChecked":"2026-09-02T00:00:00Z","action":"","host":"claude","workTarget":"/repo"}'
}

EVIDENCE_STEPS="01-validate-empty 02-init 03-append-r1 04-append-r2 05-append-r3 06-disposition 07-render 08-export-tsv 09-validate 10-migrate"

# evidence_sequence <run_fn> <project> <prefix-dir> [path-override]
#
# Runs the fixed ten-step scenario from the frozen interface — validate on an empty workspace,
# init, three appends (a full record, a record that defaults digest/firstSeen/lastChecked with
# raw output, and an untrusted remote locator), a disposition that promotes a ladder
# rung, render, export-tsv, a final validate, and migrate — through <run_fn> (one of
# step_sh/step_ps1), capturing every step under <prefix-dir>/<step-name>.{out,err,code}.
# Requires build_sequence_records to have set $R1/$R2/$R2_RAW/$R3 already.
evidence_sequence() {
  local run_fn="$1" proj="$2" prefix="$3" pathoverride="${4:-}"
  mkdir -p "$prefix"
  argv_validate
  "$run_fn" "$prefix/01-validate-empty" "$proj" "$pathoverride"
  argv_init
  "$run_fn" "$prefix/02-init" "$proj" "$pathoverride"
  argv_append "$R1" ""
  "$run_fn" "$prefix/03-append-r1" "$proj" "$pathoverride"
  argv_append "$R2" "$R2_RAW"
  "$run_fn" "$prefix/04-append-r2" "$proj" "$pathoverride"
  argv_append "$R3" ""
  "$run_fn" "$prefix/05-append-r3" "$proj" "$pathoverride"
  argv_disposition p1 fixed measured
  "$run_fn" "$prefix/06-disposition" "$proj" "$pathoverride"
  argv_render
  "$run_fn" "$prefix/07-render" "$proj" "$pathoverride"
  argv_export_tsv
  "$run_fn" "$prefix/08-export-tsv" "$proj" "$pathoverride"
  argv_validate
  "$run_fn" "$prefix/09-validate" "$proj" "$pathoverride"
  argv_migrate
  "$run_fn" "$prefix/10-migrate" "$proj" "$pathoverride"
}

@test "engine parity: bash and pwsh agree byte-for-byte across a full evidence sequence" {
  export NIGHTSHIFT_EVIDENCE_NOW=2026-09-02T00:00:00Z
  build_sequence_records

  p_sh="$(new_project ev-parity-sh)"
  evidence_sequence step_sh "$p_sh" "$BATS_TEST_TMPDIR/seq-sh"

  for step in $EVIDENCE_STEPS; do
    assert_step_ok "$BATS_TEST_TMPDIR/seq-sh/$step"
  done

  if ! have_pwsh; then
    skip "pwsh not found on PATH; skipping PowerShell leg of the evidence engine-parity sequence"
  fi
  p_ps1="$(new_project ev-parity-ps1)"
  evidence_sequence step_ps1 "$p_ps1" "$BATS_TEST_TMPDIR/seq-ps1"
  for step in $EVIDENCE_STEPS; do
    assert_step_match "$BATS_TEST_TMPDIR/seq-sh/$step" "$BATS_TEST_TMPDIR/seq-ps1/$step"
  done
  diff -r "$p_sh/.nightshift/evidence" "$p_ps1/.nightshift/evidence"
}

@test "rejection parity: bash and pwsh agree on every contract violation" {
  # (a) invalid severity
  rec='{"schemaVersion":1,"id":"bad-severity","domain":"lint","sourceClass":"eslint","source":"eslint","scope":"s","severity":"nope","confidence":"high","impact":"developer","status":"open","ladder":"observed","locator":"f","digest":"d","firstSeen":"t","lastChecked":"t","action":"","host":"claude","workTarget":"/repo"}'
  argv_append "$rec" ""
  p_sh="$(new_project ev-rej-a-sh)"
  step_sh "$BATS_TEST_TMPDIR/rej-a-sh" "$p_sh"
  assert_step_rejected "$BATS_TEST_TMPDIR/rej-a-sh" 2 "invalid severity"
  if have_pwsh; then
    p_ps1="$(new_project ev-rej-a-ps1)"
    step_ps1 "$BATS_TEST_TMPDIR/rej-a-ps1" "$p_ps1"
    assert_step_match "$BATS_TEST_TMPDIR/rej-a-sh" "$BATS_TEST_TMPDIR/rej-a-ps1"
  fi

  # (c) remote locator without untrusted
  rec='{"schemaVersion":1,"id":"bad-remote","domain":"seo","sourceClass":"crawl","source":"curl","scope":"site","severity":"low","confidence":"low","impact":"user","status":"open","ladder":"declared","locator":"https://example.invalid/y","digest":"d","firstSeen":"t","lastChecked":"t","action":"","host":"claude","workTarget":"/repo"}'
  argv_append "$rec" ""
  p_sh="$(new_project ev-rej-c-sh)"
  step_sh "$BATS_TEST_TMPDIR/rej-c-sh" "$p_sh"
  assert_step_rejected "$BATS_TEST_TMPDIR/rej-c-sh" 2 "remote locator requires untrusted=true"
  if have_pwsh; then
    p_ps1="$(new_project ev-rej-c-ps1)"
    step_ps1 "$BATS_TEST_TMPDIR/rej-c-ps1" "$p_ps1"
    assert_step_match "$BATS_TEST_TMPDIR/rej-c-sh" "$BATS_TEST_TMPDIR/rej-c-ps1"
  fi

  # (d) prose ladder promotion
  rec1='{"schemaVersion":1,"id":"prose1","domain":"lint","sourceClass":"x","source":"x","scope":"s","severity":"low","confidence":"low","impact":"none","status":"open","ladder":"declared","locator":"f","digest":"d","firstSeen":"t","lastChecked":"t","action":"","host":"claude","workTarget":"/repo"}'
  rec2='{"schemaVersion":1,"id":"prose1","domain":"lint","sourceClass":"x","source":"x","scope":"s","severity":"low","confidence":"low","impact":"none","status":"open","ladder":"measured","locator":"f","digest":"d2","firstSeen":"t","lastChecked":"t","action":"","host":"claude","workTarget":"/repo","promoteBy":"prose"}'
  p_sh="$(new_project ev-rej-d-sh)"
  argv_append "$rec1" ""
  step_sh "$BATS_TEST_TMPDIR/rej-d-seed-sh" "$p_sh"
  assert_step_ok "$BATS_TEST_TMPDIR/rej-d-seed-sh"
  argv_append "$rec2" ""
  step_sh "$BATS_TEST_TMPDIR/rej-d-sh" "$p_sh"
  assert_step_rejected "$BATS_TEST_TMPDIR/rej-d-sh" 2 "ladder must not be promoted by prose"
  if have_pwsh; then
    p_ps1="$(new_project ev-rej-d-ps1)"
    argv_append "$rec1" ""
    step_ps1 "$BATS_TEST_TMPDIR/rej-d-seed-ps1" "$p_ps1"
    assert_step_match "$BATS_TEST_TMPDIR/rej-d-seed-sh" "$BATS_TEST_TMPDIR/rej-d-seed-ps1"
    argv_append "$rec2" ""
    step_ps1 "$BATS_TEST_TMPDIR/rej-d-ps1" "$p_ps1"
    assert_step_match "$BATS_TEST_TMPDIR/rej-d-sh" "$BATS_TEST_TMPDIR/rej-d-ps1"
  fi

  # (e) disposition of an unknown id
  argv_disposition does-not-exist fixed
  p_sh="$(new_project ev-rej-e-sh)"
  step_sh "$BATS_TEST_TMPDIR/rej-e-sh" "$p_sh"
  assert_step_rejected "$BATS_TEST_TMPDIR/rej-e-sh" 2 "unknown id does-not-exist"
  if have_pwsh; then
    p_ps1="$(new_project ev-rej-e-ps1)"
    step_ps1 "$BATS_TEST_TMPDIR/rej-e-ps1" "$p_ps1"
    assert_step_match "$BATS_TEST_TMPDIR/rej-e-sh" "$BATS_TEST_TMPDIR/rej-e-ps1"
  fi

  # (f) a hand-written malformed second line, then validate
  recok='{"schemaVersion":1,"id":"ok1","domain":"lint","sourceClass":"x","source":"x","scope":"s","severity":"low","confidence":"low","impact":"none","status":"open","ladder":"declared","locator":"f","digest":"d","firstSeen":"t","lastChecked":"t","action":"","host":"claude","workTarget":"/repo"}'
  p_sh="$(new_project ev-rej-f-sh)"
  argv_append "$recok" ""
  step_sh "$BATS_TEST_TMPDIR/rej-f-seed-sh" "$p_sh"
  assert_step_ok "$BATS_TEST_TMPDIR/rej-f-seed-sh"
  printf '%s\n' '{this is not json' >>"$p_sh/.nightshift/evidence/findings.jsonl"
  argv_validate
  step_sh "$BATS_TEST_TMPDIR/rej-f-sh" "$p_sh"
  assert_step_rejected "$BATS_TEST_TMPDIR/rej-f-sh" 1 "malformed JSON on line 2"
  if have_pwsh; then
    p_ps1="$(new_project ev-rej-f-ps1)"
    argv_append "$recok" ""
    step_ps1 "$BATS_TEST_TMPDIR/rej-f-seed-ps1" "$p_ps1"
    printf '%s\n' '{this is not json' >>"$p_ps1/.nightshift/evidence/findings.jsonl"
    argv_validate
    step_ps1 "$BATS_TEST_TMPDIR/rej-f-ps1" "$p_ps1"
    assert_step_match "$BATS_TEST_TMPDIR/rej-f-sh" "$BATS_TEST_TMPDIR/rej-f-ps1"
  fi

  # (g) init on a dir without .nightshift
  argv_init
  bare_sh="$BATS_TEST_TMPDIR/rej-g-bare-sh"
  mkdir -p "$bare_sh"
  step_sh "$BATS_TEST_TMPDIR/rej-g-sh" "$bare_sh"
  assert_step_rejected "$BATS_TEST_TMPDIR/rej-g-sh" 1 "no .nightshift/"
  if have_pwsh; then
    bare_ps1="$BATS_TEST_TMPDIR/rej-g-bare-ps1"
    mkdir -p "$bare_ps1"
    step_ps1 "$BATS_TEST_TMPDIR/rej-g-ps1" "$bare_ps1"
    assert_step_match "$BATS_TEST_TMPDIR/rej-g-sh" "$BATS_TEST_TMPDIR/rej-g-ps1"
  fi

  # (h) no arguments at all. PowerShell parameter binding prints its own usage wording, so the
  # pwsh leg agrees on the exit code only.
  capture_raw "$BATS_TEST_TMPDIR/rej-h-sh" bash "$EV"
  assert_step_rejected "$BATS_TEST_TMPDIR/rej-h-sh" 1 "usage: evidence.sh --project DIR"
  if have_pwsh; then
    capture_raw "$BATS_TEST_TMPDIR/rej-h-ps1" "$PWSH_BIN" -NoProfile -NonInteractive -File "$WIN"
    [ "$(cat "$BATS_TEST_TMPDIR/rej-h-ps1.code")" = "1" ]
  fi
}

@test "the bash evidence ledger needs no python3 when jq is present on PATH" {
  export NIGHTSHIFT_EVIDENCE_NOW=2026-09-02T00:00:00Z
  build_sequence_records

  bin="$(build_toolset_bin ev-no-python-bin $EVIDENCE_TOOLSET_WITH_JQ)"
  [ ! -e "$bin/python3" ]
  run_p="$(new_project ev-no-python-run)"
  evidence_sequence step_sh "$run_p" "$BATS_TEST_TMPDIR/seq-no-python-run" "$bin"
  for step in $EVIDENCE_STEPS; do
    assert_step_ok "$BATS_TEST_TMPDIR/seq-no-python-run/$step"
  done
}

@test "the bash evidence ledger requires jq or python3 on PATH" {
  p="$(new_project ev-neither)"
  bin="$(build_toolset_bin ev-neither-bin $EVIDENCE_TOOLSET_NO_JQ)"
  [ ! -e "$bin/jq" ]
  [ ! -e "$bin/python3" ]

  rec='{"schemaVersion":1,"id":"n1","domain":"lint","sourceClass":"x","source":"x","scope":"s","severity":"low","confidence":"low","impact":"none","status":"open","ladder":"declared","locator":"f","digest":"d","firstSeen":"t","lastChecked":"t","action":"","host":"claude","workTarget":"/repo"}'
  run --separate-stderr env PATH="$bin" bash "$EV" --project "$p" append --record "$rec"
  [ "$status" -eq 2 ]
  printf '%s\n' "$stderr" | grep -qF 'JSON parser unavailable; write the receipt in the skill'
}

@test "an absolute evidence id does not write outside .nightshift" {
  p="$(new_project ev-escape)"
  bash "$EV" --project "$p" init >/dev/null
  rec="$(sample /tmp/nightshift-proof claude)"
  run --separate-stderr bash "$EV" --project "$p" append --record "$rec" --raw proof
  [ "$status" -eq 2 ]
  printf '%s\n' "$stderr" | grep -qF 'invalid id'
  [ ! -e /tmp/nightshift-proof ]
  [ ! -e /tmp/nightshift-proof.txt ]
  [ ! -e "$p/.nightshift/evidence/raw/tmp/nightshift-proof.txt" ]
  for bad in '..' '.' 'foo/bar' 'foo\bar' '_leading'; do
    rec="$(sample "$bad" claude)"
    run --separate-stderr bash "$EV" --project "$p" append --record "$rec" --raw proof
    [ "$status" -eq 2 ]
    printf '%s\n' "$stderr" | grep -qF 'invalid id'
  done
}

example_record() {
  sed -n '/^```json$/,/^```$/p' "$1" | sed '1d;$d'
}

@test "the baseline guidance example validates through the ledger" {
  p="$(new_project ev-baseline-page)"
  bash "$EV" --project "$p" init >/dev/null
  rec="$(example_record "$ROOT/plugins/nightshift/skills/nightshift/references/evidence/baseline.md")"
  run bash "$EV" --project "$p" append --record "$rec"
  [ "$status" -eq 0 ]
  run bash "$EV" --project "$p" validate
  [ "$status" -eq 0 ]
}

@test "the checkpoint guidance example validates through the ledger" {
  p="$(new_project ev-checkpoint-page)"
  bash "$EV" --project "$p" init >/dev/null
  rec="$(example_record "$ROOT/plugins/nightshift/skills/nightshift/references/evidence/checkpoint.md")"
  run bash "$EV" --project "$p" append --record "$rec"
  [ "$status" -eq 0 ]
  run bash "$EV" --project "$p" validate
  [ "$status" -eq 0 ]
}

@test "evidence temps are created mode 700" {
  grep -qF 'mktemp -d' "$EV"
  grep -qF 'chmod 700' "$EV"
}
