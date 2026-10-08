# Codex hooks

The manifest at `../../.codex-plugin/plugin.json` points here, so Codex loads `hooks.json` in
this directory instead of `../hooks.json` — the two hosts never read each other's wiring.

`clock-out-gate.sh`, `hardhat.sh`, `session-end.sh`, and `pulse.sh` make the same decisions as Claude's hooks, reading the
same punch list and the same `lib/lib.sh`. Everything Codex-specific — the stdin payload, the
block/deny shapes on stdout, how a hook finds the project — lives in `lib-io.sh`, the one
adaptation seam.

The wire format follows the documented Codex hooks contract
(<https://developers.openai.com/codex/hooks>): one JSON object on stdin carrying `session_id`,
`transcript_path`, `cwd`, `tool_name`, and `tool_input`; the Stop continuation as
`{"decision":"block","reason":…}` (Stop expects JSON on stdout even on exit 0, so a permitted
stop answers `{"continue":true}` rather than silence);
the PreToolUse denial as the `hookSpecificOutput` `permissionDecision` shape; `${PLUGIN_ROOT}`
as the plugin root in commands. The catch-all matcher sends every observable local tool to the
hardhat, where `toolDeny` uses the canonical `tool_name`: shell commands, including unified exec,
arrive as `Bash`; file edits arrive as `apply_patch` with the patch text in
`tool_input.command`, while `Edit` and `Write` are matcher aliases only. MCP and other local
function tools reach this path; hosted tools do not.

`session-end.sh` writes `.session-end` when the bound Codex session ends. Codex SessionEnd
reason is always `other` (close, archive/delete, idle unload after about 30 minutes with no
client). Closing the session is pause-recovery: the watchman stands down and Start re-arms.
A crash that never fires SessionEnd still revives. `pulse.sh` overwrites `.shift-pulse` for
the bound session so a quiet live tab is not guessed dead.

`prompt-submit.sh` is the UserPromptSubmit hook. It reads the documented `prompt` field and closes
an open plan room when the owner's message starts with `$nightshift:plan-exit` or
`$nightshift:start`; it never blocks a prompt.

Recovery ownership stays host-neutral too. The Codex watchman advances `.shift-lease` before each
spawn and passes its generation/nonce through the child environment; the hardhat and Stop hook
accept only that generation for the bound shift. Codex's hook payload does not provide process
ancestry Nightshift can vouch for, so the watchman records its child process witness while the hook
leaves the interactive pid fields empty.

One point the docs leave open is held conservatively in `lib-io.sh`: no project-dir env var
is documented for hooks, so the payload's `cwd` locates the shift and `CODEX_PROJECT_DIR` is
honored first as an explicit override. Codex's native `request_user_input` and the
`AskUserQuestion` compatibility alias each read their own exact `toolDeny` entry, so an owner may
give them different messages or allow one with an empty value.

The repo-root `.agents/plugins/marketplace.json` is the Codex marketplace entry; the
`.claude-plugin/marketplace.json` beside it is also read as a legacy-compatible path, and both
resolve the same `./plugin`.
