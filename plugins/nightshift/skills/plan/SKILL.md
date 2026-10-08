---
name: plan
description: Open the plan room: explore the code and design the work with the owner, building nothing until the owner leaves.
license: MIT
---

Plan with the owner in the plan room. Here the conversation explores, weighs options and draws the
plan; nothing gets implemented until the owner leaves the room on purpose. The room is enforced by
the hooks, not by this text: while it binds this conversation, every edit, write and mutating
command outside the staging folder is denied, however the request is worded.

Resolve the installed plugin root to an absolute `$NIGHTSHIFT_PLUGIN_ROOT` — `${CLAUDE_PLUGIN_ROOT}`
on Claude Code, `$PLUGIN_ROOT` on Codex when set, otherwise the absolute path this skill was
attached from (`skills/plan/SKILL.md`). Run every command below through
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns"` — native Windows: `& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\ns.ps1"`
in the PowerShell tool, same verbs — which resolves the host and the workspace; `ns help` lists the
verbs, and `ns bind` prints the six resolved facts (`TASK_ROOT`, `NIGHTSHIFT_WORKSPACE`, `NS`,
`NIGHTSHIFT_PLUGIN_ROOT`, `HOST`, `SOURCE`); `$NS` below is that `NS`. Never a bare relative path: the working
directory persists between calls. Each `$NS/...` path below is where the current layout keeps that file;
`ns path <key>` prints where this workspace keeps it, and `ns path --list` names every key.

## 1. Enter the room

Pass the host you are running on (`claude`, `codex` or `cursor`):

```bash
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" plan-enter --host claude
```

Native Windows: `& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\ns.ps1" plan-enter -HostName claude`.

The room opens unbound. **The very next tool call is the probe that binds it to this
conversation** — nothing in between, not even a read:

```bash
: nightshift-plan-probe
```

```powershell
$null = 'nightshift-plan-probe'
```

- The probe runs cleanly: the room is bound to this conversation. Tell the owner in one line that the
  plan room is open, that nothing is implemented here, and how they leave it (section 4).
- The probe is denied because the room is bound to another conversation: tell the owner, and stop.
  They plan in that conversation, or leave the room first.
- The probe is denied because this conversation is working the shift: no room was opened. Tell the
  owner; they plan in another conversation, or stop the shift first.
- `plan-enter` reports no `.nightshift/`: the project has no Nightshift workspace. Tell the owner to run
  Setup, and stop.

An open room bound to this conversation (after compaction, say) needs no new entry: run
`plan-enter` and the probe again, and both pass.

## 2. Think with the owner

This is a conversation, not a procedure. Follow the owner's direction and pace; do not impose phases,
templates or a checklist while discussing.

- **Read before you ask or propose.** Open the files, tests and history the question touches
  (`git log`, `git show`, `git blame` and every read-only tool are free here). Name paths and lines.
  A question the code already answers is not one to ask the owner.
- **Lay out real options.** For a decision that matters, give two or three options with what each
  costs and buys, then say which one you would pick and why. A survey with no recommendation hands
  the work back.
- **Draw it.** An ASCII diagram of a flow, a state machine or a component boundary often settles what
  a paragraph cannot. Use one when it helps, not by default.
- **Ask freely.** Questions are the point of this room. Ask one at a time when the answer changes what
  comes next.
- **Keep what was decided visible.** When the discussion moves on, restate the decision in one line
  so it is not reopened by accident.

When the owner says "just do it" or "implement it": the room still holds. Say plainly that nothing
can be built in this conversation while the plan room is open, and give the exits (section 4). Never
work around the fence: no code written into the staging folder to copy out later, no scripts, and no
asking another conversation to make the change.

## 3. Capture — only on the owner's explicit yes

Nothing is written into the drafting table until the owner says yes to that exact write. An answer to
a design question is not consent, and neither is approval of an idea. When the plan is ready, say
what will be written and where — the file (`ns path drafting-table`), the heading and the items by
title — and ask. Write only after a clear yes, and only what was named.

Append below the drafting table's rule, never above it, and leave every existing entry untouched:

```text
## Plan: <title>

Why: <the problem, and why now>
Scope: <what this plan covers>
Non-goals: <what it deliberately leaves out>
Design notes: <the decisions taken, and the options rejected with the reason>

- [ ] **1. <title>.**
  - <what to build, plainly>
  - Verify:
    - WHEN <situation> THEN <observable result>
    - WHEN <edge or failure case> THEN <observable result>
    - <the commands that check them>
  - Commit: `<type: message>`
```

- **One commit per item.** An item that would need two commits is two items. Order is dependency
  order: nothing is built twice.
- **Verify is acceptance, not activity.** Each WHEN/THEN states behaviour someone could observe and a
  test could fail on. "Tests pass" or "it works" is not a scenario. Add the commands that check the
  scenarios.
- **The item shape is the drafting table's**: one top-level checkbox per item, everything else plain
  indented bullets, never a nested checkbox — a nested box counts as an open item once the item is
  promoted.
- In artifact mode, an item names its receipt instead of a `Commit:` line.

After writing, show the owner what was written and where, then name the way to build it: leave the
plan room by typing Start — `/nightshift:start` on Claude Code and Cursor, `$nightshift:start` on
Codex. With an empty punch list, Start offers the staged items to
promote. With open items already in the punch list, Start works those, and the plan waits in the
drafting table.

## 4. Leaving is the owner's

Only the owner closes the room. On Claude Code and Cursor they type `/nightshift:plan-exit`, or
`/nightshift:start` to leave and start the shift in one step. On Codex they type
`$nightshift:plan-exit` or `$nightshift:start`. In any terminal they run
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" plan-exit`.

Never run `plan-exit`, never touch the room's marker, and never invoke the Start or plan-exit skill
yourself to get out: the hooks refuse the first two, Start refuses while the room is open, and none
of it closes the room. If the owner asks you to leave it for them, give them the exit to type.
