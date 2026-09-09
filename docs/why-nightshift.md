# Why Nightshift exists

I asked for eight changes and stepped away. Four easy items shipped. The four hard ones were
deferred because they “deserved a focused session.”

![The checkpoint that prompted Nightshift: smaller fixes completed, harder items deferred, and a
question left waiting](https://github.com/user-attachments/assets/a4816652-a2c1-4212-aff9-8a3dafd848a6)

This was the focused session. The agent had the project, the task list, and time to work. What was
missing was a durable agreement about when the work was done.

That screen was the starting point. Four recurring failures shaped what Nightshift became.

## The quiet early finish

The agent completes the easiest part, rewrites the meaning of “done,” and presents the remainder as
future work. A conversational instruction to continue is easy to lose after enough tool output or
context compaction. The unfinished work needs to remain a contract, not become a suggestion.

Nightshift keeps completion in a file. Open checkboxes remain an explicit contract at every stop
attempt.

## The overnight question

A long run stops at 02:40 with “quick question before I continue.” The owner sees it at 08:00,
still waiting for the answer. The useful work window has gone and the list is not done. If an
allowance reset landed that morning, the remaining capacity expired unused and the same items now
consume the new cycle.

Nightshift parks the question with the chosen default and continues. The owner can answer live or
review the decision later.

## The review loop that never converges

One review finds twenty issues. After those are fixed, the next review finds twenty *new* issues.
Where were those twenty the first time? The owner becomes a courier between repeated scans without
a stable definition of done.

Nightshift makes the work list, verification, and ending condition explicit before the run. A
finite shift ends when its list is clear. A defect hunt can finish at a clean pass; product
evolution and coverage hunts continue until their required deadline.

## The dead session

A session dies, or an API error leaves it waiting. A hook inside that session cannot provide
its own recovery:

![API Error: 500 Internal server error — a server-side issue that leaves the session waiting for a
restart](https://github.com/user-attachments/assets/c9a72548-995b-47c3-a72e-03a0f890a5bc)

Without recovery, the owner's night becomes one eye on the host status page, waiting to relaunch
the second the service returns. So much for sleeping.

Nightshift records the active session and keeps the work contract on disk. A separate watchman
requires positive failure evidence before attempting recovery. Claude Code can also recover a
classified live API-error session; a live Codex error remains outside that recovery path.
Stop-work orders, completed shifts, and deadlines stand the watchman down.

The host-specific signals, session-end behavior, and fallbacks are documented in
[How Nightshift works](how-it-works.md#recovery). Recovery preserves the chance to continue;
it cannot repair the upstream service or guarantee that the work itself is correct.

## The design response

Nightshift changes the ending: the shift keeps working until its list is clear, quitting time
arrives, or the owner stops it, and the first morning task is reviewing what happened rather than
reconstructing the run.

These failures need different mechanisms:

- a persistent punch list for what remains;
- hooks for rules the agent must not reinterpret;
- a parking lot for decisions that should not block the night;
- a deadline or finite ending condition;
- recovery outside the dead session;
- local receipts for what actually happened.

That is Nightshift's scope. It does not make generated code inherently correct, replace review, or
repair a host's internal context engine. It keeps the working contract available until the list is
done, the deadline arrives, or the owner stops the shift.

## What it costs

Nightshift adds work rather than removing it: a contract to read, gates to run, receipts and a
report to write, and a watchman that wakes up. **It is not a way to spend fewer tokens, and nothing
here claims it is.** A shift may well use more than the same work done by hand.

What it can reduce is rework — a night that stops at the wrong place, a morning spent
reconstructing what happened, a change nobody can review. Whether that trade is worth it depends
on the work, and it is yours to judge. Where a report shows what an item cost, those are the
numbers the host reported, kept separate from anything estimated; where the host reports nothing,
the report says unavailable rather than guessing. A token count is never turned into a price.

The [receipts and token usage guide](receipts.md#receipts-and-token-usage) explains how the runtime measures each
item and preserves gaps in the host's data.

## Follow the story

- [How Nightshift works](how-it-works.md#how-nightshift-works) follows the contract from Start to clock-out.
- [The first overnight run](../examples/adapttable-overnight.md#example--an-overnight-run-on-a-production-library) shows the work and the owner review.
- [The 45-hour handoff](../examples/adapttable-continuity.md#flagship-example--one-contract-two-coding-agents-57-issues) follows a contract across hosts.
- [Run your first shift](../README.md#your-first-shift) starts with one small, attended task.

For a specific question, use the [documentation index](README.md#documentation).
