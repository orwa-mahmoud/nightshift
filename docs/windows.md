# Native Windows

Nightshift has a native PowerShell path for setup, hooks, process ownership, recovery, and Task
Scheduler generation. It does not use WSL or depend on Git Bash, Node.js, Python, `jq`, a proxy, or
a second agent runtime.

## Choose the runtime deliberately

- **Native Windows has a bundled PowerShell path** for setup, hooks, process ownership, recovery,
  and Task Scheduler generation when Claude Code or Codex run in PowerShell, Git is installed
  natively, PowerShell 5.1 or later is present, and the workspace is on a local NTFS volume. CI
  verifies that path with local host fixtures; it does not load an authenticated host session.
- **WSL is supported as Linux.** Install and run the host, plugin, repository, and watchman inside
  the same WSL distribution, then use the POSIX commands documented elsewhere.
- **A split Windows/WSL run is unsupported.** Do not keep the host process on one side and the
  workspace, hooks, or watchman on the other.
- **Network shares and filesystems without Windows ACLs or hard links are unsupported for an
  active shift.** Atomic session claims and private lease files fail closed there.

Installing Git for Windows is optional for Claude Code itself. Repository mode's work-target,
commit, and local receipts-repository snapshot require native Git. Artifact mode records
completion in the shift report, with optional per-item receipts and no work-target commit.
If Git Bash is installed, Claude Code may choose
it as the hook shell. The bundled launcher is written to detect Windows and transfer the hook to
PowerShell. That Git Bash transfer is not yet a CI-verified claim; prefer a native PowerShell host
session until it is.

## What has parity

The native path uses the same on-disk contract and marker names as macOS and Linux:

- setup copies only absent templates, writes `state-version`, records work-mode and the selected
  work target (a Git repository or a persistent folder), and can create the optional local-only
  receipts repository;
- PreToolUse binds one session, creates and enforces the process lease, protects `rules.json` and
  lease state, applies exact `toolDeny` keys, and enforces configured command and commit guards;
- Stop honors `STOP` first, releases completed or expired shifts, records stalls, commits optional
  receipts, and blocks while open Items remain;
- the watchman advances the lease before every child, passes the generation and nonce in that
  child's environment, and runs recovery in the persisted work target;
- the scheduler emits a daily Task Scheduler definition with `IgnoreNew`, so Task Scheduler and
  the process lease both refuse overlapping starts;
- Start runs the same preflight through `ns.ps1 start-preflight`, and its `ok`,
  `warn` and `refuse` sentences are byte-identical to the POSIX helper's;
- Doctor, status's lease inspector, import-issues, archive retention, migrate-state,
  apply-profile, and export-support use bundled PowerShell helpers beside the POSIX scripts.
  Native Windows does not call `.sh` for those, and does not require `jq`, Python, Node, or a
  package manager. If `gh` is already on PATH, import-issues uses it; Nightshift never installs it.
  Hunt and Quality compose in the skill on every host. Native Windows has no planner or preview.

Claude Code has no Windows-only command field in a plugin hook manifest. Nightshift therefore
dot-sources a small shell/PowerShell launcher from the shared manifest. POSIX hosts continue into
the existing shell hook; every Windows shell path continues into the bundled `.ps1` hook. Codex
uses its documented `commandWindows` override; the cmd.exe entrypoint launches the bundled hook
with Windows PowerShell and an explicit execution-policy bypass.

## Setup and start

Use the normal host skill: `/nightshift:setup` and `/nightshift:start` on Claude Code, or ask
Nightshift to set up and start on Codex. The skills select their PowerShell commands when the host
is native Windows.

The mechanical scaffold is also available without a model turn:

```powershell
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" setup `
  --project (Get-Location) --work-target C:\path\to\repository --mode repository
```

Setup still asks before choosing gates, changing project permissions, migrating legacy state, or
creating a receipts repository. The script itself asks nothing.

When the opened folder is not the Nightshift workspace, the same plugin-root helper writes the
explicit link after the owner confirms both absolute paths:

```powershell
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" link-workspace `
  --host-root C:\path\to\task --workspace C:\path\to\workspace
