# Start — host detail

Open this only when a Start preflight verdict names your host, or when a refusal needs a
host-native command. Everything here is detail behind a verdict the helper already printed.

## Native Windows

Use the PowerShell tool and native paths throughout. The host variables are
`$env:CLAUDE_PROJECT_DIR`, `$env:CODEX_PROJECT_DIR` and `$env:PLUGIN_ROOT`, with
`[Environment]::CurrentDirectory` as the Codex launch-cwd fallback. Import the bundled module
before calling any helper function:

```powershell
Import-Module "$NIGHTSHIFT_PLUGIN_ROOT\lib\Nightshift.psm1" -Force
```

Do not route a native run through WSL or Git Bash. WSL is a separate Linux runtime and follows the
POSIX commands.

Native Windows reads JSON with PowerShell's built-in `ConvertFrom-Json` (not PowerShell 7) and
enumerates keys with `PSObject.Properties.Name`. There is no `jq` or Python prerequisite on this
host.

## Claude Code

Frictionless permissions come from `$TASK_ROOT/.claude/settings.local.json` or
`$TASK_ROOT/.claude/settings.json` — a `bypassPermissions` default mode, or an allowlist covering
the gates' commands. Settings on disk are what a headless revival inherits; a mode picked at launch
dies with the process. A live conversation is handed back with `claude --resume <id>` for a
terminal, or `vscode://anthropic.claude-code/open?session=<id>` for the IDE; `claude agents --json`
lists ids. Claude Code records clean session ends and Esc, and its watchman stands down for either
rather than resuming.

## Codex

Approvals are per launch. A shift meant to run unattended is started
`codex -a never -s danger-full-access`; the workspace-write sandbox protects `.git`, so a session
under it can edit but never commit. A contract that does not commit needs only `workspace-write` —
ticks alone finish a night. The guards remain the fence either way.

A live conversation is handed back with `codex resume <id>`. Codex SessionEnd (reason `other`) is
pause-recovery: closing, archiving, or an idle unload stands the watchman down and Start re-arms;
the punch list stays. A crash that never fires SessionEnd still revives, but only when
`$NS/.shift-session` holds a resumable session id — a UUID or a long hex token. ChatGPT
thread/conversation handles, rollout paths and other non-resumable identities are refused: the
watchman stands down rather than starting an unrelated conversation. A missing id still falls back
to a fresh session whose handover is the punch list.

## Cursor

Arm the Cursor watchman, never the Claude or Codex one. Record the Cursor conversation id in
`.shift-session` (host line `cursor`); that id is the origin IDE tab. Revival mints or resumes a
CLI worker in `.shift-worker` and never passes the IDE id to `agent --resume`.
