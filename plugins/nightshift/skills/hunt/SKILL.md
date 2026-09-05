---
name: hunt
description: Compose a guided or automatic shift from the ready catalog, then review it first or run it directly under one time budget. Use when the owner wants to choose jobs or let Nightshift find the highest-value applicable work.
---

Compose a shift for the host-opened project: settle the work, the ending, and the hours, then
either show it for approval or cut it and start.

Bind once, then never search, guess, or re-resolve. `$TASK_ROOT` is the host-opened project
folder: `${CLAUDE_PROJECT_DIR}` on Claude Code; on Codex the `CODEX_PROJECT_DIR` recovery override
when Nightshift set it, otherwise `pwd -P` captured before any other shell call.
`$NIGHTSHIFT_WORKSPACE` is the validated absolute target of `$TASK_ROOT/.nightshift-link` when that
link exists, otherwise `$TASK_ROOT`. Then `NS="$NIGHTSHIFT_WORKSPACE/.nightshift"` (native Windows:
`$NS = Join-Path $NIGHTSHIFT_WORKSPACE '.nightshift'`), and every Nightshift file is `$NS/<name>`
for the rest of the run; helpers taking `--project` or `-Project` receive
`"$NIGHTSHIFT_WORKSPACE"`. The shell's working directory persists between calls, so a bare path is
never safe.

Resolve `$NIGHTSHIFT_PLUGIN_ROOT` from `${CLAUDE_PLUGIN_ROOT}` on Claude Code, from `$PLUGIN_ROOT`
on Codex, or from the absolute path this skill was attached from (`skills/hunt/SKILL.md`); never
search for the plugin. Read
`$NIGHTSHIFT_PLUGIN_ROOT/skills/nightshift/references/execution-modes.md` before composing: it
carries the state map, who selects work, when the clock starts, direct-mode authority, the tooling
policy, and how several entries become one shift. If `$NS/` does not exist yet, tell the owner to
run Setup, then return.

## 0. Read the sentence first

The owner's sentence is binding intent. There is no keyword list.

A time budget, an actionable objective, and clear direct-execution intent — regardless of
wording — are a complete prompt: compose it and run it. Examples of a complete prompt:
*"use the next 20 hours adding features and enhancing existing ones"*;
*"8 hours clear lint and test debt"*; *"make checkout less ugly, run it"*.

- Complete → Automatic, run directly. Do not offer catalog cards. Do not ask who selects, when to
  start, or "same as last time." Write the shift policy from existing tools, no new elevation, and
  remembered verification, unless the sentence already granted a policy or allowance.
- Incomplete → Ask only a field that is still missing, then continue.
- The owner asked to pick from the menu, or named Guided → section 1.

## 1. Ask who selects

Entries live one per file in `$NIGHTSHIFT_PLUGIN_ROOT/skills/nightshift/references/shifts/`.
**List that directory and read every file in it**. `shift-catalog.md` beside it explains the two
endings and carries the Maintainer night preset; it does not list the entries.
Read the directory rather than reciting from memory: entries are added over time, and a job
that exists in the folder but not in the offer is a job the owner never gets.

Offer two first-class modes when the prompt did not already choose:

- **Guided** — one offer line per entry, with its ending marked, plus one line for any
  preset `shift-catalog.md` names.
- **Automatic** — inspect the work target per `execution-modes.md` (in artifact mode that includes
  `$NS/receipts/`, not a git log) and compose the entries that support the stated objective.
  Quality, coverage, and dependency work do not hijack a feature or design objective. Show evidence
  only in review-first mode; run-direct does not pause.

**More than one may be chosen** — a night can clear the lint backlog and then hunt coverage until
the whistle. Respect every entry's compatibility restrictions when combining; never combine
entries that claim the same single-writer state.

Refuse to compose, cut, or arm when `$NS/receipts` exists but is not a usable directory.
If `$NS/work-mode` is missing and Setup would propose artifact, refuse to compose, cut, or arm and
send the owner to Setup. Do not `git init` a notes folder.
Refuse to compose, cut, or arm when work-mode is malformed.
Refuse to compose, cut, or arm when the work target cannot be resolved.

