---
name: status
description: Read-only shift status — open vs ticked items, parked decisions, snag-log summary, deadline remaining, and any STOP/stall state. Starts no work.
---

Report the shift status for the host-opened project **without starting or changing anything** —
this is read-only. Modify no file, begin no work.

Resolve the installed plugin root to an absolute `$NIGHTSHIFT_PLUGIN_ROOT` — `${CLAUDE_PLUGIN_ROOT}`
on Claude Code, `$PLUGIN_ROOT` on Codex when set, otherwise the absolute path this skill was
attached from (`skills/status/SKILL.md`) — and run every command below through `runtime/ns`,
which resolves the host, the workspace and any `.nightshift-link` itself. Never search for the
plugin, and never use a bare relative path: the shell's working directory persists between calls.

`ns bind` prints the five facts those commands are built on — `TASK_ROOT`, `NIGHTSHIFT_WORKSPACE`,
`NS`, `NIGHTSHIFT_PLUGIN_ROOT` and `HOST` — for a read of your own. Status needs none of them: every
fact it reports is printed for it.

On native Windows the same verbs run through `& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\ns.ps1"`,
with the same flags. Use the PowerShell tool and native paths; do not route Status through WSL
or Git Bash. `ns help` lists the verbs this host has.

## 1. Run the two read-only inspectors

```bash
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" status
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" doctor
```

`ns status` prints every fact: workspace, schema, armed or not, item counts and the current open
item, parked entries, staged drafts and Hunt orders, recent snag dispositions, opportunity counts
and any building entry, deadline remaining, `STOP`, stall attempts, session, lease, watch reason,
work mode and target, artifact receipts, and recent transitions. `ns doctor` adds the checks Status
cannot make safely on its own — process liveness, the lease lines, and every Warning about a path
that is not a usable file.

## 2. Render, never re-derive

Every number and every name above is already computed. Do not count boxes, subtract a deadline from
the clock, read a marker, or work out what a state means: the fact lines carry their own meaning
where there is one to carry.

Do not reimplement liveness, do not read the runtime-owned lease file directly, and never re-derive
policy precedence. The inspectors validate through the shared library, classify the recorded pid
and the watchman pid themselves, and never print a session id, a session scope, or an ownership
capability.

Write a compact, glanceable summary in plain language. Lead with what matters tonight — that is
your judgement, and the only judgement this skill asks for. What the facts say is not.

**Relay every Warning either inspector prints.** Each one is a real finding: a planted symlink
where a marker should be is not an empty night, a malformed work mode is not a working site, and a
failed clock-out is not a finished shift. Say what it means for the owner and name the confirm
action the inspector offers. Never soften a warning into silence.

Do not print a project tool's raw output, credentials, raw evidence, a session id, or a transcript
path. The inspectors do not emit them; do not go looking.

The project inventory is a separate optional report the owner asks for by name:
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" inventory`. Status never prints it unasked — a table of
packages is not a glance.
