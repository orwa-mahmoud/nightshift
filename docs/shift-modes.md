# Shift modes

Already have an approved task list? Put it under `## Items` in the punch list and Start works it.
Use Hunt when you want help choosing or composing the work. Use Quality when the objective is
project quality debt. Run Setup first in the Git repository or persistent folder you want changed.

## Choose the right starting point

| Your situation | Start here |
| --- | --- |
| You know exactly what should change | Write bounded items and use Start. |
| You want a particular kind of work, such as coverage or documentation | Hunt, Guided selection. |
| You have a goal and hours to spend, but no prepared backlog | Hunt, Automatic selection. |
| You want to survey and address quality debt | Quality. |
| You have specific GitHub issues to work | Import issues, review the drafts, then promote approved items. |

Hunt composes from the [ready-shift catalog](../plugins/nightshift/skills/nightshift/references/compose/shifts/).
Each entry describes its scope, discovery, verification, and ending. You can adapt its punch-list
example yourself or let Hunt assemble it. Import issues accepts explicit URLs or `owner/repo`
plus issue numbers; it never searches GitHub or writes back.

## Ready-made shifts

The catalog ships these entries. Pick them yourself with Hunt's Guided selection, or give Hunt a goal
and hours and it chooses. Your own entries sit beside them, and one with the same key replaces the
shipped entry.

**Open-ended:** they work in complete units until quitting time, or, for a defect hunt, until a full
pass finds nothing new.

| Shift | What it works on |
| --- | --- |
| [Coverage hunt](../plugins/nightshift/skills/nightshift/references/compose/shifts/coverage-hunt.md) | Give it the night, wake up to tests |
| [Defect hunt](../plugins/nightshift/skills/nightshift/references/compose/shifts/defect-hunt.md) | The review cycle, ridden to convergence |
| [Owner walkthrough](../plugins/nightshift/skills/nightshift/references/compose/shifts/owner-walkthrough.md) | Pursue one owner-supplied objective until quitting time |
| [Product evolution](../plugins/nightshift/skills/nightshift/references/compose/shifts/standing-loop.md) | Research the space and improve until quitting time |

**Finite:** they end when the work they discover is done.

