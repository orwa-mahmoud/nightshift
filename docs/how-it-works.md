# How Nightshift works

Nightshift is a native plugin for Claude Code, Codex, and Cursor. It adds no proxy, hosted
service, or second agent runtime. Skills define the working method, files preserve the contract, hooks enforce
the host-specific boundaries that are available, and local shell or PowerShell processes handle
scheduling and recovery when no live session can act.

The workflow skills are shared, but their host boundaries are explicit. Each resolves the
host-opened project through Claude Code's project path, Cursor's project path, or, on Codex, a
Nightshift recovery override or the launch directory captured before any shell call can change it.
Those become one neutral task-root and workspace name. Bundled files follow the same pattern:
Claude Code substitutes its plugin root, Cursor uses `CURSOR_PLUGIN_ROOT` when set, and Codex uses
its plugin root when available or the absolute path attached to the loaded skill. From there the
skill uses one neutral plugin-root name. Hooks, session signals, permissions, and watchmen remain
separate where the hosts actually differ.

## The work contract

Setup creates a local `.nightshift/` workspace. The important files are plain Markdown:

- `punch-list.md` — the work and its completion state;
- `drafting-table.md` — known work that has not been promoted into the active shift;
- `parking-lot.md` — decisions made without blocking the run;
- `work-orders.md` — catalog work composed by Hunt or Quality;
- `product-research.md` and `opportunity-map.md` — evidence and continuation state for product
  evolution;
- `snag-log.md` — problems found and their disposition;
- `shift-log.md` — progress, stalls, recovery, and clock-out.
- `shift-report.md` — live item progress, results, verification, and measured token usage and duration.

Completion lives in checkboxes, not in a conversational claim. Normal clock-out is reached only
when every open `- [ ]` under `## Items` is ticked; checkboxes elsewhere in the file do not belong
to the gate. A crash or compaction can discard conversation detail without discarding the
objective, completed items, open work, or verification still due. Product-evolution and
owner-walkthrough shifts also keep the active unit's completed work, decisions, rejected paths,
exact next action, and remaining verification in `opportunity-map.md`.

Only checkboxes under `## Items` in `punch-list.md` belong to the active contract. A list alone does
not activate hooks: Start, or a Hunt or Quality path that starts immediately, creates
`.shift-armed` after preflight. The clock-out gate and owner rules are active while that marker
exists and the shift has not ended. A `STOP` order keeps hardhat on until clock-out writes
`.nightshift/.ended`; open boxes stay as the record. Reset is the manual escape.

**A shift that ended stays ended.** Adding an unchecked item afterwards does not put you back on
shift: the gate releases, your rules stop applying, and the watchman will not revive it — the
punch list is an ordinary to-do file again, whatever leftover `STOP`, deadline, policy or stall
file is still lying about. Working those items as a shift takes an explicit Start, which arms a
new marker and a new identity. That is the same boundary as the first time: a list is not a shift
until someone starts one.

Archive files ticked items and never resets the leftover Shift contract or Gates. An empty
`## Items` section still binds the next Hunt or Start cut — review those sections before
composing a new campaign. Status and Doctor report the leftover; Archive writes a Notes reminder
when a campaign is fully filed.

Start asks nothing when items are queued; an empty list offers staged work for approval.
Before it arms, it runs one native preflight —
`ns start-preflight` (native Windows: `ns.ps1 start-preflight`) — which prints
one verdict per line: `ok` for a fact worth stating, `warn` for something the owner should hear
while the shift still arms, and `refuse` for a condition that stops it. The sentences are
byte-identical on POSIX and native Windows, so a scheduled or headless run behaves exactly like an
interactive one. Host-specific detail behind a verdict lives in
[`references/hosts/`](../plugins/nightshift/skills/nightshift/references/hosts/).

Immediately after arming, Start — and Hunt or Quality when they start immediately — make a
harmless host-shell probe—Bash on POSIX, PowerShell on
native Windows—that records `.shift-session` before item work and creates `.shift-lease` for that
process. Passive reads, searches, and MCP calls cannot
make that first claim. The complete session record appears atomically; if two Start probes race,
one wins and the other is explicitly rejected. Gate and guard decisions then apply to the bound
session and current lease owner; another conversation opened beside the shift can chat, ask, or
issue the stop-work order without inheriting the shift gate. The session record's fifth line names
its host (`claude` or `codex`); legacy records without that line belong to Claude Code.

