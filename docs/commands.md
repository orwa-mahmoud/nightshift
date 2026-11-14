# Command reference

Choose work with [Shift modes](shift-modes.md#shift-modes), inspect [receipts and token usage](receipts.md#receipts-and-token-usage),
or [archive finished shifts](archive.md#archive-and-continue). The commands below operate those workflows.

| Command | What it does |
| --- | --- |
| **Set up and plan** | |
| `/nightshift:setup` | Asks at most four questions: the gates, then every default on one screen. |
| `/nightshift:plan` | Opens the plan room: explore and design with the agent; nothing is built. |
| `/nightshift:plan-exit` | Leaves the plan room. `/nightshift:start` leaves and starts in one step. |
| `/nightshift:import-issues` | Stages explicitly named GitHub issues onto the drafting table. |
| `/nightshift:customize` | Shows every setting, template and catalog entry on one screen, and changes what you name. |
| **Choose and run the work** | |
| `/nightshift:start` | Works the queued items without questions; offers drafts only when the list is empty. |
| `/nightshift:hunt` | Composes tonight's shift: pick ready-made shifts, set the hours, add your scope. |
| `/nightshift:quality` | Surveys quality debt; you choose review first or run directly. |
| **While it runs** | |
| `/nightshift:status` | What got done, what got parked, and what got stuck. |
| `/nightshift:doctor` | Diagnoses the workspace: facts, warnings and next actions. Never repairs. Can export a local support bundle, never uploaded. |
| `/nightshift:stop` | Pauses now. Open boxes stay open and the deadline is kept. |
| **After the shift** | |
| `/nightshift:archive` | Files the shift into its own folder, `.nightshift/archive/<YYYY-MM-DD>/` by default, laid out like the live site. Open work and the contract stay live. |
| `/nightshift:reset` | Drops the runtime markers and the deadline; keeps the punch list and history. |
| `/nightshift:purge` | Deletes this project's `.nightshift/`. Does not uninstall the plugin. |

You can also write items in the punch list by hand, one checkbox per task;
[the example punch list](../examples/overnight-webapp.md) shows the anatomy with filled items. You
review the local commits or artifact receipts yourself: push only in repository mode, or forbid
pushing outright with `NIGHTSHIFT_FORBIDDEN_COMMANDS` set to `git .*push` ([tool rules](knobs.md#tool-rules)).

## Start

With work in the punch list, `/nightshift:start` asks nothing and works it. With an empty list, it
offers your staged drafts for approval. Before it arms, it runs a preflight that prints one `ok`,
`warn` or `refuse` line per check, and it refuses to arm when something would stall the shift.

[Setup](setup.md#setup) explains Setup's questions, [Shift modes](shift-modes.md#shift-modes) gives
copyable Hunt and Quality requests, and [The plan room](plan-room.md#the-plan-room) covers planning.

## Terminal controls

These run from any terminal, with no model and no tokens, in the folder that holds `.nightshift/`
(or pass `--project <path>`). Below, `ns` is `"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns"`; on native
Windows, `ns.ps1` takes the same verbs.

| Command | What it does |
| --- | --- |
| `ns stop-shift` | Pauses the shift now, even if the agent is stuck. Open items and the deadline are kept. |
| `ns reset-shift` | Drops the runtime markers, the deadline and a leftover STOP. Keeps the punch list, the history, and what open items have already spent. |
| `ns purge-workspace --confirm-path <path to .nightshift>` | Resets, then deletes this project's `.nightshift/`. Does not uninstall the plugin. |
| `ns plan-new --name <name>` | Starts a plan file from the punch list's contract and checks. Keeps a plan that already has the name. |
| `ns plan-exit` | Leaves the plan room. |
| `ns start-preflight` | Prints the checks Start runs before it arms. |
| `ns shift-estimate --items 5` | Estimates time and tokens per item from your past receipts, with a suggested deadline and budget. Needs at least three readings. |
| `ns check-items` | Names drafted items with a missing `Verify:` or `Commit:`, an `Evidence:` that names nothing, or a `Budget:` that does not parse. Refuses nothing. |
| `ns link-workspace --host-root <path> --workspace <path>` | Points a task folder at the workspace that already holds `.nightshift/`. |
| `ns export-support` | Writes a local support bundle, with known sensitive fields left out. Never uploaded. |
| `ns archive-receipts` | Files a finished shift's receipts into its archive folder. |
| `ns check-report --report <file> --manifest <file>` | Checks a cited research report against its source manifest. |

`touch .nightshift/STOP` also stops the shift, at the agent's next stop. Write it where
`.nightshift/` is, not beside a `.nightshift-link`. When a stopped shift left an expired deadline,
Start will not invent a new one: run Reset, then Start.

When a shift is not where you expect, run `/nightshift:doctor`, then follow
[Troubleshooting](troubleshooting.md#troubleshooting). Doctor reports; it never repairs.

## Permissions

An unattended shift cannot click Allow, so set the host's permissions before you start. Setup never
changes them, and recovery never adds bypass flags: `recovery.launchScope` decides whether a revived
session uses your host's defaults or a recorded Codex sandbox. Nightshift's guards stay active
within whatever the host allows.

On Codex, unattended execution is `-a never` and the sandbox is a separate choice. A contract
that does not commit runs under `-s workspace-write`, because ticks alone finish a night. Under
Codex's `workspace-write` sandbox `.git` is protected, so a contract that commits cannot run under
it and needs `codex -a never -s danger-full-access`. The owner-defined Nightshift guards remain
active in either sandbox mode.

## Start at a fixed time

```text
/nightshift:schedule
```

It checks the things that would otherwise surprise you at 4am — that work is actually queued in the
punch list, that permissions won't stall a headless run, that nothing is registered twice — then
prints the launchd plist (macOS), crontab or systemd entry (Linux), or Task Scheduler XML (native
Windows) for this project and the one command that installs it. **It registers nothing itself.**

Two things it will tell you, worth knowing in advance: **the items must be in the punch list before
the scheduled time**, because a start works the list it finds and promotes nothing; and **a sleeping
machine runs nothing** — launchd defers a missed job to the next wake, cron loses it, and only
`pmset repeat wakeorpoweron` makes a Mac wake for it.

### When you have no credit left

The moment you most want to schedule a run is often the moment your quota is gone — and then no
slash command works, because a command is read by the model. The generator underneath is plain
shell that spends no tokens and needs no session:

| Command (`ns` is `"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns"`) | What it does |
| --- | --- |
| `ns schedule --preflight` | Checks both hosts. Writes nothing. |
| `ns schedule --at 04:05` | Prints the config and the command that installs it. |
| `ns schedule --at 04:05 --agent 'codex exec -s danger-full-access'` | The same entry, run by Codex instead of Claude. |
| `ns schedule --at 04:05 --target systemd` | Prints a user `.service` and `.timer`. Never runs `systemctl`. |
| `ns schedule --list` | Shows what is already registered for this project. |
| `ns schedule --remove` | Prints the command that unregisters it. |

Run it from a terminal with `NIGHTSHIFT_PLUGIN_ROOT` set to the absolute installed plugin directory.
Keep the bundled runtime and libraries together. It refuses a second entry for a project
that already has one, and identifies projects by path rather than folder name, so two checkouts
called `api` never collide. It cannot queue your work for you, though — that part has to be in the
punch list already. Preflight also fails when the work mode is unset or the work target cannot be
read, because a scheduled start would refuse to arm.

Native Windows uses the token-free PowerShell generator:

```powershell
ns.ps1 schedule --project . --preflight
ns.ps1 schedule --project . --at 04:05
ns.ps1 schedule --project . --at 04:05 `
  -Agent 'codex exec -s danger-full-access'
ns.ps1 schedule --project . --list
ns.ps1 schedule --project . --remove
```

It emits a current-user Task Scheduler definition with overlap prevention and `StartWhenAvailable`.
It does not wake the machine or run after logout as a stored-credential account; see
[Native Windows](windows.md#native-windows).

`/nightshift:nightshift` is the method itself: how to work an item, park a decision, keep a snag
log, and run product evolution. The agent loads it whenever a shift is running, so you rarely run it
yourself.

---

[Troubleshoot a stopped or refused shift](troubleshooting.md#troubleshooting) · [Documentation index](README.md#documentation)
