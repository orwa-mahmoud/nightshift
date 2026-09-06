# Troubleshooting

Read-only checks first. Do not delete markers, rewrite `rules.json`, or kill processes until the
matching **Repair** says so. Doctor (`/nightshift:doctor` on Claude Code, or ask Nightshift to
diagnose on Codex) prints what Nightshift resolved and classifies offers; invoking it changes
nothing. For a failed night you want to report, use the
[Failed shift](https://github.com/orwa-mahmoud/nightshift/issues/new?template=failed_shift.yml)
form — not a paste of the transcript.

Host differences that matter here: both Stop hooks refuse an early clock-out. Claude Code's
watchman can revive a live session sitting on a host API-error event. A Codex session that is
**alive but errored is stood by**, not revived, until that signature is captured. Codex SessionEnd
(reason `other`) stands the watchman down — close, archive, or idle unload is pause-recovery;
Start re-arms. A crash with no SessionEnd still revives. Cursor liveness is pulse + pid +
transcript + lease pid; empty pid is not death. `touch .nightshift/STOP` is the POSIX panic stop-work order;
`New-Item -ItemType File -Force .nightshift\STOP` is its native Windows PowerShell equivalent.
Write it in the folder that contains `.nightshift/` — the workspace, or the target of
`.nightshift-link`. A STOP next to the link file is not the order.
That marker waits for the next Stop event or watchman wake. To pause immediately — including when
the model is stuck — run `"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" stop-shift` (native Windows:
`ns.ps1 stop-shift`). Reset drops the deadline but keeps work.
`ns purge-workspace` permanently deletes that project's `.nightshift/` after an exact
`--confirm-path`. None of them uninstall the plugin.
The full Windows boundary is in [Native Windows](windows.md).

## 0. Where is the site?

**Check.** From the folder you opened in Claude Code or Codex:

```sh
pwd
ls -ld .nightshift .nightshift-link 2>/dev/null
```

Native Windows PowerShell: `Get-Location` and
`Get-Item -Force .nightshift,.nightshift-link -ErrorAction SilentlyContinue`.

| You see | Meaning |
|---|---|
| `.nightshift/` directory | This folder owns run state. |
| `.nightshift-link` file, no directory | This task root points at another workspace. |
| neither | Nightshift is not set up here. |

An absent `.nightshift/` is not a crash. Run setup from the project you want Nightshift to change
(`/nightshift:setup` on Claude Code, or ask Nightshift to set up on Codex). ChatGPT scratch paths
under `/workspace/scratch/` are refused on purpose — open the repository in Codex.

**Repair (link only).** If the task is open on a different folder than the workspace that already
has `.nightshift/`, create an explicit pointer. Nightshift never searches nearby folders:

```sh
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" link-workspace \
  --host-root /absolute/task/root \
  --workspace /absolute/nightshift/workspace
```

Native Windows runs the same verb: `ns.ps1 link-workspace --host-root <path> --workspace <path>`.

The target must already contain `.nightshift/`. Relative, missing, multiline, and symlink pointers
are rejected.

## 1. Unsupported or malformed `state-version`

**Check.** After resolving the workspace:

```sh
ls -l .nightshift/state-version
cat .nightshift/state-version
```

A current workspace has a regular file containing the integer `1` and a newline. A missing
file is legacy version `0` — hooks still run. A newer integer, a symlink, extra text, or
anything that is not a single unsigned integer fails closed: start, hooks, status, archive,
and recovery will not guess and will not rewrite the marker.

**Repair.** Upgrade Nightshift when the marker is newer than this plugin supports. Never
downgrade or overwrite a future version. For a missing marker, migrate only while unarmed
and only after an explicit yes:

```sh
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" migrate-state
```

On native Windows:

```powershell
& "$env:CLAUDE_PLUGIN_ROOT\runtime\windows\ns.ps1" migrate-state --project C:\path\to\workspace
```

That command writes only `.nightshift/state-version`. Doctor offers it as a confirmation
repair; invoking Doctor does not run it.

## 2. Invalid `.nightshift-link`

**Check.** If `.nightshift-link` exists:

```sh
ls -l .nightshift-link
wc -l .nightshift-link
cat .nightshift-link
```

A valid link is a regular file (not a symlink) with **exactly one absolute path** to a directory
that contains `.nightshift/`. Anything else fails closed: hooks and skills will not guess.

**Repair.** Remove the broken file and run `ns link-workspace` again (native Windows:
`ns link-workspace --host-root` / `-Workspace`), or work from the workspace
that already owns `.nightshift/`. Do not hand-write a relative path.

## 3. Wrong workspace or work target

**Check.** Run state lives in the resolved workspace. Read the mode first:

```sh
# after resolving the workspace (pwd, or the link target)
sed -n '1p' .nightshift/work-mode 2>/dev/null
sed -n '1p' .nightshift/work-target 2>/dev/null
```

Native Windows: `Get-Content -TotalCount 1 .nightshift\work-mode` and
`Get-Content -TotalCount 1 .nightshift\work-target`.

Missing `work-mode` means repository. In repository mode the code repository may be that same
folder, or the single git child named in `.nightshift/work-target`:

```sh
git -C "$(sed -n '1p' .nightshift/work-target 2>/dev/null || pwd)" rev-parse --show-toplevel
```

Two git repositories as siblings of `.nightshift/` with no `work-target` is undecidable: commit
guards deny rather than pick one.

In artifact mode the work target is the persistent folder itself. There is no work-target git
history. Look at `.nightshift/receipts/` — Doctor reports `artifact receipts N` and, when any
exist, `latest artifact receipt` with the filename of the most recently written receipt. Doctor warns `artifact receipts path is not a usable directory` when that path exists but is not a usable directory, and offers a confirm action to replace it rather than write-receipt. Start, Hunt, Quality, and Schedule refuse when that path is unusable rather than begin a notes-folder night that cannot land receipts. Archive
copies those files with `ns archive-receipts` (native Windows: `ns.ps1 archive-receipts`)
into the dated folder and leaves the live copies in place. Missing or empty receipts create no dated receipts folder. A failing `git -C … rev-parse` here is
expected, not a broken site.

```sh
ls .nightshift/receipts 2>/dev/null
```

Native Windows: `Get-ChildItem .nightshift\receipts -ErrorAction SilentlyContinue`

**Repair.** Re-run setup and choose the folder explicitly. Do not invent a `work-target` by
hand unless it is the absolute git top-level of the repo you mean. Do not `git init` an artifact
folder to satisfy this page.
The GitHub issue hunt is skipped in artifact mode.
The defect hunt is skipped in artifact mode.
Documentation drift is skipped in artifact mode.
TODO and FIXME debt is skipped in artifact mode.
Coverage hunt is skipped in artifact mode.
Tooling quality-debt entries are skipped in artifact mode.

## 4. Unreadable rules

**Check.**

```sh
ls -l .nightshift/rules.json
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" doctor   # prints what the shipped reader made of the file
```

Doctor is the authority here because it uses the same reader the hooks use: it prints
`rules.json is a JSON object` and one line per resolved knob, or names the exact reason the file
was rejected. Nightshift never asks you to install a JSON parser for this.

Native Windows: `Get-Content -Raw .nightshift\rules.json | ConvertFrom-Json | Out-Null`

Watchman refuses to arm when `watchMinutes` is missing or not a whole number, or when
`watchRetrySeconds`, `revivalPrompt`, or `freshRevivalPrompt` are empty. The clock-out stall
guard stands down if `stallMax` / `stallWarnEvery` cannot be read. Editors can validate the file
against the [rules schema](knobs.md#editor-schema) without changing behaviour.

`toolDeny` must contain three native question keys: `AskUserQuestion` for Claude Code,
`request_user_input` for Codex, and `AskQuestion` for Cursor. Missing one does not activate a
hidden default; that question call is denied with a configuration repair. A non-empty value denies
with that message and an empty value explicitly allows the tool.

Exact tool-name matching needs no `jq` and no `python3`: the bundled reader parses `rules.json`
directly, and an unreadable or unsupported file fails closed rather than arming with a guess. What
`jq` still buys on POSIX is the hook payload — a shell command is extracted with `jq` or, without
it, a `sed` fallback, while an MCP payload that cannot be decoded is treated as if it addressed
the process lease and denied. Native Windows uses PowerShell's built-in `ConvertFrom-Json`.

**Repair.** Re-run setup and accept missing keys it offers. Do not paste a half-file over an
owner-edited `rules.json`. During an active shift the session working the night is denied
editing this file — change it yourself between sessions.

## 5. STOP vs stale arming

**Check.**

```sh
ls -l .nightshift/STOP .nightshift/.shift-armed .nightshift/.ended \
  .nightshift/.session-end .nightshift/.shift-pulse .nightshift/.shift-lease .nightshift/.stall \
  .nightshift/.watchman 2>/dev/null
sed -n '1,5p' .nightshift/STOP 2>/dev/null
```

Native Windows: `Get-Content -TotalCount 5 .nightshift\STOP`

| Marker | Meaning |
|---|---|
| `STOP` | Stop-work order. The gate releases at the **next stop attempt**; open boxes stay open. Site rules stay armed until then. |
| `.shift-armed` | A shift was started. Without it, `punch-list.md` is only a to-do file. |
| `.ended` | The gate already clocked the shift out. |
| `.session-end` | Owner closed the session (Claude, Cursor `aborted`/`user_close`, Codex reason `other`). Watchman stands down; Start re-arms. |
| `.shift-pulse` | Overwrite-only liveness from the bound session. Fresh pulse keeps watchman standing by. |
| `.shift-lease` | Transient process ownership for the bound shift. A watchman advances it before each recovery attempt; do not print or edit its capability line. |
| `.mutex-scope` | Private Windows mutex identity. It persists across shifts so alternate paths and Windows logon sessions share the same lock; do not print, edit, or delete it. |
| `.stall` | Stuck stop-attempt count. Not an ending. |

A leftover `STOP`, `.ended`, `.session-end`, `.shift-pulse`, `.shift-session`, or `.shift-lease` from last night
will surprise tonight. Start clears stale run-control markers before it arms. Do not delete them by
hand while a session is still working the list.

A leftover Shift contract is different: Archive and Start leave it in place. After a finished
campaign, `punch-list.md` can have zero open boxes and still name last night's branch, release,
and issue-close list. The next Hunt cut inherits that text. Status and Doctor report it; review
the contract and Gates before composing a new campaign. Do not delete the punch list to "clear"
it. Re-run Setup while Items are empty to be offered a restore of the shipped contract.

**Repair (you want the shift ended now).** From any terminal at the workspace that owns
`.nightshift/`:

```sh
touch .nightshift/STOP
```

Native Windows: `New-Item -ItemType File -Force .nightshift\STOP`.

**Repair (you want a new shift and no session is alive).** Run start. It is what clears last
night's leftovers. Killing `.watchman`'s pid is start's job when that pid is still live.

If Doctor calls the lease malformed, Start fails closed instead. Issue STOP and confirm no worker
or watchman is alive. On POSIX, load `lib/lib.sh` and call `ns_lease_reset_stale` as printed by
Start; on native Windows, import `lib\Nightshift.psm1` and call
`Reset-NSStaleLease .nightshift`. Never print, hand-edit, or selectively delete the lease.

## 6. Missing session identity

**Check.** Immediately after arming, Start — and Hunt or Quality when they start immediately —
make a harmless Bash binding probe on POSIX or a
PowerShell binding probe on native Windows. It writes
`.nightshift/.shift-session` before item work. Typical layout: session id, transcript or rollout
path, pid, process start time, host (`claude` or `codex`). Claude fills the process fields when it
can verify them. Codex leaves lines 3–4 empty on POSIX because its hook cannot vouch for a process
identity; native Windows records them when process ancestry is available.

The binding probe also creates `.shift-lease`. It records session scope, host, ownership
generation, a capability field that stays empty until recovery, and the current process witness.
That capability is intentionally not a diagnostic value: use Doctor to see lease validity, host,
generation, mode, and holder liveness without printing it. A missing lease on an older armed
workspace is bootstrapped by the bound session's next tool call.

```sh
sed -n '1,5p' .nightshift/.shift-session 2>/dev/null
```

Native Windows: `Get-Content -TotalCount 5 .nightshift\.shift-session`

A 500 can land **before** the binding probe, so the file may be missing while the punch list is
open. On Claude Code the watchman then treats the newest conversation ending in the host's API-error
event as the wedge and resumes with `--continue`. On Codex, with no recorded id, revival falls
back to a fresh headless run; the punch list on disk is the handover.

**Repair.** Do not invent a session id. If the shift is still armed and boxes are open, let the
watchman run, or start a fresh session that reads the punch list. Pasting an id from another
project will append to the wrong conversation.

## 7. Watchman stood down or will not revive

**Check (read-only).** Tail the journal; do not truncate it:

```sh
tail -n 40 .nightshift/shift-log.md
ls -l .nightshift/.watchman .nightshift/.watchman-tick 2>/dev/null
```

Native Windows: `Get-Content -Tail 40 .nightshift\shift-log.md`

Stand-down is success when the night already reached a declared ending. Matching log lines:

| Log (substring) | Host | What it means |
|---|---|---|
| `stop-work order — standing down` | both | `STOP` exists. |
| `shift is owned by` | both | This watchman is the wrong host. The other host's watchman owns the shift. |
| `clean session end` | Claude Code | Owner closed the session on purpose. |
| `owner pressed Esc — standing by` | Claude Code | Interrupt in the transcript tail. Not a death. `STOP` ends the shift. |
| `long silent work; standing by` | Claude Code | Process alive, quiet, no API-error tail. |
| `a claude session is live in this project` | Claude Code | Another Claude process in the project; revival refused to avoid two writers. |
| Codex process or rollout still growing | Codex | Alive; stood by. A live-but-errored Codex session is **not** revived. |
| `watchMinutes missing` / `cannot arm` | both | Unreadable rules. See §4. |
| `all N attempts failed` | Claude Code | Revival failed; the next knock comes at the interval. |
| `backing off, knocking again in Mm` | Claude Code | The last error named a limit. The wait doubles, up to an hour; a pulse or a revival puts it back to the interval. |
| `the armed marker is gone` | both | `.shift-armed` is no longer there. Nothing is armed, so nothing is watched. Start re-arms. |
| `the watchman pidfile is gone` / `another watchman owns this site` | Claude Code | `.nightshift/.watchman` was removed or claimed by another loop. |
| `resumed session returned` / `revival returned` | both | Revival succeeded. |

**Repair.** None, if the line is a declared ending. If rules cannot arm, fix `rules.json` and
re-run start. If the wrong-host watchman stood down, leave it — the recorded host's watchman is
the one that should be running. If you pressed Esc and wanted the night to continue, resume that
session yourself; the watchman will not.

To report a revival that should have fired and did not, file a
[Failed shift](https://github.com/orwa-mahmoud/nightshift/issues/new?template=failed_shift.yml)
with sanitized markers only.

## 8. The watchman revived, but the IDE still shows the error

**Check.** An already-open Claude Code or Codex conversation panel may not reload turns appended by
a headless resume. The unchanged error screen therefore does not prove recovery failed, and the
owner does not need to watch the recovery. The headless worker continues against the punch list; if
you want confirmation, inspect `shift-log.md` for the watchman's revival attempt rather than
sending another prompt from that panel. If the stale process later reports that the shift continued
in a recovered process, the process lease is working: its tool call was rejected before execution.

**Repair.** Close and reopen the recorded conversation from the IDE's conversation history. When a
Claude session ID was recorded, Nightshift writes its `claude --resume <session-id>` command and
IDE deep links to `parking-lot.md` after the headless subprocess exits successfully. That may not
happen until the revived run finishes. `shift-log.md` provides an optional live receipt through its
`resume attempt` entry. Codex records its recovery in the shift log; reopen the durable thread from
history only when you want to inspect or interact with it.

Do not continue in the stale panel while the headless process may still be active. The lease fences
observable shift tools there, but it cannot refresh the display. Other conversations in the same
project remain ordinary and can work normally; only a second Start is refused while this shift is
active.

If Doctor says the lease is malformed, or work was already interleaved before the fence took
effect, run Stop (`/nightshift:stop` on Claude Code, or ask Nightshift to stop on Codex) from a
separate helper conversation, or run `ns` from a terminal — adding `--project <path>` when you are
not already in the project.
That disarms immediately and releases the lease. Wait for the active process to stop, inspect the work target and shift log, then run Start; do not rewrite `.shift-lease` by hand. A bare `touch` leaves the watchman running until it checks the marker after the current
subprocess returns or on its next wake.

Automatic refresh is tracked in
[anthropics/claude-code#82655](https://github.com/anthropics/claude-code/issues/82655),
[openai/codex#28259](https://github.com/openai/codex/issues/28259), and
[openai/codex#21743](https://github.com/openai/codex/issues/21743). Resolving those display-sync
gaps would remove the manual reopen and make the handoff more consistent; it would not switch
recovery on. The watchman already runs the recovery, and the process lease already fences the stale
worker.

## See also

- [Command reference](commands.md) — setup, start, status, doctor, stop, reset, purge, schedule
- [Shift modes](shift-modes.md) — copyable Hunt and Quality launch combinations
- [Owner knobs](knobs.md) — `rules.json` and env overrides
- [First-night safety checklist](first-night-checklist.md)
- [Security policy](../SECURITY.md) — public issues by default; private advisory is optional