Start also refuses to place a second agent beside a live shift. It returns the recorded session
handoff instead. A helper conversation remains outside the gate, but it is not
permission to start another shift on the same contract. It is outside the shift command guards too:
the helper can chat and ask freely, but it is not a safe channel for commands the shift rules deny.

`rules.json` contains the owner-controlled hooks configuration. `work-target` records the repository
that receives code changes when state lives in a parent workspace. `state-version` prevents newer
or malformed state from being interpreted by older hooks; unsupported versions fail closed.

## Three policy layers and one resolved view

Nightshift separates **what the project always forbids**, **what the owner usually prefers**, and
**what tonight's shift authorizes**:

| File | Role |
| --- | --- |
| `rules.json` | Permanent boundaries: tool denies, commit guards, retention, and the five elevation categories (`sudo`, containers, global-packages, daemons, external-services). The shipped template denies each by default. Containers cover the Docker socket and create-state verbs (`run`, `create`, `compose up`, `start`, `build`); read-only forms such as `docker ps` and `brew list` are not gated. Hardhat is hardening, not a sandbox. |
| `shift-defaults.json` | Only in a workspace that has not migrated. The same four remembered choices now live in the `shift` block of `rules.json`; `ns shift-policy migrate` moves them, and until it runs they are still read from here. Neither file is ever the source of an effective value. |
| `shift-policy.json` | Tonight's authoritative snapshot: deadline, verification level, tooling policy, one-shift elevation allowances with provenance, and the shift identity they bind to. Written by composition or Start; guarded while armed. |

Status and Doctor render **one resolved policy block**: every effective setting, its source file,
and each elevation category with whether it is allowed permanently, for one shift, or denied.
Preflight compares punch-list needs against that view before arming.

**Verification profiles** (`fast`, `balanced`, `strict`, `custom`) live in
`references/profiles/`. `fast` is first-class: no automated checks, items and receipts only.
`balanced` runs existing fast checks per item and a full suite at the end. `strict` runs applicable
checks per item and at the end. Profiles propose defaults during Setup; owner rules remain
authoritative.

**Tooling policies** are `existing-tools` (scan with what is already installed),
`review-missing` (hold the clock until the owner approves a plan for what is missing), and
`auto-add` (add tools under the elevation categories the shift already allows). Artifact mode is
always `existing-tools`. Start never asks: a composition step records the choice on the policy
snapshot, and Start works with what it finds.

**Parsers.** The plugin ships no Python. POSIX hooks read `rules.json` with a bundled reader that
needs neither `jq` nor `python3`; an unreadable or unsupported rules file fails closed and does not
arm. `shift-policy.json` is JSON that the bash helpers read with `jq`, falling back to an inline
`python3` program when `jq` is absent — with neither installed, Start says so and arms from
`rules.json` alone rather than asking the owner to install anything. An MCP payload the hardhat
cannot decode is treated as if it addressed the process lease, so an opaque call is denied rather
than waved through. Native Windows uses PowerShell's built-in `ConvertFrom-Json` throughout and
needs no third-party parser.

## Mechanical gates and owner rules

On Claude Code, Codex, and Cursor, an attempted stop with open punch-list items receives the
focused contract again. On every host, hook-backed rules can deny commands, protected paths,
suspicious secret patterns, or commits under the wrong identity.

The five elevation categories deny by default. Optional command, path, identity, and secret
guards (`forbiddenCommands`, `protectedDirs`, `expectedEmail`, `neverCommitPatterns`) stay empty
until the owner sets them; Setup proposes them and the owner chooses. The three explicit
question-tool entries are the exception: the shipped rules park questions so an unattended shift
does not wait, and the owner may set any of them to an empty string to allow that host's
question tool. Active rules hold in every permission mode, including a
broadly permitted unattended session. That combination lets the host run without approval prompts
while hooks still enforce the owner's configured boundaries—a frictionless permission mode plus
an owner-specific denylist that host permissions alone do not express.

Hooks enforce command and stop boundaries. They do not prove that the work behind a checked box is
good. Verification belongs in each item's gate, and a human still reviews the resulting commits.
Doctor (`/nightshift:doctor` on Claude Code, or ask Nightshift to diagnose on Codex) prints what
Nightshift resolved — facts, warnings, and classified next actions — and never repairs.

## Questions, stalls, and deadlines

During a shift, questions are parked with a sensible default instead of silently waiting for the
owner. An owner watching live can answer immediately; otherwise the decision remains on disk for
morning review.

