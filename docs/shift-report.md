# Shift report and token usage

The shift report answers three questions: what did the agent deliver, how was it checked, and
what did each item consume? It lives at `.nightshift/shift-report.md` and is written during the
work. You can read an unfinished item's progress without waiting for the whole shift to end.

## Read the work item by item

Each item has its own section: current state, the result you get, significant changes and their
reasons, verification and limitations, output files or commits, and related snags or decisions.
While it runs, a short progress paragraph records what is done and what remains. The final result
replaces that paragraph when the item finishes. Later corrections stay visible in the section.

At clock-out, an overall outcome identifies what was delivered, what remains open, and what you
should review next. A stop or deadline can leave the report incomplete; a missing summary does
not delay the stop. The separate [morning receipt](morning-receipt.md#the-morning-receipt) provides the compact ending
and evidence summary. The [example report](../examples/shift-report.md#shift-report) shows completed work,
an unfinished item, a correction, and partially available usage.

## Token usage is measured by the runtime

The hooks read the host's records and append usage and duration to the item's section at its tick.
The agent does not estimate its own consumption. Accounting boundaries follow ticks: work between
two ticks belongs to the item closed by the second, including its verification and reporting.
This is useful attribution, not a profiler of individual edits; items ticked together can share a
reading. Duration is wall-clock time, with known idle gaps identified rather than silently removed.

| Host | Measurement source | How to read the figures |
| --- | --- | --- |
| Claude Code | Session transcript | Repeated response records are deduplicated. Cache reads and cache writes are separate from input. |
| Codex | Rollout token counter | Cached input is already included in input; reasoning is already included in output. |
| Cursor | IDE stop payload | Input overlaps cache figures. Reasoning and subagent usage are not reported; recovered CLI segments have no per-turn usage source. |

Input, output, cache reads, cache writes, and reasoning retain their names and host-specific
meaning. Missing measurements are marked `unavailable`. Recovery, model changes, and counter
resets open new segments instead of subtracting incompatible counters. Totals are not added
across hosts, and tokens are never converted into an estimated price. Usage already spent before
the shift began is excluded from its accounting.

## Choose when progress updates appear

The report defaults to progress updates after 20 minutes of work on an item. You can choose:

- **Time:** update after the configured minutes.
- **Tokens:** update after the configured token threshold; fall back to time when no counter is available.
- **Either:** update when either threshold is reached.
- **Completion only:** write the finished section without intermediate updates.

The runtime checks the cadence when a tool returns, so it does not interrupt a running command.
These thresholds control reporting frequency; they do not end a shift or enforce a token budget.
Use the shift's deadline and stall settings to bound continued work.

The settings are `report.progressMode`, `report.progressMinutes`, and `report.progressTokens`.
`report.usage` defaults to `when-available`; `off` disables usage measurement and the runtime's
progress-due notices. `report.enabled=false` disables the report itself while retaining the work
contract and other records. Report and morning-receipt templates can be customized separately.
See [Owner knobs](knobs.md#shift-handoff-and-archive) for the exact settings.

## Keep the report useful after the shift

Review the actual outputs and checks alongside the report. When you [archive the shift](archive.md#archive-and-continue),
its report is filed with its records, links are adjusted for the new location, and an untouched
original is preserved. Open work retains the evidence it needs for continuation.

[Review the underlying evidence](evidence-capabilities.md#reviewing-a-shift) ·
[Choose the next shift](shift-modes.md#shift-modes) · [Documentation index](README.md#documentation)
