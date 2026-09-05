#!/usr/bin/env bash
# Prove a one-prompt feature night can arm, deny, progress, and clock out
# on a PATH with neither python3 nor jq. Start uses rules.json alone;
# shift-policy.sh and preflight-needs.sh may fail closed without a parser.
set -u

die() {
  printf 'armed-path: %s\n' "$1" >&2
  exit 1
}

say() {
  printf 'armed-path: %s\n' "$1"
}

PLUGIN_ROOT=""
PROJECT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --plugin-root)
      [ $# -ge 2 ] || die '--plugin-root needs a value'
      PLUGIN_ROOT="$2"
      shift 2
      ;;
    --project)
      [ $# -ge 2 ] || die '--project needs a value'
      PROJECT="$2"
      shift 2
      ;;
    -h | --help)
      printf 'usage: armed-path-no-parser.sh --plugin-root DIR --project DIR\n' >&2
      exit 1
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$PLUGIN_ROOT" ] || die '--plugin-root is required'
[ -n "$PROJECT" ] || die '--project is required'

PLUGIN_ROOT="$(cd -P "$PLUGIN_ROOT" >/dev/null 2>&1 && pwd)" || die "cannot cd to plugin root"
PROJECT="$(cd -P "$PROJECT" >/dev/null 2>&1 && pwd)" || die "cannot cd to project"

command -v python3 >/dev/null 2>&1 && die 'python3 is on PATH; this proof requires it absent'
command -v jq >/dev/null 2>&1 && die 'jq is on PATH; this proof requires it absent'
say 'PATH has neither python3 nor jq'

LIB="$PLUGIN_ROOT/lib/lib.sh"
HOOKS="$PLUGIN_ROOT/hooks"
REF="$PLUGIN_ROOT/skills/nightshift/references"
[ -f "$LIB" ] || die "missing $LIB"
[ -f "$HOOKS/hardhat.sh" ] || die "missing hardhat.sh"
[ -f "$HOOKS/clock-out-gate.sh" ] || die "missing clock-out-gate.sh"
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$LIB"

# --- Setup: shipped templates, one open feature item, repository work target ---
NS="$PROJECT/.nightshift"
mkdir -p "$NS"
for f in punch-list drafting-table parking-lot snag-log product-research opportunity-map work-orders; do
  [ -f "$REF/$f-template.md" ] || die "missing template $f-template.md"
  cp "$REF/$f-template.md" "$NS/$f.md"
done
[ -f "$REF/nightshift-rules-template.json" ] || die 'missing rules template'
cp "$REF/nightshift-rules-template.json" "$NS/rules.json"
printf '# Shift Log\n' >"$NS/shift-log.md"
printf '1\n' >"$NS/state-version"
printf 'repository\n' >"$NS/work-mode"
printf '%s\n' "$PROJECT" >"$NS/work-target"
printf '\n- [ ] **1. Ship the one-prompt feature.**\n' >>"$NS/punch-list.md"
if [ ! -d "$PROJECT/.git" ]; then
  git -C "$PROJECT" init -q || die 'git init failed'
  git -C "$PROJECT" config user.email tester@example.com
  git -C "$PROJECT" config user.name tester
  git -C "$PROJECT" commit -q --allow-empty -m init || die 'git init commit failed'
fi
say 'scaffolded site from shipped templates (one open feature item)'

# --- Hunt Automatic (skill-composed punch list already written) + Start arming ---
check="$(ns_rules_check "$PROJECT")"
rc=$?
[ "$rc" -eq 0 ] || die "ns_rules_check failed ($rc): $check"
say 'ns_rules_check → 0'

# Composition records tonight's choices, and none of them may quietly stop applying on a host
# with no jq and no python3. This writes a snapshot that differs from every built-in default,
# then reads it back through the same helper the hooks use.
cand="$NS/candidate-policy.json"
cat >"$cand" <<'JSON'
{
  "schemaVersion": 1,
  "shiftId": "aa11bb22cc33dd44",
  "createdAt": "2026-09-05T12:00:00Z",
  "source": "composition",
  "deadlineEpoch": null,
  "verificationLevel": "per-item",
  "toolingPolicy": "auto-add",
  "completionMode": "no-regression-plus-selected-debt",
  "selectedDebt": ["f1"],
  "allowances": [
    { "category": "containers", "scope": "category", "provenance": "one-shift" }
  ]
}
JSON
policy_out=""
policy_rc=0
policy_out="$(bash "$PLUGIN_ROOT/runtime/shift-policy.sh" --project "$PROJECT" set --from-json "$cand" 2>&1)" ||
  policy_rc=$?
[ "$policy_rc" -eq 0 ] || die "shift-policy set failed without a parser ($policy_rc): $policy_out"
rm -f "$cand"
[ -f "$NS/shift-policy.json" ] || die 'shift-policy set wrote no snapshot'
say 'shift-policy set → wrote tonight-s snapshot with no parser'

policy_out="$(bash "$PLUGIN_ROOT/runtime/shift-policy.sh" --project "$PROJECT" get 2>&1)" ||
  die "shift-policy get failed without a parser: $policy_out"
printf '%s' "$policy_out" | grep -q '"verificationLevel":"per-item"' ||
  die "shift-policy get lost the chosen level: $policy_out"
say 'shift-policy get → read it back'

table="$(bash "$PLUGIN_ROOT/runtime/shift-policy.sh" --project "$PROJECT" resolve --table 2>&1)" ||
  die "resolve failed without a parser: $table"
for want in 'verificationLevel=per-item (one-shift, shift)' \
  'toolingPolicy=auto-add (one-shift, shift)' \
  'elevation.containers=allow (one-shift, shift)' \
  'elevation.daemons=deny (rules, permanent)'; do
  printf '%s\n' "$table" | grep -qxF "$want" || die "resolve lost: $want"