The GitHub issue-hunt entry is offered with the rest of the catalog. It consumes only
drafting-table entries the Import issues skill created (canonical Source URL and
`Status: proposed`); list them by reading `$NS/drafting-table.md`. Promote a selection by cutting
the item — never a copy — with
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/import-issues.sh" --project "$NIGHTSHIFT_WORKSPACE" --promote …`
(native Windows: `& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\import-issues.ps1" -Project "$NIGHTSHIFT_WORKSPACE" -Promote …`),
or do the cut here when that helper cannot parse the file.
It does not replace defect hunt or product evolution, and never searches or writes back to GitHub.
Never select it when work mode is artifact.

The other repository-shaped jobs are out of scope there too:
Never select defect hunt when work mode is artifact.
Never select documentation drift when work mode is artifact.
Never select TODO and FIXME debt when work mode is artifact.
Never select coverage hunt when work mode is artifact.
Never select tooling quality-debt entries when work mode is artifact.

`runtime/normalize-output.sh` and `runtime/inventory.sh` are read-only reports a shift may
lean on when the host carries them — if present, optional, never required. The first turns a
supported tool format into one compact summary for the receipt and the ledger; the second lists
each workspace package's manager, lockfile, declared scripts, configs, and which named tools are
runnable. Automatic composes and works a shift without either.

## 2. Ask when execution starts

When the prompt did not already carry clear direct-execution intent, ask
**review first, or run directly?** — a choice independent from Guided or Automatic.

- **Review first** — discovery stays read-only and the clock starts only after approval.
- **Run directly** — start the clock once the tooling policy is settled and do not pause after
  discovery, under the direct-mode decision policy in `execution-modes.md`. Review-missing holds
  the clock until that plan is approved.

## 3. Ask the tooling policy and confirm tonight's shift policy

This is composition's one question for tonight's policy — Start never asks it. On a complete
Automatic prompt, skip the question and write the safe defaults from `execution-modes.md`, parking
any elevation gap. **The tooling policy is the owner's standing answer, not a default to re-pick:**
read the resolved value and carry it. Only when the owner has no explicit persistent choice does a
complete prompt run under existing tools. A saved `auto-add` or `review-missing` survives an
objective that says nothing about tooling; a tonight-only `existing-tools` in the prompt overrides
it for that shift alone and changes nothing persistent. Carrying a policy forward grants no new
elevation — an allowance is still the owner's to give. Otherwise ask **before scanning**, and
before any compose, cut, or arm.

Read `$NS/work-mode` and the remembered project default with
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/shift-policy.sh" --project "$NIGHTSHIFT_WORKSPACE" defaults-get`
(native Windows: `& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\shift-policy.ps1" -Project "$NIGHTSHIFT_WORKSPACE" defaults-get`),
and run the permission preflight
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/preflight-needs.sh" --project "$NIGHTSHIFT_WORKSPACE"`
(native Windows: `& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\preflight-needs.ps1" -Project "$NIGHTSHIFT_WORKSPACE"`)
against the entries this compose would select. Ask the single prefilled question in
`execution-modes.md`, folding every capability gap into it, then write the resolved policy with
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/shift-policy.sh" --project "$NIGHTSHIFT_WORKSPACE" set --from-json -`
(native Windows: `-Command set -FromJson -`). Persist a change as the new project default only when
the owner says to remember it (`defaults-set`). In review-first mode that policy is the only file
written before approval; in run-direct mode, arm as soon as it lands.

Artifact mode refuses repository-tool policies (`auto-add`, `review-missing`) and explains why — a
notes folder has no repository toolchain to add. Only existing-tools is valid there; if the
remembered default holds a repository-tool policy, keep existing-tools.

Under auto-add, capture the write surface before writing with
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/provision.sh" --project "$NIGHTSHIFT_WORKSPACE" baseline --surface <rel> [<rel>...]` (one flag takes several paths, or repeat `--surface` per path)
(native Windows: `provision.ps1 -Command baseline -Surface …`), then install, smoke, `diff`, and
`rollback` when smoke or the tooling commit fails.

Then inspect, compose, cut, or arm. Under existing-tools, skip unavailable contracts even when
Guided selected them.

## 4. Establish the ending

Per the entry's declared ending:

- **Open-ended** — hours are REQUIRED. These have no natural end but the clock; a walkthrough may
  not start without a deadline. The entry's declared open-ended title is the source of truth.
- **Finite** — when hours were not already given, ask the ending as an explicit either/or: *until
  every finding is clear, or capped at N hours?* Both are valid; the work ends when the list is
  empty either way, and hours are only a safeguard against a backlog bigger than the night.

One deadline governs the whole shift, and Automatic always requires hours. On a mixed selection say
so in one line: the finite work runs first, and the open-ended job soaks up whatever time is left.

