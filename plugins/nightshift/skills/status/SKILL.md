---
name: status
description: Read-only shift status — open vs ticked items, parked decisions, snag-log summary, deadline remaining, and any STOP/stall state. Starts no work.
---

Report the shift status for the host-opened project **without starting or changing anything** —
this is read-only.

**State map:** `punch-list.md` → owner-approved work active in this shift;
`drafting-table.md` → known work staged for a later shift; `parking-lot.md` → unresolved owner
decisions plus the default chosen so work continues; `work-orders.md` → timed catalog work composed
only through Hunt. Report these as different categories; do not merge or move them.

Resolve the installed plugin root to an absolute `$NIGHTSHIFT_PLUGIN_ROOT` — `${CLAUDE_PLUGIN_ROOT}`
on Claude Code, `$PLUGIN_ROOT` on Codex when set, otherwise the absolute path this skill was
attached from (`skills/status/SKILL.md`) — and run every command below through `runtime/ns`,
which resolves the host, the workspace and any `.nightshift-link` itself. Never search for the
plugin, and never use a bare relative path: the shell's working directory persists between calls.

`ns bind` prints the five facts those commands are built on — `TASK_ROOT`, `NIGHTSHIFT_WORKSPACE`,
`NS`, `NIGHTSHIFT_PLUGIN_ROOT` and `HOST` — for a read or write of your own. `$NS/<name>` below is
that `NS`; owner-facing prose may use the short names (`punch-list.md`, `parking-lot.md`, `STOP`).

On native Windows the same verbs run through `& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\ns.ps1"`,
with the same flags. Use the PowerShell tool and native paths; do not route Status through WSL
or Git Bash. `ns help` lists the verbs this host has.

## 1. Run the two read-only helpers

```bash
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" status
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" doctor
```

`ns status` gives the glanceable summary: workspace, armed or not, item counts, evidence counts,
resolved policy, preflight gaps, and the separate `liveness`, `last activity`, `last checkpoint`
and `stall attempts` lines. `ns doctor` supplies what Status cannot see safely on its own —
`recorded pid` and `watchman pid` liveness, the process-lease lines, work mode and work target, the
deadline reading, and every Warning about a path that is not a usable file. Do not
reimplement liveness, do not read the runtime-owned lease file directly, and never re-derive
policy precedence: the inspectors validate with the shared library and never print a session id, a
session scope, or an ownership capability.

**Relay every Warning either helper prints.** They are already plain English and each one is a
real finding — a planted symlink where a marker should be is not an empty night, a malformed work
mode is not a working site, and a failed clock-out is not a finished shift. Say what each warning
means for the owner and name the confirm action the helper offers. Never soften one into silence,
and never re-derive the state behind it.

## 2. Read the files the inspectors do not fold in

- **Schema** — `$NS/state-version`: missing means legacy `0`, `1` is current. Report a newer or
  malformed marker and stop there; never rewrite it and never run migration from status.
- **Shift** — whether one is running: `$NS/.shift-armed` exists. Without it the punch list is a
  to-do file and nothing is holding it, however many boxes are open — say so plainly and name Start
  as what begins the shift (`/nightshift:start` on Claude Code, or ask Nightshift to start on
  Codex).
- **Items** — ticked vs open counts from `$NS/punch-list.md`, counted **below the `## Items`
  heading only** (open = lines matching a dash + bracketed space; ticked = bracketed x), and the
  title of the current open item. A checkbox above that heading is contract prose, not work, and
  the gate does not count it either. When no open boxes remain, say plainly that the leftover
  Shift contract and Gates still bind the next Hunt or Start cut — Archive files ticked items and
  never resets those sections. If ticked items are still in the list, name Archive.