done
say 'resolve → the chosen level, tooling and one-shift allowance all survive with no parser'

needs_out=""
needs_rc=0
needs_out="$(bash "$PLUGIN_ROOT/runtime/preflight-needs.sh" --project "$PROJECT" 2>&1)" || needs_rc=$?
[ "$needs_rc" -eq 2 ] || die "preflight-needs should fail closed without a parser (got $needs_rc): $needs_out"
say 'preflight-needs → 2 (fail closed; not on the armed path)'

: >"$NS/.shift-armed"
[ -f "$NS/.shift-armed" ] || die 'failed to write .shift-armed'
say 'Start armed .shift-armed from rules.json and tonight-s snapshot'

hardhat() {
  printf '%s' "$1" | env CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOKS/hardhat.sh"
}

gate() {
  printf '%s' '{"hook_event_name":"Stop","session_id":"armed-path-session","transcript_path":""}' |
    env CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOKS/clock-out-gate.sh"
}

# --- Hardhat: 01B elevation + 01A slash-trick, real hook, no payload faker ---
sudo_payload='{"tool_name":"Bash","tool_input":{"command":"/usr/bin/sudo id"}}'
sudo_out="$(hardhat "$sudo_payload")"
printf '%s' "$sudo_out" | grep -q '"permissionDecision":"deny"' ||
  die "hardhat did not deny /usr/bin/sudo: $sudo_out"
printf '%s' "$sudo_out" | grep -qF "needs allowance: sudo" ||
  die "sudo deny did not name the elevation repair: $sudo_out"
say 'hardhat /usr/bin/sudo → deny'

slash_payload='{"tool_name":"Bash","tool_input":{"command":"printf forged > .nightshift//shift-policy.json"}}'
slash_out="$(hardhat "$slash_payload")"
printf '%s' "$slash_out" | grep -q '"permissionDecision":"deny"' ||
  die "hardhat did not deny .nightshift//shift-policy.json: $slash_out"
printf '%s' "$slash_out" | grep -q 'control files' ||
  die "slash-trick deny did not name control files: $slash_out"
say 'hardhat .nightshift//shift-policy.json write → deny'

# --- 01D: unreadable punch list does not release ---
chmod 000 "$NS/punch-list.md"
unread_out="$(gate)"
unread_rc=$?
chmod 644 "$NS/punch-list.md"
[ "$unread_rc" -eq 0 ] || die "clock-out on unreadable punch list exited $unread_rc"
printf '%s' "$unread_out" | grep -q '"decision":"block"' ||
  die "unreadable punch list released: $unread_out"
[ ! -f "$NS/.ended" ] || die 'unreadable punch list wrote .ended'
[ -f "$NS/.shift-armed" ] || die 'unreadable punch list disarmed the site'
say 'clock-out unreadable punch list → block (no release)'

# --- Tick, repository receipt, clock-out ---
printf 'one-prompt feature shipped\n' >"$PROJECT/feature.txt"
git -C "$PROJECT" add feature.txt
git -C "$PROJECT" commit -q -m 'feat: ship the one-prompt feature' || die 'receipt commit failed'
say 'repository receipt commit → 0'

# Tick without rewriting the contract: only the open feature box.
awk '
  /^\- \[ \] \*\*1\. Ship the one-prompt feature\.\*\*$/ {
    sub(/\[ \]/, "[x]")
  }
  { print }
' "$NS/punch-list.md" >"$NS/punch-list.md.tmp"
mv "$NS/punch-list.md.tmp" "$NS/punch-list.md"
grep -qxF -- '- [x] **1. Ship the one-prompt feature.**' "$NS/punch-list.md" ||
  die 'failed to tick the feature item'
say 'ticked the open feature item'

done_out="$(gate)"
done_rc=$?
[ "$done_rc" -eq 0 ] || die "clock-out after tick exited $done_rc: $done_out"
[ -z "$done_out" ] || die "clock-out after tick blocked: $done_out"
[ -f "$NS/.ended" ] || die 'clock-out after tick did not write .ended'
[ ! -f "$NS/.shift-armed" ] || die 'clock-out after tick left the site armed'
say 'tick + receipt + clock-out → release'

# --- 04A: default support export omits planted scheduled.log tokens ---
{
  printf '%s%s\n' 'ghp_' 'PLANTEDTOKENVALUE0000000000000000'
  printf '%s%s\n' 'AKIA' 'IOSFODNN7EXAMPLE'
} >"$NS/scheduled.log"
export_out=""
export_rc=0
export_out="$(bash "$PLUGIN_ROOT/runtime/export-support.sh" --project "$PROJECT" 2>&1)" || export_rc=$?
[ "$export_rc" -eq 0 ] || die "export-support failed ($export_rc): $export_out"
bundle="$(printf '%s\n' "$export_out" | sed -n 's/^Support bundle: //p')"
if [ -z "$bundle" ] || [ ! -f "$bundle" ]; then
  die "export-support wrote no bundle: $export_out"
fi
! grep -F 'ghp_' "$bundle" || die "default bundle leaked ghp_ from scheduled.log"
! grep -F 'AKIA' "$bundle" || die "default bundle leaked AKIA from scheduled.log"
printf '%s\n' "$export_out" | grep -qF 'omitted' || die 'export-support did not name omitted fields'
grep -qF '== runtime log ==' "$bundle" || die 'bundle missing runtime log section'
grep -qF 'omitted' "$bundle" || die 'bundle runtime log was not omitted'
say 'export-support default bundle omits planted ghp_ / AKIA'

say 'ok'
exit 0