## 5. Ask for guided scope

> Anything specific about scope or approach?

Ask this in Guided mode; in Automatic the owner's sentence is the scope. Free text is skippable and
is where the useful shift is made: *"only `packages/api/`"*, *"use `getTestInstance()` from the
test package"*, *"one module — this becomes a single reviewable PR"*.
If a selected entry declares Owner instructions required, it is not skippable: ask, and refuse to
compose, cut, or arm that entry until the owner supplies a non-empty answer. Those entries are
Guided-only and are never selected in Automatic mode. Never edit the entry's own contract to fit
it; the owner's words become their own sub-bullet:

```text
 - **Owner instructions:** <verbatim, as written>
```

The entry's rules stay above it untouched. They enforce the shift contract — assert behaviour
rather than counts, gate green at every commit or artifact receipt, never silence instead of
fixing — and owner text adds constraints rather than replacing them.

## 6. Review or cut

In **review first**, print the items exactly as they will be written, with evidence, order, hours,
and ending, then ask for one approval. The preview is model prose: a no-write, no-clock simulation
of the resolved workspace and work target, the shift policy, why each entry serves the stated
objective, overlaps removed, rejected alternatives, and the stopping rule.
This is the last look before anything is armed. Write nothing before approval.

In **run directly**, do not ask again: write the order and immediately cut it into the active
shift. Record significant discovery and selection decisions in `$NS/parking-lot.md`.

On approval, append to `$NS/work-orders.md` — hunt's own file; the drafting table stays the
owner's room. Never clobber orders already sitting there — append below them:

```text
## Work order — <ISO date time>
Hours: <N, or "none — finite">

- [ ] **<entry item, verbatim>**
 - **Owner instructions:** <if any>
```

The hours are inert while a review-first order sits here — the clock starts only at the cut, after
approval. In run-direct mode the order is cut immediately, so its clock starts now.

## 7. Start or park after review

After review-first approval, ask **start now, or park it for later?** Run-direct skips this
question and always starts now; choosing it was already explicit authorization.

On **now** — start the shift yourself, here, without making the owner type another command. Follow
the Start skill exactly, including its whole preflight and the unsupported-permission report
described in `execution-modes.md`. Then clear the stale markers and
**cut** the whole `## Work order` section out of `$NS/work-orders.md` (heading, hours, and item —
do not leave an empty order heading behind), put only the item under `## Items` in the punch list
(a cut, never a copy — it must not exist in two places), and:

- write `$NS/deadline` as a UNIX epoch from the recorded hours — `date +%s` plus hours*3600 on
  POSIX, or `Get-NSUnixTime` plus hours*3600 after
  `Import-Module "$NIGHTSHIFT_PLUGIN_ROOT\lib\Nightshift.psm1" -Force` on native Windows;
- **arm the gate** with `touch "$NS/.shift-armed"` on POSIX, or
  `New-Item -ItemType File -Force "$NS\.shift-armed"` in native Windows PowerShell;
- log the start and run the binding probe (`: nightshift-binding-probe` on POSIX,
  `$null = 'nightshift-binding-probe'` on native Windows);
- classify Codex `$NS/.shift-session` line 1 with `ns_codex_identity_kind` from
  `$NIGHTSHIFT_PLUGIN_ROOT/lib/lib.sh` (native Windows: `Get-NSCodexIdentityKind` after importing
  `Nightshift.psm1`) before arming the watchman or beginning item work;
- **arm the watchman** as the Start skill requires: Claude Code uses
  `$NIGHTSHIFT_PLUGIN_ROOT/runtime/claude/watchman.sh`, Codex
  `$NIGHTSHIFT_PLUGIN_ROOT/runtime/codex/watchman.sh`, Cursor
  `$NIGHTSHIFT_PLUGIN_ROOT/runtime/cursor/watchman.sh`, and native Windows
  `& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\start-watchman.ps1"`
  `-Project "$NIGHTSHIFT_WORKSPACE" -HostName claude` (Codex: `-HostName codex`; Cursor:
  `-HostName cursor`).

An empty `## Items` section still keeps the Shift contract and Gates; they bind the cut item.
Record leftover campaign rules in `$NS/parking-lot.md` when they are not this order's.

On **later** — the order stays parked in `$NS/work-orders.md` with its hours, costing nothing. It
arms nothing and the gate stays inert. Start (`/nightshift:start` on Claude Code, or ask Nightshift
to start on Codex) will offer it when the owner is ready.
