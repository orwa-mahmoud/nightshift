# Start — host detail

Open this only when a Start preflight verdict names your host, or when a refusal needs a
host-native command. Everything here is detail behind a verdict the helper already printed.

## Native Windows

Use the PowerShell tool and native paths throughout. The host variables are
`$env:CLAUDE_PROJECT_DIR`, `$env:CODEX_PROJECT_DIR` and `$env:PLUGIN_ROOT`, with
`[Environment]::CurrentDirectory` as the Codex launch-cwd fallback. Import the bundled module
before calling any helper function:

Do not route a native run through WSL or Git Bash. WSL is a separate Linux runtime and follows the
POSIX commands.

Native Windows reads JSON with PowerShell's built-in `ConvertFrom-Json` (not PowerShell 7) and
enumerates keys with `PSObject.Properties.Name`. There is no `jq` or Python prerequisite on this
host.

## Process evidence

The primary tell is POSIX `kill -0` on a recorded numeric pid; `ps`, `pgrep` and `lsof` are
optional enhancers and must never be installed. When `kill -0` cannot classify the pid and no
host roster or transcript pulse answers, the state is `process-evidence-unavailable` and Start
stops — missing tools are not a dead session. On native Windows the equivalent is `Get-Process -Id`
plus the recorded UTC start time through `Test-NSRecordedProcess`; an inaccessible process is
unavailable evidence, not death.

**Stand down a stale watchman before clearing its state.** The helper does this only after it has
proved no shift is live: it kills a still-running pid from `$NS/.watchman` and waits for it to
exit. On native Windows it reads pid and start time and calls `Stop-Process -Id` only when
`Test-NSRecordedProcess` returns Alive — a reused pid is not this watchman. A watchman must not be
able to advance the old lease while markers are being removed. A pid it cannot verify is left
running and the preflight refuses.

**Cross-host handoff.** The `fence` verdict is the on-disk fence:
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" continuity-handoff fence-check --project "$NIGHTSHIFT_WORKSPACE"` reads the same lease,
session and pid. Model-authored flags and omitted fields cannot grant takeover, and two active
workers are never permitted. Summarize campaign history from `$NS/shift-log.md` instead of calling
the packaging subcommands.

**Stale-lease reset.** When a refusal tells the owner to reset unowned lease state, this is the
command they run themselves in a terminal after issuing STOP:

```bash
bash -c '. "$NIGHTSHIFT_PLUGIN_ROOT/lib/lib.sh"; ns_lease_reset_stale "$NIGHTSHIFT_WORKSPACE/.nightshift"'
```

Native Windows uses `Reset-NSStaleLease "$NS"` from the imported module. A false result is a
refusal, not permission to delete the lease directly.

When the verdict is `terminal clock-out failed without releasing the shift` and the lease is
interactive, reopen the recorded conversation — do not run the stale-lease reset. If a recovery
worker still holds the lease, wait or run Stop from a separate session; reopening stays blocked
while that worker is alive.

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

## Work mode and work target

`repository` is the historical default. `artifact` means the work target is a persistent folder,
not a Git repository: inspect and edit that folder, do not require Git, and complete each item with
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" write-receipt` (native)
instead of a work-target commit. Completion there is `$NS/receipts/`, not a git log. Cited reports
follow `cited-research.md` beside this file and
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" check-report`.

When the record is missing, the resolver uses the workspace itself if it is a repository, or its
single immediate child repository. It skips a symlink or reparse child; that is not a nested
checkout. Several child repositories make the choice ambiguous, and the preflight refuses until
Setup records one.

## Linking another workspace

If the start request itself explicitly names a different existing Nightshift workspace, that
owner-provided path is authorization to link it. Print both absolute paths, run
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" link-workspace --host-root "$TASK_ROOT" --workspace "$PROPOSED_WORKSPACE"`,
then continue from the resolved workspace. Without an explicit path or an existing valid link,
refuse to arm outside the task root and send the owner to Setup; never discover a target.

## State version

Migration is a Setup or Doctor repair only —
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" migrate-state` on POSIX,

on native Windows. Start never writes the marker, and a newer marker is never rewritten or
downgraded.
