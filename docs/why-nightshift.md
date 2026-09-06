# Why Nightshift exists

Nightshift started with an eight-item coding session. Four easy items shipped. The four hard ones
were deferred by the agent because they “deserved a focused session.”

![An agent checkpoint showing the smaller fixes completed, the larger items deferred, and a
question left waiting](https://github.com/user-attachments/assets/a4816652-a2c1-4212-aff9-8a3dafd848a6)

The problem was not a missing prompt. That screen was only the mildest of four predictable nights.

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
finite shift ends when its list is clear; an open-ended shift ends at its required deadline.

## The dead session

The API fails, the process exits, and no hook remains alive to restart it:

![API Error: 500 Internal server error — a server-side issue that leaves the session waiting for a
restart](https://github.com/user-attachments/assets/c9a72548-995b-47c3-a72e-03a0f890a5bc)

Without recovery, the owner's night becomes one eye on the host status page, waiting to relaunch
the second the service returns. So much for sleeping.

Nightshift records the active session and keeps the work contract on disk. Its watchman can resume
a session that has positive evidence of death. Both hosts stand down for completed shifts,
stop-work orders, and deadlines. Claude Code also exposes Escape and clean-session-end signals.
Codex SessionEnd (reason `other`) is pause-recovery: Start re-arms, and a crash with no SessionEnd
still revives. Cursor liveness is pulse plus pid plus transcript plus lease pid, not empty-pid-as-dead.

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

Those figures are read by the runtime from the records your host already keeps — the session
transcript on Claude Code, the rollout's running count on Codex, the stop payload on Cursor — and
written into each item's section at the tick. Nothing is estimated, and the model never writes a
usage figure: it cannot see its own token counts, so anything it wrote would be a guess.

Read [how Nightshift works](how-it-works.md), or
[run a first shift](../README.md#run-a-first-shift).
