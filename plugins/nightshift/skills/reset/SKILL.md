---
name: reset
description: Abandon current Nightshift runtime mechanics without deleting the owner's work or evidence.
---

Reset runtime mechanics for the host-opened project. This recovers from damaged or confusing
runtime state. It does not delete the punch list, rules, history, or `.nightshift/` itself.

Resolve the installed plugin root to an absolute `$NIGHTSHIFT_PLUGIN_ROOT` — `${CLAUDE_PLUGIN_ROOT}`
on Claude Code, `$PLUGIN_ROOT` on Codex when set, otherwise the absolute path this skill was
attached from (`skills/reset/SKILL.md`) — and run every command below through `runtime/ns`,
which resolves the host, the workspace and any `.nightshift-link` itself. Never search for the
plugin, and never use a bare relative path: the shell's working directory persists between calls.

`ns bind` prints the five facts those commands are built on — `TASK_ROOT`, `NIGHTSHIFT_WORKSPACE`,
`NS`, `NIGHTSHIFT_PLUGIN_ROOT` and `HOST` — for a read or write of your own. `$NS/<name>` below is
that `NS`; owner-facing prose may use the short names (`punch-list.md`, `parking-lot.md`, `STOP`).

On native Windows the same verbs run through `& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\ns.ps1"`,
with the same flags. Use the PowerShell tool and native paths; do not route Reset through WSL
or Git Bash. `ns help` lists the verbs this host has.

Run the trusted helper. Do not delete runtime files by hand:

```bash
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" reset-shift
```

The helper first performs Stop (pause and disarm), then removes the current deadline, leftover
`STOP`, and temporary session, recovery, watchman, lease, and mutex markers. It preserves the punch
list and unfinished items, rules, parking lot, work orders, receipts, archives, research,
opportunities, snag log, shift log, and workspace configuration such as work-target and work-mode.
A second Reset is safe. It never deletes `.nightshift/`.

Report that the deadline was removed and that durable files remain. The plugin install is
untouched. Start after Reset writes a new deadline only when Hunt, a work order, or the owner
supplies one — it does not invent a time budget.