- **Parked** — the count and one-line titles of entries in `$NS/parking-lot.md`.
- **Staged** — known later items in `$NS/drafting-table.md`, separately from pending timed Hunt
  orders in `$NS/work-orders.md`. Count drafting-table boxes only after the first markdown `---`
  rule so the fenced item-shape example is not a staged draft. Count open `- [ ]` boxes in
  `work-orders.md` as parked Hunt orders. If either count is non-zero and the punch list is empty,
  say Start will offer them. **With any open item under `## Items`, both counts are informational
  and nothing else:** Start works the punch list exactly as the owner left it, and drafts and Hunt
  orders stay where they are. Never offer to promote, and never present staged work as the next
  action while approved work is open.
- **Snag log** — the last few dispositions from `$NS/snag-log.md`, if any.
- **Product evolution** — when `$NS/product-research.md` or `$NS/opportunity-map.md` contains more
  than its template headings, report the most recent research entry and the counts of candidate,
  building, shipped, rejected, and parked opportunities. If one opportunity is building, show its
  title, current phase, exact Next action, and Verify remaining. Flag multiple building entries as
  inconsistent without changing them. Do not turn the map into work or change a status.
- **Deadline** — the time remaining until quitting time from Doctor's deadline fact (`$NS/deadline`
  holds a UNIX epoch; compare with `date +%s` on POSIX, or `Get-NSUnixTime` after
  `Import-Module "$NIGHTSHIFT_PLUGIN_ROOT\lib\Nightshift.psm1" -Force` on native Windows).
  Otherwise "no deadline (finite list)".
- **State** — whether `$NS/STOP` is present (and its reason), and the current `$NS/.stall` attempt
  count if any. If `$NS/STOP` is present and the shift is unarmed, the run is paused: Start resumes
  it, Reset drops the deadline, and Purge deletes project Nightshift state. None of those uninstall
  the plugin. If a shift is running, name the bound session from `$NS/.shift-session` without
  printing the session id, and report `$NS/.shift-lease` as absent, malformed, interactive, or
  recovered from Doctor's lease lines.
- **Watchman** — if `$NS/.watch-reason` exists, print line 1 (the stable code) and the same human
  label Doctor prints (`ns_reason_label` in the shared library; on native Windows,
  `Get-NSReasonLabel` after the same module import). Do not print transcript paths, session ids,
  prompts, or any other payload. Line 2 is optional non-sensitive detail only.
- **Work mode** — report Doctor's `work mode` and `work target` facts. When it warns
  `work mode is unset; Setup would propose artifact`, say so and name the confirm action to
  persist the proposed artifact mode with Setup. When it warns
  `work mode is malformed; treating the site as unusable until Setup rewrites it`, or
  `work target could not be resolved; treating workspace as the code root`, say that too. Artifact
  mode is a persistent folder, not a Git repository.
- **Artifact mode** — report Doctor's `artifact receipts N` fact and, when it prints one, the
  `latest artifact receipt` — the most recently written receipt file. Completion there is
  `$NS/receipts/`, not a git log; do not invent one. When Doctor warns
  `artifact mode has ticked items but no receipts`, say so: ticked boxes without a receipt are not
  reviewable completion. When it warns
  `artifact receipts path is not a usable directory`, say so and name its confirm action — a
  planted file or symlink is not an empty night, so do not also report empty ticks for it.
  Dated copies from Archive live under `$NS/archive/<YYYY-MM-DD>/receipts/`
  and do not replace the live files Status reports.
  Missing or empty receipts create no dated receipts folder.
- **Transition history** — when `$NS/shift-log.md` records stand-down, revival, or host changes,
  summarize those lines in the skill (compact, no secrets). Multi-night campaigns are independent
  bounded shifts; the next night begins only after the prior archives or the owner accepts the
  handoff recorded in the log.

Do not print a project tool's raw output, credentials, raw evidence, or rule values.

Keep it a compact glanceable summary. Do not modify any file, do not begin work.

The project inventory is a separate optional report the owner can ask for by name:
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" inventory`. Status never prints it
unasked — a table of packages is not a glance.
