---
name: purge
description: Permanently delete this project's Nightshift state. Does not uninstall the plugin.
---

Remove Nightshift from this project. This deletes punch lists, rules, receipts, archives, and
history under the project's `.nightshift/` directory. It does not uninstall the global Nightshift
plugin.

Resolve the installed plugin root to an absolute `$NIGHTSHIFT_PLUGIN_ROOT` — `${CLAUDE_PLUGIN_ROOT}`
on Claude Code, `$PLUGIN_ROOT` on Codex when set, otherwise the absolute path this skill was
attached from (`skills/purge/SKILL.md`) — and run every command below through `runtime/ns`,
which resolves the host, the workspace and any `.nightshift-link` itself. Never search for the
plugin, and never use a bare relative path: the shell's working directory persists between calls.

`ns bind` prints the five facts those commands are built on — `TASK_ROOT`, `NIGHTSHIFT_WORKSPACE`,
`NS`, `NIGHTSHIFT_PLUGIN_ROOT` and `HOST` — for a read or write of your own. `$NS/<name>` below is
that `NS`; owner-facing prose may use the short names (`punch-list.md`, `parking-lot.md`, `STOP`).

On native Windows the same verbs run through `& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\ns.ps1"`,
with the same flags. Use the PowerShell tool and native paths; do not route Purge through WSL
or Git Bash. `ns help` lists the verbs this host has.

Print the exact canonical `$NS` path. Warn that punch lists, rules, receipts, archives, and history
will be lost, and that the plugin itself stays installed. Do not run the helper until the owner
confirms that exact path. Then:

```bash
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" purge-workspace \
  --confirm-path "$NS"
```

The helper first performs Reset, then deletes only that validated `.nightshift/` directory and a
local `.nightshift-link` on the opened task root when present. It refuses symlinks, malformed
links, workspace roots, home directories, `/`, and other broad paths. It never deletes repository
files outside that Nightshift state. A second Purge with the same confirmation is safe.

If the task root is linked, pass the folder you opened as `--project "$TASK_ROOT"`. This is the
one command whose target is the task root rather than the workspace, so it is the one place the
dispatcher's answer is not the one you want: purging only the workspace path leaves the host link
in place.
