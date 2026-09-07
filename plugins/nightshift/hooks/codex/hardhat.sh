#!/usr/bin/env bash
# hardhat.sh — Codex PreToolUse guard. Same rules as Claude's hardhat; only the wire format
# differs, and that lives entirely in lib-io.sh.
#
# Every rule is shift-scoped and read from the owner's .nightshift/rules.json. toolDeny
# uses exact Codex tool names: a non-empty message denies, an empty message allows, and
# an unlisted optional tool is allowed. request_user_input and its AskUserQuestion
# compatibility alias are explicit entries so neither gets a hidden fallback:
#   protectedDirs        space/pipe-separated dir names never to git add/commit/tag/remote
#   expectedEmail        commits must be authored by this identity
#   neverCommitPatterns  staged diff (git diff --cached) must not match this grep -E pattern
#   forbiddenCommands    deny any command matching this grep -E pattern during a shift
#                        (the no-push recipe: set it to 'git .*push')
#   elevation            per-category policy and grep -E pattern for the five categories that
#                        create system state (sudo, containers, global-packages, daemons,
#                        external-services); denied by default, lifted by the owner in
#                        rules.json or for one shift in shift-policy.json. Hardhat is
#                        hardening, not a sandbox.
# An env var of the matching NIGHTSHIFT_ name overrides the file for the session; the file
# itself is guarded during a shift, so only the owner sets or lifts a rule.
#
# The two commit guards read git, so they resolve the repository the commit lands in (see
# repo_root in lib.sh) rather than assuming it is the project dir. When that repository cannot
# be identified they deny: a guard that cannot look is never a guard that approves.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh" # pure-bash path: no dirname, so a hostile PATH cannot unsource the helpers
# shellcheck source=plugins/nightshift/hooks/shared/hardhat-core.sh
. "$_here/../shared/hardhat-core.sh"
# shellcheck source=plugins/nightshift/hooks/codex/lib-io.sh
. "$_here/lib-io.sh"

codex_read_input
TOOL="$CODEX_TOOL_NAME"
CMD="$CODEX_TOOL_CMD"
CWD="$CODEX_CWD"
SID="$CODEX_SESSION_ID"
TPATH="$CODEX_TRANSCRIPT_PATH"

HOST_DIR="$(codex_project_dir)"
LINK_ERROR=""
PROJECT_DIR="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)" || LINK_ERROR=1
NS="$PROJECT_DIR/.nightshift"
PUNCH="$NS/punch-list.md"
ENDED="$NS/.ended"


# The emission (and its escaping) is the seam's; the guard only decides.
deny() {
  codex_emit_deny "$(ns_expand_injected_paths "$PROJECT_DIR" "$1")"
  exit 0
}

[ -z "$LINK_ERROR" ] || deny "BLOCKED: .nightshift-link is invalid. Open the correct project task or repair the explicit link to an absolute workspace containing .nightshift/."
STATE_KIND="$(ns_state_kind "$PROJECT_DIR")"
case "$STATE_KIND" in
  malformed | future)
    deny "BLOCKED: $(ns_state_refuse_message "$STATE_KIND")"
    ;;
esac

# A commit message must not read as the command it mentions, so blank the message argument
# before matching. Only that argument: scrubbing every quoted span would also hide a genuinely
# forbidden command that happens to be quoted, such as sh -c "git push".
SCRUBBED="$(ns_hardhat_scrub "$CMD")"
LEASE_COMMAND="$CMD"
case "$TOOL" in Bash | PowerShell) LEASE_COMMAND="$SCRUBBED" ;; esac
LEASE_NONCE="${NIGHTSHIFT_LEASE_NONCE:-}"
LEASE_GENERATION="${NIGHTSHIFT_LEASE_GENERATION:-}"

# Every remaining rule is shift-scoped: inert unless a shift is truly active. A stop-work order
# is a request, not the ending — the agent keeps working until its next stop attempt, which is
# exactly when the site rules still matter. The gate writes ENDED when it actually releases, and
# that is what stands these rules down.
if ! ns_hardhat_active; then
  if [ "${NIGHTSHIFT_REVIVAL:-}" = "1" ]; then
    if [ ! -f "$NS/.shift-armed" ] || [ ! -f "$PUNCH" ] || { [ -f "$ENDED" ] && [ ! -L "$ENDED" ]; } \
      || ! ns_lease_nonce_matches "$NS" codex "$LEASE_NONCE" "$LEASE_GENERATION"; then
      deny "BLOCKED: this recovered worker no longer owns an active shift. Do not continue after clock-out."
    fi
  fi
  exit 0
fi

# Process ownership is runtime state for the whole site, not agent-editable state. This narrow
# protection applies even to helper conversations; all of their ordinary project work stays free.
if ns_hardhat_payload_targets_lease "$TOOL" "$CODEX_RAW" "$LEASE_COMMAND"; then
  deny "BLOCKED: the process lease is runtime-owned, as is its mutex identity. Do not read, delete, or rewrite either file; issue STOP from another session if ownership must be reset."
fi