| Shift | What it works on |
| --- | --- |
| [Accessibility repair](../plugins/nightshift/skills/nightshift/references/compose/shifts/accessibility-repair.md) | Objective violations from checks the project already runs |
| [API contract drift](../plugins/nightshift/skills/nightshift/references/compose/shifts/api-contract-drift.md) | Checked-in server, schema, and client contracts brought back into agreement |
| [Architecture health](../plugins/nightshift/skills/nightshift/references/compose/shifts/architecture-health.md) | Concrete dependency and boundary cost from repository evidence |
| [Build reproducibility](../plugins/nightshift/skills/nightshift/references/compose/shifts/build-reproducibility.md) | Declared clean setup and build paths |
| [CI warning cleanup](../plugins/nightshift/skills/nightshift/references/compose/shifts/ci-warning-cleanup.md) | Repository-owned warnings the pipeline already prints |
| [Clear quality debt](../plugins/nightshift/skills/nightshift/references/compose/shifts/clear-quality-debt.md) | The backlog your tools already know about |
| [Dead-code cleanup](../plugins/nightshift/skills/nightshift/references/compose/shifts/dead-code-cleanup.md) | Code proven unused by tooling the repository already trusts |
| [Dependency upgrade sweep](../plugins/nightshift/skills/nightshift/references/compose/shifts/dependency-upgrade-sweep.md) | The version drift your package manager already tracks |
| [Developer onboarding](../plugins/nightshift/skills/nightshift/references/compose/shifts/developer-onboarding.md) | Fresh-reader checkout through one verified change |
| [Documentation drift](../plugins/nightshift/skills/nightshift/references/compose/shifts/documentation-drift.md) | Local docs that no longer match this repository |
| [Documentation media accuracy](../plugins/nightshift/skills/nightshift/references/compose/shifts/documentation-media-accuracy.md) | Verify named screenshots and GIFs against a local UI |
| [Documentation writing](../plugins/nightshift/skills/nightshift/references/compose/shifts/documentation-writing.md) | Sourced docs from an outline or tree |
| [Environment example drift](../plugins/nightshift/skills/nightshift/references/compose/shifts/environment-example-drift.md) | Reconcile a root `.env.example` with literal config reads |
| [Flaky-test repair](../plugins/nightshift/skills/nightshift/references/compose/shifts/flaky-test-repair.md) | Unstable tests reproduced and repaired without weakening coverage |
| [GitHub issue hunt](../plugins/nightshift/skills/nightshift/references/compose/shifts/github-issue-hunt.md) | Work imported issues, one commit each, never write back |
| [Incident follow-up](../plugins/nightshift/skills/nightshift/references/compose/shifts/incident-follow-up.md) | Repository actions from supplied incident evidence |
| [Localization parity](../plugins/nightshift/skills/nightshift/references/compose/shifts/localization-parity.md) | Objective key drift in an existing localization system |
| [Migration compatibility](../plugins/nightshift/skills/nightshift/references/compose/shifts/migration-compatibility.md) | Guarded framework, config, and data migrations |
| [Performance regression](../plugins/nightshift/skills/nightshift/references/compose/shifts/performance-regression.md) | Measured change with an existing baseline |
| [Product journey](../plugins/nightshift/skills/nightshift/references/compose/shifts/product-journey.md) | Reproducible user-route gaps from explicit journey evidence |
| [Pull-request readiness](../plugins/nightshift/skills/nightshift/references/compose/shifts/pull-request-readiness.md) | Branch-scoped acceptance before human review |
| [Release readiness](../plugins/nightshift/skills/nightshift/references/compose/shifts/release-readiness.md) | Baseline vs candidate without publishing |
| [Research synthesis](../plugins/nightshift/skills/nightshift/references/compose/shifts/research-synthesis.md) | Decision-ready comparison of named sources |
| [Runbook verification](../plugins/nightshift/skills/nightshift/references/compose/shifts/runbook-verification.md) | Safe procedure replay with existing observability |
| [SEO audit](../plugins/nightshift/skills/nightshift/references/compose/shifts/seo-audit.md) | Prioritized, cited findings from an explicit site or tree |
| [TODO and FIXME debt](../plugins/nightshift/skills/nightshift/references/compose/shifts/todo-fixme-debt.md) | Actionable code comments resolved without inventing product decisions |
| [Toil reduction](../plugins/nightshift/skills/nightshift/references/compose/shifts/toil-reduction.md) | Automate repeated manual work with evidence |
| [Vulnerability sweep](../plugins/nightshift/skills/nightshift/references/compose/shifts/vulnerability-sweep.md) | The advisories filed against what you already ship |

## Who selects, and when work starts

These are independent choices. Picking a category does not by itself authorize implementation.

| | **Review first** | **Run directly** |
| --- | --- | --- |
| **Guided** | You choose the entries; inspect the plan before approving work. | You choose the entries; Nightshift starts their work immediately. |
| **Automatic** | Give a goal and hours; inspect the proposed work before approving it. | Give a goal and hours; Nightshift selects and starts work that serves the goal. |

One sentence is enough. *“Enhance my project for 5 hours”* is a complete Automatic request: it runs
directly under the shipped `shift.execution`, and a new project is set up first. With no hours,
Nightshift asks one question: how many hours.

Review-first discovery is read-only. Nothing is armed until you approve. Run directly authorizes
implementation within the stated scope and time; it does not authorize publishing, destructive
changes, or changes to owner policy. Significant decisions and their rollback stay in the parking
lot for review.

Run `/nightshift:hunt` and pick the options shown under each heading, or ask in plain words as in
the examples.

## Guided + Review first

Owner-selected catalog entries, with a plan to inspect before implementation.

`/nightshift:hunt` → **Guided** → select entries → **Review first**.

> Hunt Guided, documentation writing, review first. Propose an installation guide based on the
> repository's current setup commands. Show the sources and planned output before starting.

Approve the assembled order to cut it into the punch list and start. If it needs changes, revise
it first or save the order for later. The clock starts only after approval.

## Guided + Run directly

Owner-selected catalog entries, with immediate authority to discover and implement the work.

`/nightshift:hunt` → **Guided** → select entries → **Run directly**.

> Hunt Guided, coverage hunt, run directly for two hours. Focus on this repository's parser error
> paths. Use the existing test runner and leave local commits for review.

The clock starts immediately. Nightshift works the selected entry under its definition of done
and ending condition. Decisions that can be made within that scope are recorded with defaults
instead of causing another approval pause.

## Automatic + Review first

Your sentence supplies the objective; Nightshift selects applicable entries to serve it.
Hours are required.

`/nightshift:hunt` → **Automatic** → set hours → **Review first**.