That mechanical policy is explicit in `rules.json`: `toolDeny.AskUserQuestion` controls Claude
Code, `toolDeny.request_user_input` controls Codex, and `toolDeny.AskQuestion` controls Cursor.
A non-empty value denies that exact tool with the owner's message; an empty value allows it. The
[tool-rules reference](knobs.md#tool-rules) explains the remaining contract text an owner changes
for an interactive, ask-and-wait shift. Existing workspaces should re-run Setup after upgrade and
accept the offered `request_user_input` or `AskQuestion` entry; Nightshift never inserts either
without confirmation.

Run directly authorizes reasonable, reversible implementation defaults without a second approval
pause. Significant decisions, rejected paths, and rollback instructions stay in `parking-lot.md`
for morning review; publishing, destructive changes, and owner policy remain out of scope unless
explicitly authorized.

Review-first Hunt and Quality runs scan or draft only and arm nothing until the owner approves.
Copyable owner requests for each combination are in [Shift modes](shift-modes.md#shift-modes).
Run-direct paths perform the same Start preflight before arming.

A no-progress stop attempt is logged as a stall while the finite contract remains open. Owners who
prefer a hard retry cap can set `NIGHTSHIFT_STALL_MAX=N`. Open-ended shifts require a deadline
in `.nightshift/deadline` as UNIX epoch seconds; Start refuses to arm one without it. Finite
shifts may also use one as a cap.

The stall guard reads checked items and commits as progress in repository mode, and checked
items and artifact receipts in artifact mode. A deadline is therefore the final
cost boundary when failed attempts could otherwise keep producing commits. Without a deadline or
stall cap, a finite shift can remain held and retry until the owner intervenes.

## Recovery

No hook can recover the session it was running inside after that process dies. Nightshift's
watchman runs outside the session, records the active conversation identity, and wakes
periodically. The default cadence is ten minutes and is owner-configurable.

Both watchmen act only on a shift recorded for their own host and require positive evidence before
reviving a dead session. When a resumable identity exists, they target that conversation first;
the host-specific continuation and fresh-session fallbacks below cover failed resume attempts or a
missing identity. They never revive merely because a workspace “looks stuck”: builds, syncs, logs,
and all other project-file activity do not vote on session life. They stand down for a completed
shift, a stop-work order, quitting time, or a shift owned by the other host.

Immediately before each revival attempt, the watchman atomically advances `.shift-lease` to a new
generation and passes that generation's ownership nonce to the child process. Every observable
tool call from the bound shift is checked against the lease. The recovered child is admitted; an
older UI or headless process on the same conversation is denied and told to reopen the thread. A
retry advances the generation again, fencing a previous recovery attempt that outlived its caller.
The clock-out gate checks the same ownership before changing stall, STOP, ending, or receipt state.

The lease is scoped to the shift, not the project. Unrelated tabs and conversations continue to
work normally, while a second Start still refuses because an armed shift already exists. Normal
completion, a processed stop-work order, quitting time, or an opted-in stall ending releases the
lease. It is transient, excluded from receipts, and its capability is omitted from support output.
While the shift is active, hooks deny agent tools in any conversation from targeting the lease
itself; ownership changes only through Start, the watchman, or clock-out.

One narrow fail-closed window exists when recovery began before any session identity could be
recorded. Until the recovered child's first observed call binds its new identity, Nightshift cannot
distinguish that child from a helper conversation, so only the child carrying the recovery nonce is
admitted. Once bound, unrelated conversations are free again.

Native Windows uses the same lease and marker contract through bundled PowerShell. Hooks identify
the host ancestor through `Win32_Process`, verify a recorded PID with its UTC start time, and
protect lease capabilities with a private Windows ACL. Task Scheduler generation is the Windows
counterpart to launchd, cron, and systemd generation. The complete parity and the conservative
limits around process evidence, login state, and filesystems are documented in
[Native Windows](windows.md#native-windows).

Claude Code provides additional transcript and session signals. Its liveness ladder checks the
shift transcript for the owner's Escape first, then checks current transcript activity, the
recorded process, the host's `claude agents --json` roster, and other Claude processes in the
project. Any positive evidence of live work—or unavailable process evidence—stands down rather
than guessing. A live session whose latest conversation event is an API error can instead be
classified as wedged and resumed. A clean `SessionEnd` also stands the watchman down.

Positive revival evidence is the inverse: a recorded process proved dead, a responsive host roster
without the shift session, or an API-error event at the end of a live conversation with nobody
acting.

Codex SessionEnd stands the watchman down: closing, archiving, or an idle unload (about 30
minutes with no client) is pause-recovery. The punch list stays; Start re-arms. A crash that
never fires SessionEnd still revives. A fresh `.shift-pulse`, a live recorded process, or a
growing rollout keeps the watchman standing by. Empty pid alone is not death. A live session
that appears wedged on an API error is also left alone until a stable rollout signature has
been captured and classified; see
[#41](https://github.com/orwa-mahmoud/nightshift/issues/41).

With the shipped rules, each Claude watchman wake makes up to three attempts when it has a session
ID: `claude --resume <id>`, then `claude --continue`, then a fresh `claude -p`. Without a recorded
ID, the first attempt is `--continue`. Codex also makes up to three timed attempts, but its rungs
are `codex exec resume` when the identity is resumable, then fresh `codex exec` fallbacks. The
pauses come from `watchRetrySeconds` in `rules.json`.

Every attempt re-runs the host's liveness ladder first, so an owner action or returning session
cancels the remaining retries. An exhausted wake waits for the next one rather than declaring the
night over.

Codex same-conversation revival requires a resumable identity in `.shift-session`; ChatGPT thread
handles, rollout paths, and other known non-resumable identities stand down rather than opening an
unrelated conversation. A missing first identity may use the documented fresh fallback. In every
case, the punch list remains the authoritative handoff.

### Reopening a revived thread

A headless revival appends to the recorded Claude conversation, but an IDE panel that was already
open does not reload turns written by that external process. Close and reopen the recorded thread
from conversation history to see the current transcript. When a recorded session ID exists, the
watchman writes `claude --resume <session-id>` plus Cursor and VS Code deep links to
`parking-lot.md` after the headless subprocess exits successfully—which may not be until that run
finishes. The recovered worker needs no owner monitoring: it continues against the punch list, and
`shift-log.md` records the `resume attempt` for optional inspection.

Do not type **Continue** in the unchanged panel while a headless revival may be working. If the old
process reaches an observable tool, the process lease rejects it before that tool runs. Reopening
is required only to see or interact with the current transcript because the lease cannot refresh
the host's UI. Claude live refresh is tracked in
[anthropics/claude-code#82655](https://github.com/anthropics/claude-code/issues/82655).

Codex has the same stale-window boundary: `codex exec resume` can append to the durable session
without refreshing an already-open Desktop thread. Reopen it before prompting again. The lease
fences observable tools in the stale process; it does not repair the display. Upstream tracking:
[openai/codex#28259](https://github.com/openai/codex/issues/28259) and
[openai/codex#21743](https://github.com/openai/codex/issues/21743).

Those three reports concern display and session-index synchronization. If the hosts resolve them,
the manual reopen can disappear and the recovery handoff can feel consistent across interactive
and headless use. The watchman, on-disk contract, and process lease still provide the recovery and
safety behavior; broader context-continuity reports discussed below can affect resume quality and
are not merely interface polish.

## Stop means stop

Escape and Ctrl+C remain available host interrupts; Nightshift cannot override the owner's
keyboard. They pause or interrupt the current process without clearing the punch list. A clean
Claude session exit is different: it tells the watchman to stand down until Start re-arms. A
headless run has no Escape. On Claude Code, Escape in the shift transcript also tells the watchman
to stand by. Codex exposes no equivalent owner-interrupt signal; closing an interactive Codex
session with open Items leaves the armed shift to its watchman. To end the shift itself on either
host, use the host Stop command or the terminal helper in the folder you opened:

```bash
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" stop-shift
```

Native Windows PowerShell:

```powershell
ns.ps1 stop-shift --project C:\absolute\task\root
```

That writes `STOP` and kills only a verified watchman. `.shift-armed` stays, so hardhat
remains until clock-out writes `.nightshift/.ended`. Reset is the manual escape. The deadline and punch list
stay. Reset (`ns reset-shift` / `ns reset-shift`) drops runtime markers and the deadline. Purge
deletes that project's `.nightshift/` after an exact `--confirm-path`. None of them uninstall the
plugin.

The panic form in the folder that contains `.nightshift/` (not beside `.nightshift-link`) still
works, but it waits for the next Stop event:

```bash
touch .nightshift/STOP
```

Native Windows PowerShell uses
`New-Item -ItemType File -Force .nightshift\STOP`.

Open boxes remain open, preserving the exact stopping point. Start resumes a paused Stop. An
expired preserved deadline is not silently replaced; write a new UNIX epoch or run Reset first.

## Receipts

Nightshift leaves reports, timestamps, cycle logs, parked decisions, and snag dispositions under
`.nightshift/`; work-target commits live in the project's own Git history. The state folder is
ignored by the project repository. Setup can
optionally version it in a separate local-only Git repository. That repository is off by default;
Nightshift gives it no remote and never pushes it. Clock-out and Archive commit it with `git -C`,
identity `nightshift@localhost`, and `commit.gpgsign=false` so a global signing requirement cannot
stall a headless snapshot.

The gate blocks every turn that ends with work still open, and the reason it returns is the owner's `clockOutMessage`. With `clockOutReminderMode` set to `changed-only` it sends that message when something actually moved and one short line when nothing did — and anything it cannot be sure about, including a compacted conversation, counts as moved. The block never becomes optional and its reason is never empty.

Archiving moves finished work under the archive root — `.nightshift/archive/<YYYY-MM-DD>/` by default, or wherever `archive.root` and `archive.layout` say — while keeping the current working
files small.

For the review workflow, see [Shift report and token usage](shift-report.md#shift-report-and-token-usage) and
[Archive and continue](archive.md#archive-and-continue).

## Different strengths on each host

Claude Code and Codex expose the Stop event Nightshift uses to refuse an early clock-out while
open Items remain. Both also receive the persistent contract, owner rules, bounded shifts,
recovery after a dead resumable session, isolated changes, and reviewable progress. Those
capabilities ship as native skills and hook wiring from one package; Nightshift wraps and proxies
nothing.

Cursor is a third native front door (`.cursor-plugin`, shared skills, Cursor-shaped hooks). It
shares the same `.nightshift/` site. Clock-out reads Cursor's `stop.status` (`completed` | `aborted` | `error`). A live
Stop-button payload sends `aborted` — same owner interrupt as Claude Escape: the gate
releases, the punch list stays, the shift stays armed. Agent completion with open boxes
keeps the gate; `error` is not owner-stop.
`sessionEnd` reasons `aborted` and `user_close` record a clean-close marker for the Cursor
watchman. The bound conversation is the origin IDE tab (`conversation_id` under
`~/.cursor/projects/.../agent-transcripts`). Cursor's CLI (`agent --resume`) uses a separate
store (`~/.cursor/chats`). Those ids are not interchangeable: never pass the IDE
`conversation_id` to `agent --resume` and call it the same chat. Start arms the Cursor
watchman when `watchMinutes` is not `0`. After an IDE death it mints a CLI worker
(`.shift-worker`) and resumes that id; later wakes resume the same worker. The origin IDE
tab is denied with the attach command while that worker holds the shift. Other IDE tabs in
the same project stay outside the gate. Closing the origin tab is not a clean session end
once a worker is recorded. Do not arm the Claude or Codex watchman from a Cursor session.
Add the public GitHub repo as a Cursor marketplace source
(`.cursor-plugin/marketplace.json` at the repo root, same role as the Claude
marketplace file). Official marketplace listing waits on a
verified Cursor shift with watchman recovery. The Cursor CLI (`agent`) currently ignores
marketplace and local plugin hooks and only runs project `.cursor/hooks.json`. Setup can
copy the shipped Cursor hook file there on an explicit yes; that is a Cursor limitation,
not a Nightshift skip.

The differences among the hosts are in recovery evidence. Claude Code exposes Escape,
clean session-end, process, transcript, pulse, and API-error signals. Codex exposes SessionEnd
(reason `other`), pulse, process, and rollout activity, but not Escape or a verified API-wedge
signature. Cursor liveness is pulse plus recorded pid plus transcript growth plus lease pid;
an empty pid is never death by itself.
Same-conversation Codex recovery also depends on a resumable identity recorded before the original
process disappears.

Claude's initial interactive lease can include the CLI ancestor's pid and process start time.
On POSIX, Codex's hook payload cannot prove equivalent process ancestry, so its initial lease is
scoped to the bound session; the watchman's private generation nonce supplies the process fence
once recovery begins. Native Windows hooks can walk the Codex process ancestry and record the
same PID/start-time pair when the operating system exposes it.

Nightshift does not claim to repair either host's conversation history. It keeps the important
working state independent of that history. Claude Code's strongest host-specific behavior is the
complete recovery ladder around its transcript and session signals. Codex's strongest additional
value is a bounded shift, durable product-research and opportunity state, mechanical owner rules,
and reviewable progress around a naturally persistent task.

The host continuity failures around this boundary have been reported by Codex users in
[#25900](https://github.com/openai/codex/issues/25900),
[#8310](https://github.com/openai/codex/issues/8310), and
[#29356](https://github.com/openai/codex/issues/29356), and by Claude Code users in
[#6159](https://github.com/anthropics/claude-code/issues/6159) and
[#43044](https://github.com/anthropics/claude-code/issues/43044). Nightshift preserves the working
contract around those failures; it does not patch either host's context engine.

## Workspaces and repositories

Nightshift resolves two locations and persists both decisions:

- the **state workspace** owns `.nightshift/`;
- the **work target** is the folder that receives inspection, edits, and verification. In
  **repository** mode it is a Git repository (stack detection, gates, commits). In **artifact**
  mode it is a persistent non-Git folder. The path is stored in `.nightshift/work-target` and the
  mode in `.nightshift/work-mode` (`repository` when that file is absent). A plugin or
  marketplace manifest may sit at a repository work-target root or under `plugins/<name>/`.

State resolution never searches parent or sibling folders. Work-target resolution accepts the
opened repository or exactly one immediate, non-hidden child repository. Skip a symlink or reparse child; it is not a nested checkout. Several candidates require
an explicit choice.

### Repository root (supported)

Open a repository directly to keep local state at its root:

```text
repo/                  ← state workspace and work target
├── .git/
└── .nightshift/       ← gitignored run state
```

Setup may create an optional local receipts repository inside `.nightshift/`; it never adds a
remote.

### Parent with one repository (supported)

For separation by construction, open a plain parent workspace with one repository:

```text
my-project/            ← workspace opened in the host
├── repo/              ← the repository that may eventually push
├── .nightshift/       ← local run state and receipts
└── .claude/           ← local Claude Code settings, when used
```

Setup resolves the sole child repository once and persists its canonical path. Because
`.nightshift/` is outside that repository, run state cannot enter its history by mistake.

### Git worktree (supported)

An opened Git worktree resolves to its own top level, including when `.git` is a worktree pointer
file rather than a directory:

```text
feature-worktree/      ← state workspace and this worktree's work target
├── .git               ← Git-managed worktree pointer
└── .nightshift/
```

Each worktree uses its own state by default. To share an existing Nightshift workspace deliberately,
use the explicit link described below. A parent containing several worktrees is the same as any
multi-repository parent: Nightshift requires a selected work target instead of guessing.

### Parent with several repositories (selection required)

This layout is refused until Setup records an explicit choice:

```text
workspace/
├── repo-a/
├── repo-b/
└── .nightshift/
```

Setup shows the repository choices and writes the selected canonical top level to
`.nightshift/work-target`. Start refuses to arm if that record is absent, invalid, or no longer a
repository. Nightshift never selects the first directory silently.

### Persistent folder (artifact mode)

A local non-Git folder can be the work target when Setup proposes artifact mode and the owner
confirms. Typical uses are research, documentation, audits, and planning workspaces:

```text
notes/                 ← state workspace and artifact work target
├── research/
└── .nightshift/       ← run state; work-mode is artifact
```

`$NS/work-mode` contains `artifact`. `$NS/work-target` is the folder's canonical path. Setup
refuses `/workspace/scratch/` and any path under it — that ChatGPT workspace is disposable.
Start, Status, Doctor, Archive, Schedule, and workspace links read the same mode record. Existing
repository workspaces stay repository mode when `work-mode` is absent.

Artifact mode records item completion in the shift report by default. When
`report.legacyItemReceipts=true`, it also writes a file under `$NS/receipts/` with
`ns write-receipt` (native Windows: `ns.ps1 write-receipt`). That optional receipt
records the item, output paths, verification, optional decisions and sources, timestamps, and
file identity (bytes, SHA-256, mtime). Missing or empty outputs are refused. The stall guard
treats a new receipt like a commit; Doctor reports `artifact receipts N` and, when any exist,
`latest artifact receipt` with the filename only of the most recently written receipt;
it warns `artifact receipts path is not a usable directory` when that path exists but is not a usable directory, and offers a confirm action to replace it rather than write-receipt; Start, Hunt, Quality, and Schedule refuse when that path is unusable rather than begin a notes-folder night that cannot land receipts;
Archive copies receipts with `ns archive-receipts` (native Windows: `ns.ps1 archive-receipts`)
into the dated folder and leaves the live files in place. Missing or empty receipts create no dated receipts folder.
Repository mode follows the contract's commit policy: per-item commits, a coherent batch, or
uncommitted work when requested.

Cited reports in that folder follow `cited-research.md` and
`ns check-report` (native Windows: `ns.ps1 check-report`). Hunt's SEO audit,
documentation writing, and research-synthesis entries inherit that contract. Automatic Hunt skips
quality-debt entries the folder cannot support and skips the GitHub issue hunt in artifact mode;
imported drafts stay on the drafting table. It also skips the defect hunt in artifact mode.
It also skips documentation drift in artifact mode.
It also skips TODO and FIXME debt in artifact mode.
It also skips coverage hunt in artifact mode.
It also skips tooling quality-debt entries in artifact mode.

### Linked task root (explicit opt-in)

If the host task and state workspace must be different folders, create one explicit link:

```bash
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" link-workspace \
  --host-root /absolute/task/root \
  --workspace /absolute/nightshift/workspace
```

Native Windows runs the same verb: `ns.ps1 link-workspace` with `--host-root` and `--workspace`.

The task root receives a machine-local `.nightshift-link`, excluded through Git's local
`info/exclude` when applicable. This file is a trust boundary: it must be a regular file—not a
symlink—with exactly one absolute path to an existing directory that already owns `.nightshift/`.
Blank extra lines, relative paths, missing targets, symlinks, and targets without `.nightshift/`
fail closed.

The linked workspace becomes authoritative for every state read and write; no state is copied.
The link does not choose the code repository—that remains the linked workspace's persisted
`.nightshift/work-target`. Project settings stay at the host task root.

This repository is maintained with a parent state workspace and a nested public work target.

Remote SSH and devcontainers use these same layouts only when the host process, plugin, repository,
state workspace, hooks, and watchman all run inside the remote environment. The reproducible matrix
and the refused split-runtime boundary are in [Remote environments](remote-environments.md#remote-ssh-and-devcontainers).

## Guarantees and limits

- **Mechanical:** hooks govern when either host may stop and which configured commands or paths are
  denied during the shift.
- **Conventional:** the skill and punch-list contract govern the quality represented by a tick.
  The model reports its own completion; the owner and item checks verify it.
- **No lint or tests is a first-class setup path:** setup does not invent project tooling. The
  item's observable definition of done carries the verification instead.
- **Contract reinjection is not proof:** every blocked stop receives the working standard again,
  including no stubs, pass the item's gate, and never fake a tick, so that standard does not decay
  out of context. This proves only that open Items prevented an early clock-out—not that a checked
  item is good.
- **Completion beats cost by default:** a stuck finite shift remains held and flagged. Add a
  deadline or `NIGHTSHIFT_STALL_MAX` when a cost boundary matters more than indefinite retry.
- **Progress is approximate:** the stall guard treats ticks, commits, and artifact receipts as progress, so a failed
  attempt committed by the agent can look alive. Item checks and the deadline remain the backstop.
- **No built-in push block:** pushing is allowed unless the owner adds it to the shift rules.
- **Hardhat is hardening, not a sandbox:** shell-command rules match command text. The pattern
  rules prevent accidental drift by a cooperative agent; they are not unbypassable isolation.
- **The process lease fences observed tools:** it rejects stale-process calls delivered to the
  host's PreToolUse hook after ownership transfers. It cannot revoke a call already admitted,
  refresh the IDE, terminate a host process, suppress generated text, or control commands a human
  runs directly in another terminal.
- **Permissions still matter:** an unattended run cannot click an approval prompt. Configure the
  required host permissions before leaving.
- **First run attended:** use a trusted git repository or a persistent folder (never a disposable
  ChatGPT scratch workspace), observe stop and recovery behavior, and review every local commit or
  artifact receipt before relying on an overnight run.

Continue with the [first-night safety checklist](first-night-checklist.md#first-night-safety-checklist),
[Shift modes](shift-modes.md#shift-modes), the
[owner knobs](knobs.md#owner-knobs), or the [command reference](commands.md#command-reference).

---

[Choose the rules for your project](knobs.md#owner-knobs) · [Documentation index](README.md#documentation)
