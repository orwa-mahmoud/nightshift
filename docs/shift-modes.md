# Shift modes

Hunt and Quality share two independent choices: who selects the work, and when the clock starts.
The contract is in [selection and launch modes](../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md).
This page is one copyable walkthrough per combination. Setup must already have been run in the
project you want changed — a Git repository or a persistent folder, never a ChatGPT scratch
workspace.

A third independent choice is the tooling policy, asked before scanning: **Existing tools only**,
**Review missing tools first**, or **Automatically add standard development tools**. Artifact mode
keeps Existing tools only. Details live in the same modes contract.

Morning review is local: work-target commits in repository mode, or files under
`.nightshift/receipts/` in artifact mode (Doctor names the most recently written filename).
Doctor warns `artifact receipts path is not a usable directory` when that path exists but is not a usable directory. Start, Hunt, Quality, and Schedule refuse when that path is unusable rather than begin a notes-folder night that cannot land receipts.
Archive copies those files with `ns archive-receipts` (native Windows: `ns.ps1 archive-receipts`)
into the dated folder and leaves the live copies in place. Missing or empty receipts create no dated receipts folder. Status, the shift
log, and the parking lot sit beside those. Ticks are self-reported; they do not prove the work.

## Guided + Review first

Owner-selected catalog entries. Discovery stays read-only. Nothing is armed until you approve.

Claude Code: `/nightshift:hunt`, then **Guided**, pick the entries, then **Review first**.

Codex: ask **“Hunt Guided, documentation writing, review first.”** Name the catalog entries you
want.

The assembled order is shown before any punch-list cut. The clock starts only after approval.
Park it instead if the order is wrong.

## Guided + Run directly

Owner-selected catalog entries. Discovery, cut, and arm happen without a second pause.

Claude Code: `/nightshift:hunt`, then **Guided**, pick the entries, then **Run directly**.

Codex: ask **“Hunt Guided, documentation writing, run directly.”**

The clock starts immediately. Significant decisions go to the parking lot with a default; they
are not questions.

## Automatic + Review first

Your sentence is the objective. Nightshift reads every catalog entry, inspects the work target,
and composes the entries that serve what you asked for — quality, coverage, or dependency work
does not hijack a feature or design objective because fingerprints were easy to find. Hours are
required. Discovery stays read-only until you approve.

Claude Code: `/nightshift:hunt`, then **Automatic**, set the hours, then **Review first**.

Codex: ask **“Hunt Automatic for four hours, review first.”**

In artifact mode the scan uses the folder's files and manifests; it does not require git history.
Quality-debt entries are skipped when the folder has no tests, tooling, or manifests to inspect.
The GitHub issue hunt is skipped in artifact mode.
The defect hunt is skipped in artifact mode.
Documentation drift is skipped in artifact mode.
TODO and FIXME debt is skipped in artifact mode.
Coverage hunt is skipped in artifact mode.
Tooling quality-debt entries are skipped in artifact mode.
The clock starts only after approval.

## Automatic + Run directly

The same composition, with immediate authority to cut and arm. Hours are required. A request that
already carries a time budget, an actionable objective, and clear direct-execution intent runs here
without another question.

Claude Code: `/nightshift:hunt`, then **Automatic**, set the hours, then **Run directly**.

Codex: ask **“Hunt Automatic for four hours, run directly.”**

The clock starts immediately. Nightshift keeps selecting applicable work until quitting time or
the finite list is clear.

Quality uses the same four combinations. Review-first Quality may **fix now** (cut a Hunt work
order), **draft for later**, or **ignore**. See the [command reference](commands.md).

Continue with the [first-night safety checklist](first-night-checklist.md) before leaving a run
unattended.