> Hunt Automatic for four hours, review first. Improve this product's onboarding. Inspect the
> current journey, rank the useful changes, and show me the proposed shift before implementing.

A feature or design objective stays a feature or design objective. Finding lint warnings does not
replace it with a cleanup campaign. Review the evidence, scope, ordering, verification, and hours,
then approve or revise the plan.

## Automatic + Run directly

The same selection process, with immediate authority to work. Hours are required.

`/nightshift:hunt` → **Automatic** → set hours → **Run directly**.

> Hunt Automatic for four hours, run directly. Improve this product's onboarding using the existing
> stack. Work on an isolated branch, finish each change and verify it, and leave everything local
> for my review.

The clock starts immediately. A request that already contains an objective, a time budget, and
clear direct-execution intent needs no extra launch question. Nightshift selects work that serves
the objective, avoids overlapping entries, and follows each entry's ending condition.

## After the shift

Every mode ends the same way. Read the [morning receipt](morning-receipt.md#the-morning-receipt) at
`.nightshift/receipts/morning-<YYYY-MM-DD>-<shiftId>.md`, then follow its links to each item's
receipt.

## How an entry ends

- **Finite:** finish the defined list. Hours are optional and act as a cap.
- **Open-ended until the deadline:** keep working in complete units. Product evolution and coverage
  hunts require hours; finishing one cycle is not the end of the shift.
- **Open-ended with convergence:** repeat the cycle until its completion condition or deadline.
  A defect hunt succeeds when a full pass finds no new defects; it does not invent more work to
  fill the remaining time.

Automatic composition always requires hours. One deadline governs the shift; when combining
entries, finite work comes first, followed by at most one open-ended entry. At quitting time,
start no new unit and finish the one already in hand. An owner stop-work order takes precedence.

## Quality and owner walkthroughs

Quality offers the same selection and launch choices for tests, code, documentation, dependencies,
accessibility, contracts, and security. After a review-first survey, choose **fix now**, **draft for
later**, or **ignore**. A feature, product, or UI objective belongs with Hunt.

For your own ongoing objective, choose **Guided → Owner walkthrough**, supply the objective,
set the hours, and choose review first or run directly. The objective is preserved verbatim.
Nightshift keeps the active unit's progress and exact next action on disk. It can finish early
when the objective's acceptance criteria are verified; it does not fill the remaining hours with
unrelated work. Automatic never selects this entry because its objective must come from the owner.

## Tools and workspaces

The tooling policy decides what happens when useful checks are missing:

- **Existing tools only:** work with the project's available tools.
- **Review missing tools first:** inspect the proposed tools, writes, permissions, and rollback
  before installation and before the work clock starts.
- **Automatically add standard development tools:** allow eligible additions under the shift's
  existing elevation permissions.

A complete Automatic run-direct request carries your saved tooling policy. With no saved choice
or explicit override, it uses the default, automatically adding standard development tools. A
remembered policy grants no new elevation.
In a plain folder without Git, a shift uses the tools already there and works from the folder's
files. Entries that need a repository are skipped there: the GitHub issue hunt, the defect hunt,
documentation drift, TODO and FIXME debt, the coverage hunt, and the tooling quality-debt entries.

Review local commits in repository mode and output files plus the receipts in artifact mode.
[Evidence and receipts](evidence-capabilities.md#reviewing-a-shift) explains the records under
`.nightshift/receipts/` and how they are archived.

## Continue

- [Read the receipts and token usage](receipts.md#receipts-and-token-usage) while the work runs or after clock-out.
- [Archive finished work](archive.md#archive-and-continue) and keep the next shift's open items and decisions live.
- [Run the first-night safety checklist](first-night-checklist.md#first-night-safety-checklist) before leaving work unattended.
- [Choose owner settings](knobs.md#owner-knobs) for verification, permissions, and the receipts.
- [Use the command reference](commands.md#command-reference) for scheduling, stopping, and offline controls.
- [Read a completed run](../examples/adapttable-overnight.md#example--an-overnight-run-on-a-production-library) to see the contract and its review.

The exact composition contract is in
[selection and launch modes](../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md#selection-and-launch-modes).
To contribute an entry, use the [catalog recipe](../plugins/nightshift/skills/nightshift/references/compose/catalog-recipe.md#adding-a-shift-to-the-catalog)
and [contribution map](contribution-map.md#choose-your-contribution). The [documentation index](README.md#documentation) lists the full reference.