```

The immediate pause from any folder, with an explicit project path, is:

```powershell
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" stop-shift `
  --project C:\path\to\task
```

Reset drops the deadline afterward (`ns.ps1 reset-shift`). Purge deletes only that project's
`.nightshift/` after `-ConfirmPath` matches the canonical directory
(`ns.ps1 purge-workspace`). None of them uninstall the plugin.

The panic stop from the Nightshift workspace — the folder that contains `.nightshift/`,
not a linked task root — waits for the next Stop event:

```powershell
New-Item -ItemType File -Force .nightshift\STOP
```

## Task Scheduler

Generate and inspect a task without registering it:

```powershell
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" schedule `
  --project C:\path\to\workspace --preflight
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" schedule `
  --project C:\path\to\workspace --at 04:05
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" schedule `
  --project C:\path\to\workspace --list
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" schedule `
  --project C:\path\to\workspace --remove
```

The generator prints one PowerShell registration command and the complete XML. The action invokes
`powershell.exe` with an encoded command, preserves paths containing spaces, writes output to
`.nightshift\scheduled.log`, and registers nothing itself. The deterministic `Nightshift-*` task
name lives in Task Scheduler's existing root folder, so first registration needs no separate folder
creation. Preflight also fails `work mode is unset; Setup would propose artifact - a scheduled start will refuse to arm` when the mode file is missing and Setup would propose artifact.
It also fails `work target could not be resolved - a scheduled start will refuse to arm` when the recorded work target cannot be read.

The generated task uses the current user's interactive token. It can start a missed run when that
user is next logged in, but it does not wake or power on the machine and does not survive a logout
as a credentialed background account. Configure a credentialed task yourself only if that broader
Windows trust boundary is intentional.

## Doctor and other helpers

The same plugin-root PowerShell helpers cover Doctor, archive retention, import-issues, rule
profiles, a local support bundle, and artifact-mode completion receipts:

```powershell
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" doctor --project C:\path\to\workspace
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" migrate-state --project C:\path\to\workspace
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" retain-history --project C:\path\to\workspace
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" import-issues --project C:\path\to\workspace --list-proposed
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" apply-profile --project C:\path\to\workspace --list
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" export-support --project C:\path\to\workspace
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" write-receipt --project C:\path\to\workspace --item 'title' --verify 'checks' --output C:\path\to\file.md
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" archive-receipts --project C:\path\to\workspace
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" check-report --project C:\path\to\workspace --report C:\path\to\report.md --manifest C:\path\to\sources.tsv --output C:\path\to\report.md
```

Two optional read-only reports ship beside them and never need `jq` on this host:

```powershell
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" normalize-output --format eslint-json --input-path C:\path\to\eslint.json
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" inventory --project C:\path\to\workspace
```

`ns.ps1 normalize-output` prints one compact summary of a tool's raw output — the same bytes the POSIX
helper prints for the same file — and `ns.ps1 inventory` prints one table per workspace package. Both
write nothing, and both print one `unavailable` line and exit 3 rather than an empty report.

Missing or empty receipts create no dated receipts folder.

In artifact mode Doctor reports `artifact receipts N` and, when any exist, `latest artifact receipt`
with the filename only of the most recently written receipt. Review the shift report and output
files; use `ns.ps1 write-receipt` when the contract calls for an additional receipt through
`report.legacyItemReceipts`.
It warns `artifact receipts path is not a usable directory` when that path exists but is not a usable directory, and offers a confirm action to replace it rather than write-receipt. Start, Hunt, Quality, and Schedule refuse when that path is unusable rather than begin a notes-folder night that cannot land receipts.
Automatic Hunt and Quality skip quality-debt entries the folder cannot support.
The GitHub issue hunt is skipped in artifact mode.
The defect hunt is skipped in artifact mode.
Documentation drift is skipped in artifact mode.
TODO and FIXME debt is skipped in artifact mode.
Coverage hunt is skipped in artifact mode.
Tooling quality-debt entries are skipped in artifact mode.
Do not `git init` a notes folder.

## Process evidence and recovery

Windows hooks walk native process ancestry through `Win32_Process`; a recorded holder is identified
by both PID and UTC process start time. The watchman treats an access-denied or unavailable process
query as uncertainty and stands down. It never converts missing evidence into permission to spawn.

Claude can also consult its session roster and transcript. Codex has no equivalent Windows cwd
oracle for arbitrary peer processes, so when no recorded PID exists the native watchman treats any
exact-name Codex process as conservative live evidence. That can delay recovery when an unrelated
Codex session is open elsewhere, but it cannot create a second writer.

The host UI has the same display boundary on Windows as on other systems: a headless resume can
continue the durable conversation without refreshing an already-open panel. Reopen the recorded
thread to inspect or interact with it; the process lease already fences stale observed tool calls.

## Rule and filesystem details

PowerShell parses `rules.json` exactly with `ConvertFrom-Json`. `forbiddenCommands` and
`neverCommitPatterns` run through .NET regular expressions. Nightshift translates the common POSIX
classes used by existing rules (`[[:space:]]`, `[[:digit:]]`, `[[:alnum:]]`, and related classes)
and fails closed on any class it cannot map. An invalid command or commit pattern fails closed
and names `NIGHTSHIFT_FORBIDDEN_COMMANDS` or `NIGHTSHIFT_NEVER_COMMIT_PATTERNS`; fix it in
session settings. `neverCommitPatterns` is case-insensitive, matching
the POSIX `grep -qiE` guard. Implicitly staging commits (`-a`, `--all`, or a pathspec after `--`)
inspect `git diff HEAD`, the same content those commits would write. `expectedEmail` compares
`git config user.email` in the target repository. A command-line override (`-c user.email=`,
`--author`, `GIT_AUTHOR_EMAIL`, or `$env:GIT_AUTHOR_EMAIL`) is denied because the guard cannot
verify it. `protectedDirs` matches the paths Git would write; backslashes in those Git paths are
normalized to `/` before comparing.

Session and lease files are written in one directory, claimed atomically, and protected with a
non-inherited ACL for the current user and Local System before capability content is written.
The ignored, private `.mutex-scope` file gives every path alias to that directory the same named
mutex identity, so junction, symlink, and substituted-drive paths serialize lease changes and
watchman ownership together. The named mutex uses the machine-wide namespace, with access limited
to the current Windows user and Local System, so separate console, RDP, and scheduler sessions
serialize against the same identity. Existing local receipts repositories exclude and untrack the
identity before it is used. A volume that cannot provide the required ACL and hard-link primitives
is refused rather than silently weakening the lease.

## Verification

The `windows-native` CI job runs the lifecycle suite under both Windows PowerShell 5.1 and
PowerShell 7. It uses local host fixtures—no account or model subscription—to cover:

- setup and paths containing spaces;
- workspace links and persisted work targets;
- Doctor, migrate-state, retain-history, import-issues, apply-profile, and export-support helpers;
- artifact-mode write-receipt and archive-receipts helpers;
- PID/start-time evidence;
- atomic session and lease ownership;
- command, rules-file, and lease-file denials;
- Stop release behavior;
- Task Scheduler XML, encoded command generation, and disposable native registration;
- normal Codex recovery through an npm-style `codex.cmd` launcher;
- recovery-child placement, generation/nonce inheritance, and live-process stand-down.

The checked Windows runner is x64. Native Windows on ARM64 is not yet a verified claim.

An authenticated first shift remains part of the
[first-night safety checklist](first-night-checklist.md#first-night-safety-checklist), because CI can verify Nightshift's host
boundary without pretending to verify an owner's account, permissions, or desktop UI.

---

[Check your first attended run](first-night-checklist.md#first-night-safety-checklist) · [Documentation index](README.md#documentation)