if ns_hardhat_is_command_tool "$TOOL"; then
  NS_PLUGIN_ROOT="$(cd -P "$_here/../.." >/dev/null 2>&1 && pwd -P)" || NS_PLUGIN_ROOT=""
  if [ -n "$NS_PLUGIN_ROOT" ] && ns_hardhat_trusted_shift_control "$CMD" "$NS_PLUGIN_ROOT" "$PROJECT_DIR"; then
    exit 0
  fi
fi

# Codex offers no interactive process ancestry this hook can vouch for, so the initial pid and
# start-time lines stay empty. Watchman children carry a unique lease nonce and generation.
ns_shift_unbound codex hardhat
own_rc=$?
[ "$own_rc" -eq 1 ] && exit 0
[ "$own_rc" -eq 2 ] && deny "$NS_SHIFT_FAIL"
if ! ns_session_present "$NS" && [ -n "${SID:-}" ]; then
  case "$TOOL" in
    Bash | AskUserQuestion | request_user_input | apply_patch | Edit | Write)
      ns_session_claim "$NS" "$SID" "${TPATH:-}" "" "" codex || true
      ;;
  esac
fi
ns_shift_rebind codex "" "" hardhat
own_rc=$?
[ "$own_rc" -eq 1 ] && exit 0
[ "$own_rc" -eq 2 ] && deny "$NS_SHIFT_FAIL"
REC="$NS_SHIFT_REC"

# Start's distinctive probe is also its compare-and-set result. A losing concurrent Start is
# denied here instead of silently becoming an unrestricted helper after another session won.
if ns_hardhat_binding_probe "$TOOL" "$CMD"; then
  if [ -z "${SID:-}" ] || [ -z "$REC" ]; then
    deny "BLOCKED: Start could not bind this session atomically. Issue STOP, inspect with Doctor, and retry Start."
  fi
  if [ "$SID" != "$REC" ]; then
    deny "BLOCKED: another session already owns this shift. Reopen that conversation or issue STOP before running Start again."
  fi
fi

ns_shift_authorize codex "" "" hardhat
own_rc=$?
[ "$own_rc" -eq 1 ] && exit 0
[ "$own_rc" -eq 2 ] && deny "$NS_SHIFT_FAIL"

# Tool rules use the canonical tool_name from this host. The catch-all manifest sends every
# observable PreToolUse call here; hosted tools that Codex does not expose remain outside it.
TOOL_RULES="$(ns_tool_rules "$PROJECT_DIR" "${NIGHTSHIFT_TOOL_RULES:-}")"
if ns_hardhat_tool_deny_broken; then
  deny "BLOCKED: the toolDeny rules are not a JSON object, so the tool rules cannot run. Fix .nightshift/rules.json or run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex)."
fi

# The active agent never inspects or changes the owner's rules through any observable tool.
# Inspect target-bearing arguments and patch headers, not unrelated prose in a payload.
if ns_hardhat_payload_targets_rules "$TOOL" "$CODEX_RAW" "$SCRUBBED"; then
  deny "BLOCKED: the rules file is the owner's — the night neither reads nor rewrites its own rules. Park the need in .nightshift/parking-lot.md and keep working."
fi
if ns_hardhat_payload_targets_control "$TOOL" "$CODEX_RAW" "$SCRUBBED"; then
  deny "BLOCKED: shift control files are owner-owned while the night is armed. Do not delete or forge .shift-armed, .ended, STOP, .shift-session, work-target, work-mode, shift-policy.json, shift-defaults.json, or deadline, and do not delete the punch list. Park the need in .nightshift/parking-lot.md and keep working."
fi

if [ "$TOOL" = "request_user_input" ] \
  || { [ -z "$TOOL" ] && codex_input_mentions_tool "request_user_input"; }; then
  if m="$(ns_hardhat_required_tool_deny_reason request_user_input)"; then deny "$m"; fi
  exit 0 # a permitted question is not a command; the command guards have no business with it
fi
if [ "$TOOL" = "AskUserQuestion" ] \
  || { [ -z "$TOOL" ] && codex_input_mentions_tool "AskUserQuestion"; }; then
  if m="$(ns_hardhat_required_tool_deny_reason AskUserQuestion)"; then deny "$m"; fi
  exit 0 # a permitted question is not a command; the command guards have no business with it
fi
if m="$(ns_hardhat_tool_deny_reason "$TOOL")"; then deny "$m"; fi

if ns_hardhat_is_command_tool "$TOOL"; then
  PROTECTED_DIRS="$(rule "$PROJECT_DIR" protectedDirs "${NIGHTSHIFT_PROTECTED_DIRS:-}")"
  EXPECTED_EMAIL="$(rule "$PROJECT_DIR" expectedEmail "${NIGHTSHIFT_EXPECTED_EMAIL:-}")"
  NEVER_COMMIT_PATTERNS="$(rule "$PROJECT_DIR" neverCommitPatterns "${NIGHTSHIFT_NEVER_COMMIT_PATTERNS:-}")"
  FORBIDDEN_COMMANDS="$(rule "$PROJECT_DIR" forbiddenCommands "${NIGHTSHIFT_FORBIDDEN_COMMANDS:-}")"
  if reason="$(ns_hardhat_command_reason)"; then
    deny "$reason"
  fi
fi

exit 0
